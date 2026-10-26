#!/bin/bash
# TEE evidence run for the sealed Splash child (agent-runnable, no root).
# 1. Plants read-sweep canaries, runs the TEE probe build through the real
#    launcher and server (all phases incl. serving), and the two controls
#    (no sandbox; extension rule) through the test spawner.
# 2. Checks the os_log store for the canaries.
# 3. Crash-report arm: crash builds with and without the R1 guard.
# Writes neg/tee-<date>.txt with one PASS/FAIL/INFO line per arm.
# Usage: neg/run-tee.sh   (run neg/build-all.sh first)
cd "$(dirname "$0")/.."
PKG=$PWD/pkg/qwen38-27b
O=neg/tee-$(date +%F).txt
RUN=$PWD/neg/run-tee
UTMP=$(getconf DARWIN_USER_TEMP_DIR); UTMP=${UTMP%/}
export BENCH_OK=1
fails=0
: > $O
echo "# build: $(date '+%F %T') host=$(sysctl -n hw.model) $(sw_vers -buildVersion)" >> $O
v() {  # v <PASS|FAIL|INFO> <text>
  [ "$1" = FAIL ] && fails=$((fails + 1))
  echo "$1 $2" >> $O
}
sign() { codesign -f -s - --options runtime -i sealed.splash "$1" 2>/dev/null; }

CANARIES=(/Users/Shared "$HOME" "$HOME/Library" "$HOME/Library/Caches" "$HOME/Library/Application Support/Splash"
          "$HOME/.cache/huggingface" "$PKG" "$UTMP" /private/tmp /Library/Caches)
for d in "${CANARIES[@]}"; do printf 'TEE-SWEEP-CANARY\n' > "$d/tee-canary.txt" || echo "cannot plant in $d"; done
rm -rf "$RUN"; mkdir -p "$RUN"; printf 'r5 owndir probe\n' > "$RUN/r5-owndir-probe"
START=$(date '+%Y-%m-%d %H:%M:%S')

# --- 1a. Sealed probe build through the launcher and server (serving phase).
rm -f /tmp/sealed-reason.log
./stage-child.sh build-tee > /dev/null
S=$(./smoke.sh tee-probe-$(date +%F) | head -1)
cp /tmp/sealed-reason.log "$RUN/sealed.log" 2>/dev/null
if echo "$S" | grep -q '^PASS'; then v PASS "[serve-with-probes] $S"; else v FAIL "[serve-with-probes] $S"; fi
L="$RUN/sealed.log"
for ph in sandboxed loaded serving; do
  for k in ports fds environ; do
    line=$(grep -m1 "^tee-probe $ph $k" "$L")
    if [ -n "$line" ]; then v INFO "[record-$ph-$k] ${line#tee-probe }"; else v FAIL "[record-$ph-$k] missing"; fi
  done
done
# Port and descriptor sets must not change between loaded and serving.
# Port names: no new send right may appear between "loaded" and "serving"
# (a new send right could be a new connection; released rights are recorded).
d=$(grep -m1 "^tee-probe serving ports-diff" "$L")
echo "$d" | grep -q "added-send=0 " && v PASS "[no-new-send-rights-loaded-to-serving] ${d#tee-probe serving }" || v FAIL "[no-new-send-rights-loaded-to-serving] ${d:-missing}"
a=$(grep -m1 "^tee-probe loaded fds" "$L" | sed 's/.*fds //'); b=$(grep -m1 "^tee-probe serving fds" "$L" | sed 's/.*fds //')
[ -n "$a" ] && [ "$a" = "$b" ] && v PASS "[fds-stable-loaded-to-serving] $a" || v FAIL "[fds-stable-loaded-to-serving] loaded=($a) serving=($b)"
# Read sweep: every canary denied with EPERM.
n=$(grep -c "^tee-probe sweep " "$L"); bad=$(grep "^tee-probe sweep " "$L" | grep -vc "rc=-1 errno=1 ")
[ "$n" -ge 14 ] && [ "$bad" = 0 ] && v PASS "[read-sweep] $n canary paths, all EPERM" || v FAIL "[read-sweep] $n paths, $bad not EPERM: $(grep '^tee-probe sweep ' "$L" | grep -v 'rc=-1 errno=1 ' | head -3 | tr '\n' ';')"
# Operation classes: shm_open, spawn, fork, kill, IOKit opens must be refused.
chk() { local arm=$1 want=$2 line; line=$(grep -m1 "^tee-probe op $arm" "$L")
  if echo "$line" | grep -Eq "$want"; then v PASS "[op-$arm] ${line#tee-probe op }"; else v FAIL "[op-$arm] ${line:-missing} (want $want)"; fi; }
chk shm_open "rc=-1 errno=1$"
chk posix_spawn "rc=1$"
chk fork "rc=-1 errno=1$"
chk kill-parent-sig0 "rc=-1 errno=1$"
# IOKit: a sandbox refusal counts only where the unsandboxed control opens
# the same class (checked in 1b); the other classes are recorded.
for c in AppleSMC IOHIDSystem AppleKeyStore IOFramebuffer; do
  line=$(grep -m1 "^tee-probe op iokit-open $c " "$L")
  case $c in
    AppleSMC|AppleKeyStore) echo "$line" | grep -q "kr=0xe00002e2$" && v PASS "[op-iokit-$c] refused (kIOReturnNotPermitted): ${line#tee-probe op }" || v FAIL "[op-iokit-$c] ${line:-missing}" ;;
    *) v INFO "[op-iokit-$c] ${line#tee-probe op } (no valid control: the class is absent or refuses unsandboxed callers too)" ;;
  esac
done
for a in sysctl-write ioctl-fiodtype fsctl-sync; do line=$(grep -m1 "^tee-probe op $a" "$L"); v INFO "[op-$a] ${line#tee-probe op } (recorded)"; done
# Mach lookups: every listed service refused (1100) or unknown (1102).
# 1100 = refused by the sandbox. 1102 = no such global name (only
# com.apple.MTLCompilerService, an XPC bundle service, answers so).
n=$(grep -c "^tee-probe lookup " "$L"); ok=$(grep "^tee-probe lookup " "$L" | grep -Ec "kr=1100 |kr=1102 com.apple.MTLCompilerService$")
[ "$n" -ge 16 ] && [ "$n" = "$ok" ] && v PASS "[mach-lookups] $n services, all refused: $(grep '^tee-probe lookup ' "$L" | awk '{print $3}' | sort | uniq -c | tr '\n' ' ')" \
  || v FAIL "[mach-lookups] $n services, $ok refused: $(grep '^tee-probe lookup ' "$L" | grep -Ev 'kr=(1100|1102) ' | head -4 | tr '\n' ';')"
# A-17: the consumed extension grants nothing.
line=$(grep -m1 "^tee-probe ext consume" "$L")
echo "$line" | grep -q "read rc=-1 errno=1$" && v PASS "[A-17-extension-no-grant] ${line#tee-probe }" || v FAIL "[A-17-extension-no-grant] ${line:-missing}"

# --- 1b. Controls through the test spawner (sandboxed phase only).
ctl() {  # ctl <tag> <build>
  cp splash/$2/splash "$RUN/splash-$2" && sign "$RUN/splash-$2"
  rm -f /tmp/sealed-reason.log
  neg/B/r2neg "$RUN/splash-$2" "$PKG" control > /dev/null 2>&1
  cp /tmp/sealed-reason.log "$RUN/$1.log" 2>/dev/null
}
ctl control build-tee-nosb
C="$RUN/control.log"
n=$(grep "^tee-probe sweep " "$C" | grep -c "rc=0 "); v $([ "$n" -ge 10 ] && echo PASS || echo FAIL) "[control-read-sweep] unsandboxed build read $n canaries (the oracle can see a read)"
for a in shm_open fork kill-parent-sig0; do line=$(grep -m1 "^tee-probe op $a" "$C"); echo "$line" | grep -q "rc=0" && v PASS "[control-op-$a] ${line#tee-probe op }" || v INFO "[control-op-$a] ${line:-missing}"; done
line=$(grep -m1 "^tee-probe op posix_spawn" "$C"); echo "$line" | grep -q "rc=0$" && v PASS "[control-op-posix_spawn] ${line#tee-probe op }" || v INFO "[control-op-posix_spawn] ${line:-missing}"
for c in AppleSMC AppleKeyStore; do line=$(grep -m1 "^tee-probe op iokit-open $c " "$C"); echo "$line" | grep -q "kr=0x0$" && v PASS "[control-op-iokit-$c] unsandboxed opens it: ${line#tee-probe op }" || v FAIL "[control-op-iokit-$c] ${line:-missing}"; done
ok=$(grep "^tee-probe lookup " "$C" | grep -c "kr=0 "); v $([ "$ok" -ge 8 ] && echo PASS || echo FAIL) "[control-mach-lookups] unsandboxed build reached $ok services"
ctl extctl build-tee-ext
line=$(grep -m1 "^tee-probe ext consume" "$RUN/extctl.log")
echo "$line" | grep -q "read rc=0 " && v PASS "[A-17-control-extension-grants] with an (extension ...) rule: ${line#tee-probe }" || v FAIL "[A-17-control-extension-grants] ${line:-missing}"

# --- 2. os_log canaries: the sandboxed build's must be absent; the control's present.
sleep 3
LOGS=$(log show --style compact --start "$START" --predicate 'eventMessage CONTAINS "TEE-OSLOG-CANARY"' 2>/dev/null)
s=$(echo "$LOGS" | grep -c "TEE-OSLOG-CANARY-sandboxed"); c=$(echo "$LOGS" | grep -c "TEE-OSLOG-CANARY-control")
v $([ "$c" -ge 1 ] && echo PASS || echo FAIL) "[oslog-control-visible] unsandboxed canary lines in log show: $c"
v $([ "$s" = 0 ] && echo PASS || echo INFO) "[oslog-sandboxed] sandboxed canary lines in log show: $s (0 = os_log is not an output channel; >0 = keep os_log off the import allowlist)"
imp=$(nm -u splash/build/splash | grep -ciE "os_log|NSLog|syslog|asl_|os_trace|CFLog|xpc_|dlopen|dlsym|sandbox_extension|_IOSurface|newSharedEventHandle|sendmsg|_fork")
v $([ "$imp" = 0 ] && echo PASS || echo FAIL) "[import-allowlist] production child imports of os_log/NSLog/syslog/asl/xpc/dlopen/dlsym/sandbox_extension/IOSurface/sendmsg/fork: $imp"

# --- 3. Crash reports (A-20, R1): canary in registers, then a crash.
crash() {  # crash <tag> <build>
  cp splash/$2/splash "$RUN/splash-$2" && sign "$RUN/splash-$2"
  touch "$RUN/t0.$1"
  rm -f /tmp/sealed-reason.log
  neg/B/r2neg "$RUN/splash-$2" "$PKG" control > "$RUN/$1.r2" 2>&1
  sleep 20   # ReportCrash writes the report after the process dies
  local hits=0 reports=0
  for f in $(find ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports -newer "$RUN/t0.$1" -type f 2>/dev/null); do
    case "$f" in *splash*) reports=$((reports + 1)); grep -q -i -e "5445454341524159" -e "6072335827740016985" "$f" && hits=$((hits + 1)); echo "$f" >> "$RUN/$1.reports";; esac
  done
  echo "$reports $hits $(tail -1 "$RUN/$1.r2")"
}
read r h rest <<< "$(crash crash-nor1 build-crash-nor1)"
v $([ "$h" -ge 1 ] && echo PASS || echo FAIL) "[A-20-control-no-guard] reports=$r with-canary=$h | $rest (the oracle can see the canary)"
read r h rest <<< "$(crash crash-r1 build-crash)"
v $([ "$h" = 0 ] && echo PASS || echo FAIL) "[A-20-crash-with-guard] reports=$r with-canary=$h | $rest"

# Clean up: canaries, scratch, and restage the production child.
for d in "${CANARIES[@]}"; do rm -f "$d/tee-canary.txt"; done
./stage-child.sh > /dev/null
rm -rf "$RUN" /tmp/sealed-reason.log
echo "# result: $fails failed" >> $O
cat $O
[ $fails = 0 ]
