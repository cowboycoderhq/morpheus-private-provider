#!/bin/bash
# R7-T3 settling test (review/TRACKED-ITEMS-CLOSURE-2026-10-22.md, R7-T3.4;
# results in review/R7T3-2026-10-22.md). After Metal device creation and the
# model load, can framework code change the exception ports, the signal
# dispositions or the sandbox (or the rlimits, credentials and status word
# that the start checks rely on)?
#
#  Order of the run: A, C, B, Q, E (the full arms first).
#  Q  Quick arms through the test spawner (no requests): the release-
#     equivalent read-back build, the static-initializer control, the five
#     seeded changes after the load, the interposer build, and the crash arm
#     after the load (guard and no-guard control).
#  A  build-r7 through the launcher and the Splash server on 127.0.0.1:8299:
#     request sweep, one generation of at least 300 s, then the end check
#     (read-back and the R5 self-test again). Read-back after the load,
#     before and after each request, and every 1 ms in a busy-poll thread.
#  B  The five seeded changes during (task port: after) the first request.
#  C  The interposer build through the same workload as A. Controls: its
#     seeded calls (iii) and a Metal compile from the shared cache (i, reach).
#  E  The crash arm after the first request (guard and no-guard control).
#
# The production child in child/ is not touched: each arm runs a copy of a
# test build from its own folder under neg/run-r7t3 with its own pin and
# launch requirement. Writes neg/r7t3-<date>.txt; logs in logs/r7t3-<date>/.
# Usage: neg/run-r7t3.sh   (run neg/build-all.sh first; no sudo)
cd "$(dirname "$0")/.."
PKG=$PWD/pkg/qwen38-27b
D=$(date +%F)
O=neg/r7t3-$D.txt
RUN=$PWD/neg/run-r7t3
LOGS=$PWD/logs/r7t3-$D
PORT=8299
URL=http://127.0.0.1:$PORT
UTMP=$(getconf DARWIN_USER_TEMP_DIR); UTMP=${UTMP%/}
SGRP=$(id -Gn | tr ' ' '\n' | grep -vx "$(id -gn)" | head -1)
DPIN=3a86a25828fdfac91f5d00b3f217bbae66320000
PY=/opt/homebrew/opt/splash/libexec/python/bin/python3
export BENCH_OK=1 PYTHONUNBUFFERED=1 TRANSFORMERS_VERBOSITY=error PYTHONDONTWRITEBYTECODE=1
REFUSED='exit=113 '
LOADED='exit=-9 SANDBOXED then LOADED'
P='first byte S, then 4 bytes: 534c5342'
FATAL='3|4|5|6|7|8|10|11|12|24|25'   # the guard's fatal set (SG:136-137)
: > $O
rm -rf "$RUN" "$LOGS"; mkdir -p "$RUN" "$LOGS"
printf 'R7-CANARY\n' > "$UTMP/r7-canary.txt"
echo "# build: $(date '+%F %T') host=$(sysctl -n hw.model) $(sw_vers -buildVersion) uid=$(id -u) setid-group=$SGRP" >> $O
invalid=0 changed=0
v() {  # v <PASS|FAIL-CONTROL|CHANGED|INFO|VOID> <text>
  case $1 in FAIL-CONTROL) invalid=$((invalid + 1));; CHANGED) changed=$((changed + 1));; esac
  echo "$1 $2" >> $O
}

# prep <tag> <build> [setid|interpose] -> echoes the child path
prep() {
  local d=$RUN/$1 E=$RUN/$1/splash
  mkdir -p "$d" && printf 'r5 owndir probe\n' > "$d/r5-owndir-probe" && cp splash/$2/splash "$E"
  if [ "$3" = interpose ]; then
    cp neg/R7/libr7interpose.dylib "$d/"
    codesign -f -s - --options runtime --entitlements neg/R7/dlv.entitlements -i sealed.splash "$E" 2>/dev/null
  else
    codesign -f -s - --options runtime -i sealed.splash "$E" 2>/dev/null
  fi
  [ "$3" = setid ] && chgrp "$SGRP" "$E" && chmod g+s "$E"
  echo "$E"
}
keep() { cp /tmp/sealed-reason.log "$LOGS/$1.reason" 2>/dev/null; }
r7lines() { grep -E "$2" "$LOGS/$1.reason" 2>/dev/null | sed "s#$PWD/##g" | paste -sd ';' - | cut -c1-${3:-700}; }

# --- Server arms.
SP=""
serve() {  # serve <tag> <child> [launcher]: starts the server; 0 when the child reported "loaded"
  local tag=$1 E=$2 L=${3:-$PWD/launcher/sealed-launch} pin
  pin=$(codesign -dvvv "$E" 2>&1 | awk -F= '/^CDHash=/{print $2}')
  tools/reqgen "$E" "$pin" dummy "$RUN/$tag.req" >/dev/null
  : > "$LOGS/$tag.launch.log"
  SEALED_CHILD=$E SEALED_PIN=$pin SEALED_REQ=$RUN/$tag.req SEALED_DECOY=$PWD/tools/decoy SEALED_DECOY_PIN=$DPIN \
  SEALED_LOG=$LOGS/$tag.launch.log "$PY" -u /opt/homebrew/opt/splash/libexec/server/server.py "$PKG/target" "$PKG/draft" \
    --tokenizer "$PKG/tokenizer" --model audreyt/Qwen3.8-27B-Splash-abliterated --binary "$L" --host 127.0.0.1 \
    --port $PORT --max-memory auto --max-context 32768 --no-webui > "$LOGS/$tag.server.log" 2>&1 &
  SP=$!
  local i c
  for i in $(seq 1 150); do
    c=$(curl -s -m 3 -o /dev/null -w "%{http_code}" $URL/v1/models)
    [ "$c" = 200 ] && grep -q "manifest hash matches" "$LOGS/$tag.launch.log" && return 0
    kill -0 $SP 2>/dev/null || return 1
    sleep 2
  done
  return 1
}
stopserve() {  # stopserve <tag>: stops the server; records anything left
  kill -TERM $SP 2>/dev/null
  local i left
  for i in $(seq 1 60); do kill -0 $SP 2>/dev/null || break; sleep 1; done
  sleep 2
  local pat="$RUN/|sealed-launch-dlv|$PWD/launcher/sealed-launch serve-native|server.py.*--port $PORT"
  left=$(pgrep -f "$pat" | wc -l | tr -d ' ')
  if [ "$left" != 0 ]; then pkill -9 -f "$pat"; v INFO "[$1-cleanup] $left processes left after the stop, killed"; fi
}
childpid() { awk '/spawn rc=0/{print $3}' "$LOGS/$1.launch.log" | tail -1 | cut -d= -f2; }
waitfor() {  # waitfor <ERE> <seconds>: waits for a line in the reason file
  local i
  for i in $(seq 1 $2); do grep -Eq "$1" /tmp/sealed-reason.log 2>/dev/null && return 0; sleep 1; done
  return 1
}

# full <tag> <build> [launcher] [interpose] [sweep mode]: workload A on one build.
full() {
  local tag=$1 E pid dir mode=${5:-nomask}
  E=$(prep "$tag" "$2" "$4")
  rm -f /tmp/sealed-reason.log
  if ! serve "$tag" "$E" "$3"; then
    keep "$tag"; stopserve "$tag"
    v FAIL-CONTROL "[$tag-serve] the child did not reach \"loaded\" through the launcher: $(tail -2 "$LOGS/$tag.launch.log" | paste -sd ';' -) $(r7lines "$tag" 'CHANGED|sealed-r')"
    return 1
  fi
  pid=$(childpid "$tag")
  "$PY" neg/R7/sweep.py $URL $mode > "$LOGS/$tag.sweep" 2>&1
  [ "$mode" = nomask ] && "$PY" neg/R7/sweep.py $URL long >> "$LOGS/$tag.sweep" 2>&1
  if ! kill -0 "$pid" 2>/dev/null; then
    keep "$tag"; stopserve "$tag"; return 2   # the child was replaced during the workload
  fi
  # End check: probe files back in place (the launcher removed them after
  # "sandboxed"), the end marker, then one request.
  dir=""
  pid=$(childpid "$tag")   # the child serving now
  [ -n "$pid" ] && dir=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
  if [ -n "$dir" ] && [ "${dir#*/sealed-child-}" != "$dir" ] && [ -d "$dir/metal-cache" ]; then
    printf 'probe\n' > "$dir/r5-probe"; printf 'probe\n' > "$dir/metal-cache/r5-probe"
  fi
  mkdir -p "$RUN/$tag/en.lproj"
  "$PY" neg/R7/sweep.py $URL end >> "$LOGS/$tag.sweep" 2>&1
  waitfor '^r7: END |r7: CHANGED|sealed-r5: ' 120
  echo "# child pid=$pid tmpdir=$dir alive-at-end=$(kill -0 "$pid" 2>/dev/null && echo 1 || echo 0)" >> "$LOGS/$tag.sweep"
  keep "$tag"
  stopserve "$tag"
  rm -rf "$RUN/$tag/en.lproj"
  return 0
}

# Evaluates one full arm's reason file.
judge_full() {  # judge_full <tag>
  local f=$LOGS/$1.reason s=$LOGS/$1.sweep n
  local spawns; spawns=$(grep -c 'spawn rc=0' "$LOGS/$1.launch.log")
  v INFO "[$1-workload] $(grep -c '^REQ ' "$s") requests, $(grep -c '^REQ .* http=200 ' "$s") with http 200, child spawns=$spawns; $(grep -E '^(LONG|REQ long)' "$s" | paste -sd ';' -)"
  grep -q '^LONG' "$s" && ! grep -q '^LONG ok' "$s" && v INFO "[$1-long-generation] no single generation reached 300 s (written design: at least 5 minutes)"
  # One child must serve the whole workload; a child that ended for another
  # reason cuts the workload, and the arm is not complete.
  [ "$spawns" = 1 ] || v FAIL-CONTROL "[$1-single-child] $spawns children served the workload; other refusals: $(grep -E '^sealed-r[0-9]: ' "$f" | grep -v 'selftest' | head -2 | sed "s#$PWD/##g" | paste -sd ';' -)"
  if grep -q 'r7: CHANGED' "$f"; then v CHANGED "[$1-readback] $(r7lines "$1" 'r7: CHANGED' 900)"; return; fi
  if grep -q '^sealed-r5: ' "$f"; then v CHANGED "[$1-end-self-test] $(grep -m1 '^sealed-r5: ' "$f")"; return; fi
  for pt in sandboxed own-signals after-load loaded; do
    grep -q "^r7: check $pt PASS" "$f" && v PASS "[$1-check-$pt]" || v FAIL-CONTROL "[$1-check-$pt] missing"
  done
  n=$(grep -cE '^r7: check request-[0-9]+-(before|after) PASS' "$f")
  [ "$n" -ge ${2:-20} ] && v PASS "[$1-check-around-requests] $n checks PASS ($(grep -cE '^r7: check request-[0-9]+-before PASS' "$f") before, $(grep -cE '^r7: check request-[0-9]+-after PASS' "$f") after)" \
    || v FAIL-CONTROL "[$1-check-around-requests] only $n checks"
  local endl; endl=$(grep -m1 '^r7: END PASS' "$f")
  if [ -n "$endl" ] && grep -q '^r7: check end PASS' "$f" && grep -q 'sealed-r5 selftest done: all denials held' <(sed -n '/^r7: end self-test start/,$p' "$f"); then
    v PASS "[$1-end] read-back and the R5 self-test held: ${endl#r7: }; $(grep '^r7: busy-poll n=' "$f" | tail -1)"
  else
    v FAIL-CONTROL "[$1-end] no end result: $(tail -3 "$f" | paste -sd ';' -)"
  fi
}


# full_retry <tag> <build> [launcher] [interpose]: one more attempt when the
# child was replaced during the workload for a reason outside R7-T3 (for
# example an R6 refusal); the first attempt's logs are kept as <tag>-attempt1.
full_retry() {
  full "$@"; local rc=$?
  [ $rc = 2 ] || return $rc
  local f
  for f in "$LOGS/$1".*; do mv "$f" "$LOGS/$1-attempt1.${f##*.}"; done
  v INFO "[$1-attempt1] the child was replaced during the workload: $(grep -E '^sealed-r[0-9]: ' "$LOGS/$1-attempt1.reason" | grep -vE 'selftest|accepted residual' | head -1 | sed "s#$PWD/##g"); requests before it: $(grep -c 'http=200' "$LOGS/$1-attempt1.sweep") with http 200"
  full "$@"; rc=$?
  if [ $rc = 2 ]; then judge_full "$1"; return 1; fi
  return $rc
}

# Order: the full arms first, on a Mac with no test child loaded before them.
full_retry A build-r7 && judge_full A
# M: the token-mask requests (structured output, tools) under the read-back,
# in a build without the R6 share-mode check, which refuses those requests on
# this pair with or without the R7-T3 code (logs/r7t3-<date>-s3check/).
full M build-r7-noshar "" "" mask && judge_full M 4

# --- C. Interposer arm.
if full_retry C build-r7-interpose "$PWD/neg/R7/sealed-launch-dlv" interpose; then
  judge_full C
  f=$LOGS/C.reason
  # Control (iii): the three seeded calls, each counted with the child as the caller.
  seeds=$(sed -n '/name=seed-begin/,/name=seed-end/p' "$f" | grep -cE "name=(sigaction kind=2 arg=11|thread_set_exception_ports kind=1|sandbox_extension_consume kind=3) .*caller=$RUN/C/splash")
  # Control (i), reach: a counted call whose caller is in the shared cache.
  reach=$(grep -E '^r7i: hit .* cache=1 ' "$f" | head -3 | sed "s#^r7i: hit ##" | paste -sd ';' -)
  if [ "$seeds" = 3 ] && [ -n "$reach" ]; then
    v PASS "[C-interposer-controls] seeded calls counted=3/3; reach (shared-cache caller): $reach"
    out=$(sed -n '/name=seed-end/,$p' "$f" | grep '^r7i: hit' | awk '/name=reach-begin/{r=1} /name=reach-end/{r=0; next} !r')
    ports=$(echo "$out" | grep -c ' kind=1 ')
    fatal=$(echo "$out" | grep -cE " kind=2 arg=($FATAL) ")
    other=$(echo "$out" | grep ' kind=2 ' | grep -vE " kind=2 arg=($FATAL) " | sed -E 's/.* name=([a-z_]+) kind=2 arg=([0-9]+) .*caller=([^+]+).*/\1(\2) from \3/' | sed "s#$PWD/##g" | sort | uniq -c | paste -sd ';' -)
    relax=$(echo "$out" | grep ' kind=3 ')
    bad=$(echo "$relax" | grep -v '^$' | grep -vE "name=sandbox_extension_issue_file kind=3 arg=0 ret=0 .*caller=/System/Library/Frameworks/Metal.framework/" | grep -vE "name=sandbox_init_with_parameters kind=3 .*caller=$RUN/C/splash")
    v INFO "[C-interposer-signal-calls-outside-fatal-set] ${other:-none}"
    v INFO "[C-interposer-relax-calls] $(echo "$relax" | grep -v '^$' | sed -E 's/.* name=([a-z_]+) kind=3 arg=[0-9-]+ ret=([0-9-]+) errno=([0-9]+) cache=([01]) caller=([^+]+).*/\1 ret=\2 errno=\3 from \5/' | sed "s#$PWD/##g" | sort | uniq -c | paste -sd ';' -)"
    [ "$ports" = 0 ] && v PASS "[C-interposer-port-calls-after-guard] 0" || v CHANGED "[C-interposer-port-calls-after-guard] $ports: $(echo "$out" | grep ' kind=1 ' | head -3 | paste -sd ';' -)"
    [ "$fatal" = 0 ] && v PASS "[C-interposer-fatal-signal-calls-after-guard] 0" || v CHANGED "[C-interposer-fatal-signal-calls-after-guard] $fatal: $(echo "$out" | grep -E " kind=2 arg=($FATAL) " | head -3 | paste -sd ';' -)"
    [ -z "$bad" ] && v PASS "[C-interposer-relax-calls-allowed-only] only the child's own sandbox_init_with_parameters and denied Metal issues" \
      || v CHANGED "[C-interposer-relax-calls-allowed-only] $(echo "$bad" | head -3 | paste -sd ';' -)"
    grep -q '^r7i: dropped' "$f" && v INFO "[C-interposer-dropped] $(grep '^r7i: dropped' "$f" | tail -1)"
  else
    v VOID "[C-interposer-arm] controls did not fire: seeded=$seeds/3 reach='${reach}' (arm void, not a pass)"
  fi
fi

# --- B. Seeded changes during (task port: after) the first request.
bseed() {  # bseed <tag> <build> <class ERE> [setid]
  local tag=$1 E
  E=$(prep "$tag" "$2" "$4")
  rm -f /tmp/sealed-reason.log
  if ! serve "$tag" "$E"; then keep "$tag"; stopserve "$tag"; v FAIL-CONTROL "[$tag] did not load: $(tail -2 "$LOGS/$tag.launch.log" | paste -sd ';' -)"; return; fi
  "$PY" neg/R7/sweep.py $URL one > "$LOGS/$tag.sweep" 2>&1
  waitfor 'r7: CHANGED' 30 || { "$PY" neg/R7/sweep.py $URL one >> "$LOGS/$tag.sweep" 2>&1; waitfor 'r7: CHANGED' 30; }
  keep "$tag"; stopserve "$tag"
  local c; c=$(r7lines "$tag" '^(test: r7 seed|r7: CHANGED)' 600)
  if grep -Eq "r7: CHANGED point=[^ ]+ class=$3" "$LOGS/$tag.reason"; then v PASS "[$tag] $c"; else v FAIL-CONTROL "[$tag] $c"; fi
}
bseed B-seed-request-signal build-r7-rseed-signal 'signal-disposition SIGSEGV'
bseed B-seed-request-threadport build-r7-rseed-threadport 'exception-ports thread-ports: thread'
bseed B-seed-after-request-taskport build-r7-rseed-taskport 'exception-ports task:'
bseed B-seed-request-extension build-r7-rseed-ext 'sandbox'
bseed B-seed-request-setid build-r7-rseed-setid 'credentials' setid

# --- Q. Quick arms through the test spawner.
q() {  # q <tag> <build> <want spawner ERE> <want reason ERE> [setid|interpose]
  local E; E=$(prep "$1" "$2" "$5")
  rm -f /tmp/sealed-reason.log
  local L; L=$(neg/B/r2neg "$E" "$PKG" control 2>&1 | tail -1); L=${L#*] }
  keep "$1"
  local R; R=$(r7lines "$1" '^(test: r7|r7: (CHANGED|check after-load))')
  if echo "$L" | grep -Eq "$3" && grep -Eq "$4" "$LOGS/$1.reason"; then echo "ok $L | $R"; else echo "no $L | $R"; fi
}
ctl() {  # ctl <name> <q output>: a control that must fire
  case $2 in ok*) v PASS "[$1] ${2#ok }";; *) v FAIL-CONTROL "[$1] ${2#no }";; esac
}
r=$(q Q-readback build-r7 "^$LOADED" "^r7: check after-load PASS")
case $r in ok*) v PASS "[Q-readback-after-load] ${r#ok }";; *) grep -q 'r7: CHANGED' "$LOGS/Q-readback.reason" && v CHANGED "[Q-readback-after-load] ${r#no }" || v FAIL-CONTROL "[Q-readback-after-load] ${r#no }";; esac
ctl Q-static-init "$(q Q-static build-r7-static "^$LOADED" 'present after the guard=0')"
ctl Q-seed-load-signal "$(q Q-seed-signal build-r7-seed-signal "^$REFUSED$P" 'CHANGED point=[^ ]+ class=signal-disposition SIGSEGV')"
ctl Q-seed-load-taskport "$(q Q-seed-taskport build-r7-seed-taskport "^$REFUSED$P" 'CHANGED point=[^ ]+ class=exception-ports task:')"
ctl Q-seed-load-threadport "$(q Q-seed-threadport build-r7-seed-threadport "^$REFUSED$P" 'CHANGED point=[^ ]+ class=exception-ports thread-ports: thread')"
ctl Q-seed-load-extension "$(q Q-seed-ext build-r7-seed-ext "^$REFUSED$P" 'CHANGED point=[^ ]+ class=sandbox')"
ctl Q-seed-load-setid "$(q Q-seed-setid build-r7-seed-setid "^$REFUSED$P" 'CHANGED point=[^ ]+ class=credentials' setid)"

# Crash arm (A-20 harness of run-tee.sh), crash point after the load.
crash_q() {  # crash_q <tag> <build> -> "reports=<n> with-canary=<n> | <spawner line>"
  local E; E=$(prep "$1" "$2")
  touch "$RUN/t0.$1"
  rm -f /tmp/sealed-reason.log
  local L; L=$(neg/B/r2neg "$E" "$PKG" control 2>&1 | tail -1)
  keep "$1"
  sleep 20
  local hits=0 reports=0 f
  for f in $(find ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports -newer "$RUN/t0.$1" -type f 2>/dev/null); do
    case "$f" in *splash*) reports=$((reports + 1)); cp "$f" "$LOGS/" 2>/dev/null
      grep -q -i -e "5445454341524159" -e "6072335827740016985" "$f" && hits=$((hits + 1));; esac
  done
  echo "reports=$reports with-canary=$hits | ${L#*] }"
}
r=$(crash_q Q-crash-postload-nor1 build-r7-crash-postload-nor1)
echo "$r" | grep -Eq "^reports=[1-9][0-9]* with-canary=[1-9][0-9]* \| exit=-5 $P" && v PASS "[Q-crash-postload-control-no-guard] $r (the oracle sees the canary)" || v FAIL-CONTROL "[Q-crash-postload-control-no-guard] $r"
r=$(crash_q Q-crash-postload build-r7-crash-postload)
echo "$r" | grep -Eq "^reports=0 with-canary=0 \| exit=113 $P" && v PASS "[Q-crash-postload-with-guard] $r" || v CHANGED "[Q-crash-postload-with-guard] $r (the fault after the load did not end at the guard)"

# --- E. Crash after the first request, through the launcher. The spawner
#     sets the child's guard-mask exception port to its own port at spawn
#     (SS:1403-1415), so without R1 the fault reaches the spawner
#     (exception_seen=1); with R1 the child's guard ends it (exit 113,
#     exception_seen=0). No crash report may carry the canary.
ecrash() {  # ecrash <tag> <build> -> "exception_seen=<n> reports=<n> with-canary=<n> crashed=<0|1>"
  local tag=$1 E
  E=$(prep "$tag" "$2")
  rm -f /tmp/sealed-reason.log
  touch "$RUN/t0.$tag"
  if ! serve "$tag" "$E"; then keep "$tag"; stopserve "$tag"; echo "exception_seen=- reports=- with-canary=- crashed=0 (did not load)"; return; fi
  "$PY" neg/R7/sweep.py $URL one > "$LOGS/$tag.sweep" 2>&1
  local i
  for i in $(seq 1 60); do grep -q 'exception_seen=' "$LOGS/$tag.launch.log" && break; sleep 1; done
  sleep 20
  keep "$tag"; stopserve "$tag"
  local hits=0 reports=0 f
  for f in $(find ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports -newer "$RUN/t0.$tag" -type f 2>/dev/null); do
    case "$f" in *splash*) reports=$((reports + 1)); cp "$f" "$LOGS/" 2>/dev/null
      grep -q -i -e "5445454341524159" -e "6072335827740016985" "$f" && hits=$((hits + 1));; esac
  done
  local ex; ex=$(grep -m1 -o 'exception_seen=[0-9]' "$LOGS/$tag.launch.log")
  local cr=0; grep -q 'tee-probe crash canary' "$LOGS/$tag.reason" 2>/dev/null && cr=1
  echo "${ex:-exception_seen=-} reports=$reports with-canary=$hits crashed=$cr"
}
r=$(ecrash E-crash-request-nor1 build-r7-crash-request-nor1)
echo "$r" | grep -Eq "crashed=1" && echo "$r" | grep -Eq "exception_seen=1|with-canary=[1-9]" && v PASS "[E-crash-after-request-control-no-guard] $r (the oracle sees a fault that bypasses the guard)" \
  || v FAIL-CONTROL "[E-crash-after-request-control-no-guard] $r"
r=$(ecrash E-crash-request build-r7-crash-request)
echo "$r" | grep -Eq "^exception_seen=0 reports=0 with-canary=0 crashed=1" && v PASS "[E-crash-after-request-with-guard] $r" \
  || v CHANGED "[E-crash-after-request-with-guard] $r (the fault after a request did not end at the guard)"

# --- Verdict (criteria written before the run, R7-T3.4 and the operator's brief).
rm -f "$UTMP/r7-canary.txt"
cp -p $O "$LOGS/" 2>/dev/null
rm -rf "$RUN" /tmp/sealed-reason.log
if [ $invalid -gt 0 ]; then echo "VERDICT INVALID ($invalid controls or required checks did not fire)" >> $O
elif [ $changed -gt 0 ]; then echo "VERDICT CHANGED ($changed findings; see the CHANGED lines)" >> $O
else echo "VERDICT PASS (read-backs match after the load, around each request, in the busy-poll and at the end; all seeded controls fired; the end self-test held)" >> $O; fi
cat $O
