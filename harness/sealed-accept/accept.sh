#!/bin/bash
# Device acceptance run for the sealed Splash stack (see DESIGN.md).
# Runs the verification on this Mac (or on a remote Mac over ssh) and writes
# one JSON report: reports/<hw.model>-<osbuild>-<utcstamp>.json, with the raw
# outputs in the folder of the same name.
#
# Level A: preflight, source identity, artifacts, then
#   (a) neg/run-all.sh (the child negative suite),
#   (b) the engine evidence suite (sealed-engine-v2/scripts/evidence.sh),
#   (c) one consumer chat through tools/tee-rootkit/sealed-chat, with a
#       wrong-CD-hash control.
# Level B: A, then the installed root kit hashes, then
#   sudo -n /usr/local/libexec/tee-rootkit/tee-rootpass.sh --yes
#   (the only sudo call; without the grant the root suite is SKIP).
#
# Fail closed: a check without evidence is SKIP, never PASS. A PASS whose
# control did not fire becomes INCONCLUSIVE.
#
# Usage: accept.sh --level A|B [--out DIR] [--dry-run] [--wait SECS]
#        accept.sh --remote SSH-HOST --level A|B [--out DIR] [--dry-run]
#   --dry-run  local: preflight, identity and artifacts only; the suites are
#              SKIP. remote: print the ssh/scp commands, contact nothing.
#   --wait     seconds to wait for another suite run to end (default 7200).
# Exit: 0 the level is ACCEPTED, 1 REJECTED (a FAIL), 2 INCOMPLETE, 64 usage.
set -u
# The child build ID records the toolchain; the pinned child is an Xcode build (audit R5-5-01).
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
TOOL_VERSION=3
SELF=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
M=${SEALED_M5:-$HOME/projects/sealed-backends-spike/sealed-m5}
P=${MORPHEUS_PNODE:-$HOME/projects/morpheus-pnode}
E=$P/sealed-engine-v2
APP=$E/build/SealedEngineV2.app
BRANCH=feat/sealed-v2-splash-engine
KIT=$M/tools/tee-rootkit
RK=/usr/local/libexec/tee-rootkit
ROOTCMD=$RK/tee-rootpass.sh
SUDO=/usr/bin/sudo
ENGINE_PORT=29452

LEVEL=""; REMOTE=""; OUT=""; DRY=0; WAIT=7200
usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 64; }
while [ $# -gt 0 ]; do
  case "$1" in
    --level) LEVEL=${2:-}; shift 2 ;;
    --remote) REMOTE=${2:-}; shift 2 ;;
    --out) OUT=${2:-}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --wait) WAIT=${2:-}; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
case "$LEVEL" in A|B) ;; C) echo "level C (rebuild compare, second-party attestation) is not implemented" >&2; exit 64 ;; *) usage ;; esac
case "$WAIT" in ''|*[!0-9]*) echo "--wait needs seconds" >&2; exit 64 ;; esac
OUT=${OUT:-$(dirname "$SELF")/reports}

# --- Remote mode: copy this script, run it there, fetch the report folder.
if [ -n "$REMOTE" ]; then
  case "$REMOTE" in -*|*[[:space:]]*) echo "bad ssh host: $REMOTE" >&2; exit 64 ;; esac
  RD=".sealed-accept-remote/$(date -u +%Y%m%dT%H%M%SZ)"
  RARGS="--level $LEVEL --wait $WAIT --out \$HOME/$RD/reports"
  CMDS=(
    "ssh -o BatchMode=yes $REMOTE mkdir -p '\$HOME/$RD'"
    "scp -q $SELF $REMOTE:$RD/accept.sh"
    "ssh -o BatchMode=yes $REMOTE bash \"\$HOME/$RD/accept.sh\" $RARGS"
    "mkdir -p $OUT && scp -q -r $REMOTE:$RD/reports/. $OUT/"
  )
  if [ $DRY = 1 ]; then
    echo "DRY-RUN (not run): remote acceptance on $REMOTE, level $LEVEL"
    for c in "${CMDS[@]}"; do echo "  $c"; done
    exit 0
  fi
  ssh -o BatchMode=yes "$REMOTE" "mkdir -p \"\$HOME/$RD\"" || { echo "ssh to $REMOTE failed" >&2; exit 2; }
  scp -q "$SELF" "$REMOTE:$RD/accept.sh" || { echo "scp to $REMOTE failed" >&2; exit 2; }
  ssh -o BatchMode=yes "$REMOTE" "bash \"\$HOME/$RD/accept.sh\" $RARGS"
  rc=$?
  mkdir -p "$OUT" && scp -q -r "$REMOTE:$RD/reports/." "$OUT/" || { echo "fetching the report from $REMOTE failed" >&2; exit 2; }
  echo "remote run exit $rc; reports copied to $OUT (remote copy stays in ~/$RD on $REMOTE)"
  exit $rc
fi

# --- One run at a time on this Mac.
LOCK=/tmp/sealed-accept.lock
mkdir "$LOCK" 2>/dev/null || { echo "another accept.sh holds $LOCK (pid $(cat "$LOCK/pid" 2>/dev/null))" >&2; exit 2; }
echo $$ > "$LOCK/pid"
# The shared suite lock (tools/suite-lock.sh) for the whole run: the suites
# that accept.sh starts run inside it, and any other suite run refuses to
# start (audit R4-4-04).
SUITE_LOCK=/tmp/sealed-suite.lock
if ! mkdir "$SUITE_LOCK" 2>/dev/null; then
  who=$(cat "$SUITE_LOCK/pid" 2>/dev/null)
  if [ -n "$who" ] && ! kill -0 "$who" 2>/dev/null; then rm -rf "$SUITE_LOCK"; mkdir "$SUITE_LOCK" 2>/dev/null
  else echo "suite lock $SUITE_LOCK is held by pid ${who:-?} ($(cat "$SUITE_LOCK/name" 2>/dev/null))" >&2; rm -rf "$LOCK"; exit 2; fi
fi
echo $$ > "$SUITE_LOCK/pid"; echo accept.sh > "$SUITE_LOCK/name"
export SEALED_SUITE_LOCK_HELD=1
PROFILE_TMP=""; NEG_BACKUP=""; NEG_FINAL=""
cleanup() {
  [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null
  [ -n "${STEP_PID:-}" ] && kill "$STEP_PID" 2>/dev/null
  [ -n "$PROFILE_TMP" ] && rm -f "$PROFILE_TMP"
  if [ -n "$NEG_BACKUP" ] && [ -f "$NEG_BACKUP" ]; then cp -p "$NEG_BACKUP" "$NEG_FINAL"; rm -f "$NEG_BACKUP"; fi
  rm -rf "$LOCK" "$SUITE_LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

MODEL=$(sysctl -n hw.model)
OSB=$(sw_vers -buildVersion)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BASE="$MODEL-$OSB-$STAMP"
mkdir -p "$OUT" || exit 2
OUT=$(cd "$OUT" && pwd -P)
EV=$OUT/$BASE
mkdir -p "$EV" || exit 2
: > "$EV/facts.tsv"; : > "$EV/results.tsv"; : > "$EV/steps.tsv"
log() { echo "[accept $(date '+%T')] $*" >&2; }
fact() { printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t\n' '  ')" >> "$EV/facts.tsv"; }
# res <name> <level> <status> <control> <evidence>
res() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(printf '%s' "$5" | tr '\t\n' '  ' | cut -c1-600)" >> "$EV/results.tsv"; log "$3 $1"; }
# step <name> <RAN|SKIP> <rc> <output file> <reason>
step() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$EV/steps.tsv"; }
# Other processes that use the sealed kit (test children, spawners, suites,
# builds, the root kit) share /tmp/sealed-reason.log, the scratch folders and
# the ports. procs.awk lists them, leaving out the step's own process tree,
# this script, the engines and the engines' children.
cat > "$EV/procs.awk" <<'AWK'
{ c = $0; sub(/^ *[0-9]+ +[0-9]+ /, "", c); par[$1] = $2; cmd[$1] = c; ord[NR] = $1 }
END {
  for (i = 1; i <= NR; i++) {
    p = ord[i]; c = cmd[p]
    # Absolute and relative forms of the suite commands (audit R4-4-04).
    if (c !~ /sealed-m5\/|serve-native|tee-rootkit|SEALED_DEFS|neg\/(run|build)-all|r2neg|sealed-launch|run-sealed-server|evidence\.sh|child-repro-check|stage-child|splash\/build/) continue
    if (c ~ /sealed-accept\/|SealedEngine|tee-rootkit\/fake\//) continue
    if (cmd[par[p]] ~ /SealedEngine/) continue
    q = p; mine = 0
    for (k = 0; k < 64 && q > 1; k++) { if (q == root) { mine = 1; break }; q = par[q] }
    if (!mine) print p, c
  }
}
AWK
# foreign [step pid]: one line per other process, "pid command".
foreign() { ps -axo pid=,ppid=,command= | awk -v root="${1:-0}" -f "$EV/procs.awk"; }
busy() { foreign | awk '{print $1}' | paste -sd, -; }
# Records other processes while the step <pid> runs. Usage: watch_start <file> <pid>; watch_stop
WATCH_PID=""; STEP_PID=""
watch_start() {
  ( while kill -0 "$2" 2>/dev/null; do foreign "$2" | sed "s/^/$(date +%T) /" >> "$1"; sleep 3; done ) &
  WATCH_PID=$!
}
watch_stop() { [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; WATCH_PID=""; }
# run_step <foreign file> <output file> <command...>: runs the command in the
# background under the watcher, returns its exit code.
run_step() {
  local f=$1 o=$2 rc; shift 2
  "$@" > "$o" 2>&1 &
  STEP_PID=$!
  watch_start "$f" "$STEP_PID"
  wait "$STEP_PID"; rc=$?
  STEP_PID=""; watch_stop
  return $rc
}
# Name, mtime and size of the inputs a step reads (test builds, spawner, child,
# launcher, tools, model package, child sources). A change during the step
# means another run or an edit touched them.
snapshot() {
  (cd "$M" && { find child neg/B launcher tools pkg/qwen38-27b -type f 2>/dev/null
                find splash \( -path 'splash/build*' -prune \) -o -type f -print 2>/dev/null
                ls -d splash/build*/splash 2>/dev/null; } | sort | tr '\n' '\0' | xargs -0 stat -f '%N %m %z') > "$1"
}
# isolated <step> <before> <after> <foreign file>: records the step's isolation facts.
isolated() {
  local d f
  d=$(diff "$2" "$3" | grep -c '^[<>]'); f=$( [ -s "$4" ] && cut -d' ' -f3- "$4" | sort -u | head -5 | paste -sd ';' - )
  fact "$1_inputs_changed" "$d"; fact "$1_foreign" "$f"
}
wait_idle() {
  local t=0 b
  while b=$(busy); [ -n "$b" ]; do
    [ $t -ge "$WAIT" ] && { echo "$b"; return 1; }
    [ $t = 0 ] && log "waiting for another suite run to end (pids $b)"
    sleep 15; t=$((t + 15))
  done
  return 0
}
engine_pids() { pgrep -f "$APP/Contents/MacOS/SealedEngine"; }
listening() { lsof -nP -iTCP:$ENGINE_PORT -sTCP:LISTEN -t > /dev/null 2>&1; }

fact tool_version $TOOL_VERSION
fact tool_sha256 "$(shasum -a 256 "$SELF" | awk '{print $1}')"
# Keep the exact harness and gate code that made this report, so the report's
# tool_sha256 can always be checked against a file (audit R2-4-06).
mkdir -p "$EV/harness" && cp -p "$SELF" "$EV/harness/accept.sh" && cp -p "$(dirname "$SELF")/matrix.py" "$(dirname "$SELF")/required.json" "$EV/harness/" 2>/dev/null
fact harness_copy "harness/"
fact required_sha256 "$(shasum -a 256 "$(dirname "$SELF")/required.json" | awk '{print $1}')"
fact requested_level "$LEVEL"
fact dry_run $DRY
fact started_utc "$(date -u +%FT%TZ)"
fact host "$(hostname -s)"
fact report_base "$BASE"

# --- Preflight
log "preflight"
fact hw.model "$MODEL"
fact hw.ncpu "$(sysctl -n hw.ncpu)"
fact memsize "$(sysctl -n hw.memsize)"
fact macos "$OSB"
fact macos_version "$(sw_vers -productVersion)"
fact page_size "$(sysctl -n hw.pagesize)"
fact free_disk_bytes "$(df -k "$M" 2>/dev/null | awk 'NR==2{print $4 * 1024}')"
CSR=$(csrutil status 2>&1); fact csrutil "$CSR"
fact authenticated_root "$(csrutil authenticated-root status 2>&1 | tail -1)"
case "$CSR" in
  *"status: enabled."*) fact sip enabled; res preflight/sip-enabled A PASS NA "$CSR" ;;
  "") fact sip unknown; res preflight/sip-enabled A SKIP NA "csrutil gave no output" ;;
  *) fact sip "not enabled"; res preflight/sip-enabled A FAIL NA "$CSR" ;;
esac

# --- Source identity
log "source identity"
fact engine_repo "$P"
fact engine_branch_wanted "$BRANCH"
if git -C "$P" rev-parse --verify -q "refs/heads/$BRANCH" > /dev/null 2>&1; then
  BC=$(git -C "$P" rev-parse "refs/heads/$BRANCH"); HC=$(git -C "$P" rev-parse HEAD); CB=$(git -C "$P" branch --show-current)
  fact engine_commit "$BC"; fact engine_head "$HC"; fact engine_branch_checked_out "$CB"
  if [ "$CB" = "$BRANCH" ] && [ "$HC" = "$BC" ]; then res source/engine-branch A PASS NA "HEAD is $BRANCH at $BC"
  else res source/engine-branch A FAIL NA "checked out '$CB' at $HC; $BRANCH is $BC (the scripts run from the checkout)"; fi
  DIRTY=$(git -C "$P" status --porcelain --untracked-files=no -- sealed-engine-v2 proxy-router | paste -sd ';' -)
  fact engine_dirty_tracked "$DIRTY"
  [ -z "$DIRTY" ] && res source/engine-tree-clean A PASS NA "no tracked changes under sealed-engine-v2/ or proxy-router/" \
    || res source/engine-tree-clean A FAIL NA "tracked changes: $DIRTY"
else
  fact engine_commit ""
  res source/engine-branch A SKIP NA "no branch $BRANCH in $P"
  res source/engine-tree-clean A SKIP NA "no branch $BRANCH in $P"
fi
if [ -f "$M/child/splash" ]; then
  IDS=$(strings -a "$M/child/splash" | grep -oE 'src-[0-9a-f]{64}' | sort -u)
  n=$(printf '%s' "$IDS" | grep -c .)
  if [ "$n" = 1 ]; then
    fact SPLASH_BUILD_ID "$IDS"; fact child_source_hash "${IDS#src-}"
    res source/child-build-id A PASS NA "child/splash embeds one build id: $IDS"
  else
    fact SPLASH_BUILD_ID ""; fact child_source_hash ""
    res source/child-build-id A FAIL NA "child/splash embeds $n build ids: $(echo $IDS)"
  fi
else
  fact SPLASH_BUILD_ID ""; fact child_source_hash ""
  res source/child-build-id A SKIP NA "no child/splash"
fi
# The child source is its own git repo (splash/). The staged child must come
# from a clean tree at a commit (audit R4-S1).
CS=$M/splash
if git -C "$CS" rev-parse --verify -q HEAD > /dev/null 2>&1; then
  CC=$(git -C "$CS" rev-parse HEAD); fact child_commit "$CC"
  CDIRTY=$(git -C "$CS" status --porcelain | paste -sd ';' -); fact child_dirty "$CDIRTY"
  res source/child-commit A PASS NA "splash/ is at commit $CC"
  [ -z "$CDIRTY" ] && res source/child-tree-clean A PASS NA "no changes in splash/ (tracked or untracked, .gitignore applied)" \
    || res source/child-tree-clean A FAIL NA "splash/ has changes: $CDIRTY"
else
  fact child_commit ""; res source/child-commit A FAIL NA "splash/ is not a git repo"
  res source/child-tree-clean A FAIL NA "splash/ is not a git repo"
fi
# The harness tree (sealed-m5) is a git repo too: record its commit and refuse
# changes to the files a run executes (audit R4-4-03, R4-4-06).
if git -C "$M" rev-parse --verify -q HEAD > /dev/null 2>&1; then
  HCM=$(git -C "$M" rev-parse HEAD); fact harness_commit "$HCM"
  # Tracked files only. The daily suite records neg/final-*.txt are tracked
  # output, not executed, so the check leaves them out (audit R5-5-02).
  HDIRTY=$(git -C "$M" status --porcelain --untracked-files=no -- sealed-accept/accept.sh sealed-accept/matrix.py sealed-accept/required.json sealed-accept/approved-harness.txt sealed-accept/approved-required.txt sealed-accept/approved-matrix.txt child/pin.txt child/req-splash.bin neg ':(exclude)neg/final-*.txt' tools stage-child.sh run-sealed-server.sh | paste -sd ';' -)
  fact harness_dirty "$HDIRTY"
  [ -z "$HDIRTY" ] && res source/harness-tree-clean A PASS NA "sealed-m5 at $HCM; no changes in the harness, neg suite or tools" \
    || res source/harness-tree-clean A FAIL NA "sealed-m5 has changes in executed files: $HDIRTY"
else
  fact harness_commit ""; res source/harness-tree-clean A FAIL NA "sealed-m5 is not a git repo"
fi
# The child and the engine compile the same R1 guard from two copies; they
# must be byte-identical (audits R4-H2, R4-E-07).
GE=$E/Sources/SealedSpawnC; GC=$M/splash/runtime/sealed/guard
if cmp -s "$GE/sealed_guard.c" "$GC/sealed_guard.c" && cmp -s "$GE/include/sealed_guard.h" "$GC/sealed_guard.h"; then
  res source/guard-copies-equal A PASS NA "sealed_guard.c $(shasum -a 256 "$GC/sealed_guard.c" | cut -c1-16) and sealed_guard.h $(shasum -a 256 "$GC/sealed_guard.h" | cut -c1-16): engine and child copies are byte-identical"
else
  res source/guard-copies-equal A FAIL NA "engine ($GE) and child ($GC) copies of sealed_guard differ"
fi
TREE_ID=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["build_id"])' "$M/splash/build/engine/build-identity.json" 2>/dev/null)
fact splash_tree_build_id "$TREE_ID"
# The staged child must be a production build of the current source: the
# build ID is recomputed with the production flags and compared with the one
# embedded in child/splash (audit R3-P1).
if CHK=$(cd "$M/splash" && make -s check-build-identity SEALED_DEFS=-DSPLASH_SEALED BINARY=../child/splash 2>&1); then
  res source/child-is-current-production A PASS NA "child/splash: $(echo "$CHK" | tr -d '\n')"
else
  res source/child-is-current-production A FAIL NA "child/splash is not a production build of the current source: $(echo "$CHK" | tail -1)"
fi

# --- Artifacts
log "artifacts"
CPIN=$(cat "$M/child/pin.txt" 2>/dev/null)
fact child_pin "$CPIN"
if [ -f "$M/child/splash" ]; then
  CD=$(codesign -dvvv "$M/child/splash" 2>&1 | awk -F= '/^CDHash=/{print $2}')
  CDF=$(codesign -dvvv "$M/child/splash" 2>&1 | awk -F'sha256=' '/^CandidateCDHashFull sha256=/{print $2}')
  fact child_cdhash "$CD"; fact child_cdhash_full "$CDF"
  V=$(codesign --verify --strict "$M/child/splash" 2>&1); vr=$?
  if [ $vr = 0 ] && [ -n "$CD" ] && [ "$CD" = "$CPIN" ]; then res artifacts/child-pin A PASS NA "child/splash CD hash $CD = child/pin.txt; signature verifies"
  else res artifacts/child-pin A FAIL NA "CD hash '$CD', pin '$CPIN', codesign --verify rc=$vr $V"; fi
else
  fact child_cdhash ""; res artifacts/child-pin A SKIP NA "no child/splash"
fi
if [ -d "$APP" ]; then
  ECD=$(codesign -d --verbose=4 "$APP" 2>&1 | awk -F'sha256=' '/CandidateCDHashFull sha256=/{print $2}')
  fact engine_cdhash "$ECD"
  fact engine_identifier "$(codesign -dvvv "$APP" 2>&1 | awk -F= '/^Identifier=/{print $2}')"
  V=$(codesign --verify --strict "$APP" 2>&1); vr=$?
  if [ $vr = 0 ] && [ ${#ECD} = 64 ]; then res artifacts/engine-signature A PASS NA "SealedEngineV2.app verifies (--strict); CD hash $ECD"
  else res artifacts/engine-signature A FAIL NA "codesign --verify rc=$vr $V; CD hash '$ECD'"; fi
else
  ECD=""; fact engine_cdhash ""; res artifacts/engine-signature A SKIP NA "no $APP"
fi
# Model hash as tools/tee-rootkit/build.sh makes it (package + child pin).
MH=""
[ -n "$CPIN" ] && MH=$(python3 "$E/scripts/model-hash.py" "$M/pkg/qwen38-27b" "$CPIN" 2>/dev/null | awk '/^model/{print $2}')
fact model_hash "$MH"
APPID=$(cat "$KIT/engine-appid" 2>/dev/null)
fact engine_appid "$APPID"
fact kit_engine_cdhash "$(cat "$KIT/engine-cdhash" 2>/dev/null)"
fact kit_engine_modelhash "$(cat "$KIT/engine-modelhash" 2>/dev/null)"
KC=$(cat "$KIT/engine-cdhash" 2>/dev/null); KM=$(cat "$KIT/engine-modelhash" 2>/dev/null)
if [ -n "$ECD" ] && [ "$KC" = "$ECD" ] && [ -n "$MH" ] && [ "$KM" = "$MH" ]; then res artifacts/kit-pins-equal A PASS NA "tools/tee-rootkit pins engine $KC and model $KM, equal to the measured artifacts"
else res artifacts/kit-pins-equal A FAIL NA "kit engine '$KC' model '$KM'; measured engine '$ECD' model '$MH' (rebuild the kit)"; fi

ENGINE_WAS_RUNNING=0; [ -n "$(engine_pids)" ] && ENGINE_WAS_RUNNING=1
fact engine_running_before $ENGINE_WAS_RUNNING

# --- (a) child negative suite
if [ $DRY = 1 ]; then step neg SKIP "" "" "dry run"
elif ! b=$(wait_idle); then step neg SKIP "" "" "another suite run did not end within ${WAIT}s (pids $b)"
elif [ ! -x "$M/neg/run-all.sh" ]; then step neg SKIP "" "" "no neg/run-all.sh"
elif ! BCHK=$(bash "$M/neg/build-all.sh" --check 2>&1); then
  # A test build whose build ID differs from the current source tests a
  # different child (audits R2-N1, R3-G1). Recomputed with each build's own
  # flags, so every source that feeds the build ID counts.
  echo "$BCHK" > "$EV/neg-build-check.txt"
  step neg FAIL "" neg-build-check.txt "test builds do not match the current source; run neg/build-all.sh first ($(echo "$BCHK" | grep -c '^STALE') stale)"
else
  echo "$BCHK" > "$EV/neg-build-check.txt"
  log "(a) neg/run-all.sh (about 10 minutes)"
  # run-all.sh writes neg/final-<date>.txt; keep an existing record of that date.
  NEG_FINAL=$M/neg/final-$(date +%F).txt
  if [ -f "$NEG_FINAL" ]; then NEG_BACKUP=$(mktemp /tmp/sealed-accept-negfinal.XXXXXX); cp -p "$NEG_FINAL" "$NEG_BACKUP"; fi
  snapshot "$EV/neg-inputs-before.txt"
  run_step "$EV/neg-foreign.txt" "$EV/neg-run-all.txt" bash -c 'cd "$1" && exec bash neg/run-all.sh' run-all "$M"
  rc=$?
  snapshot "$EV/neg-inputs-after.txt"
  isolated neg "$EV/neg-inputs-before.txt" "$EV/neg-inputs-after.txt" "$EV/neg-foreign.txt"
  if [ -n "$NEG_BACKUP" ]; then cp -p "$NEG_BACKUP" "$NEG_FINAL"; rm -f "$NEG_BACKUP"; NEG_BACKUP=""; fi
  step neg RAN $rc neg-run-all.txt ""
fi

# --- (b) engine evidence suite
if [ $DRY = 1 ]; then step engine SKIP "" "" "dry run"
elif ! b=$(wait_idle); then step engine SKIP "" "" "another suite run did not end within ${WAIT}s (pids $b)"
elif [ ! -f "$APP/Contents/embedded.provisionprofile" ] || [ ! -f "$E/scripts/evidence.sh" ]; then
  step engine SKIP "" "" "no evidence.sh or no embedded provisioning profile in $APP"
else
  log "(b) sealed-engine-v2/scripts/evidence.sh (child rebuild twice, engine rebuild, engine restart)"
  # A temp copy of the app's own profile: evidence.sh reads it, the app keeps its file.
  PROFILE_TMP=$(mktemp /tmp/sealed-accept-profile.XXXXXX)
  cp "$APP/Contents/embedded.provisionprofile" "$PROFILE_TMP"
  before=$(ls "$E/build"/evidence-*.txt 2>/dev/null | sort | tail -1)
  snapshot "$EV/engine-inputs-before.txt"
  run_step "$EV/engine-foreign.txt" "$EV/engine-evidence.txt" bash "$E/scripts/evidence.sh" "$PROFILE_TMP"
  rc=$?
  # Apple's devicecheck service answers "Code=0 (null)" now and then; a retry
  # after a pause is the fix, and the attempt is recorded in the step reason.
  tries=1
  while [ $rc -ne 0 ] && [ $tries -lt 3 ] && grep -q "devicecheck" "$EV/engine-evidence.txt" 2>/dev/null; do
    log "engine evidence attempt $tries failed on devicecheck; retrying in 30 s"
    sleep 30
    tries=$((tries + 1))
    run_step "$EV/engine-foreign.txt" "$EV/engine-evidence.txt" bash "$E/scripts/evidence.sh" "$PROFILE_TMP"
    rc=$?
  done
  engine_retries=$tries; fact engine_attempts "$tries"
  snapshot "$EV/engine-inputs-after.txt"
  isolated engine "$EV/engine-inputs-before.txt" "$EV/engine-inputs-after.txt" "$EV/engine-foreign.txt"
  rm -f "$PROFILE_TMP"; PROFILE_TMP=""
  after=$(ls "$E/build"/evidence-*.txt 2>/dev/null | sort | tail -1)
  [ -n "$after" ] && [ "$after" != "$before" ] && cp "$after" "$EV/" && fact engine_evidence_file "$after"
  attempt_note=""
  [ "${engine_retries:-0}" -gt 1 ] && attempt_note="attempts=${engine_retries}"
  step engine RAN $rc engine-evidence.txt "$attempt_note"
fi

# --- (c) consumer chat round trip, pinned to the measured engine CD hash and model hash
CHAT=$KIT/sealed-chat
if [ $DRY = 1 ]; then res consumer/chat A SKIP NA "dry run"
elif [ ! -x "$CHAT" ]; then res consumer/chat A SKIP NA "no $CHAT"
elif ! (cd "$KIT" && grep ' sealed-chat$' SHA256SUMS | shasum -a 256 -c -s); then res consumer/chat A FAIL NA "$CHAT differs from the kit's SHA256SUMS"
elif [ ${#ECD} != 64 ] || [ ${#MH} != 64 ] || [ -z "$APPID" ]; then res consumer/chat A SKIP NA "no pins: engine CD hash '$ECD', model hash '$MH', app id '$APPID'"
elif ! listening; then res consumer/chat A SKIP NA "no engine listening on :$ENGINE_PORT"
else
  log "(c) consumer chat"
  "$CHAT" --engine http://127.0.0.1:$ENGINE_PORT --app-id "$APPID" --cdhash "$ECD" --weights "$MH" > "$EV/consumer-chat.txt" 2>&1
  crc=$?
  # Control: the same request pinned to a wrong CD hash must be refused.
  "$CHAT" --engine http://127.0.0.1:$ENGINE_PORT --app-id "$APPID" --cdhash "$(printf '%064d' 1)" --weights "$MH" > "$EV/consumer-chat-control.txt" 2>&1
  CTL=FAIL; grep -q '^FAIL.*code identity' "$EV/consumer-chat-control.txt" && ! grep -q '^REPLY' "$EV/consumer-chat-control.txt" && CTL=PASS
  R=$(grep -m1 '^REPLY' "$EV/consumer-chat.txt")
  if [ $crc = 0 ] && grep -q '^REPLY.*"Paris"' "$EV/consumer-chat.txt" && grep -q 'matches the pinned hash' "$EV/consumer-chat.txt"; then
    if [ $CTL = PASS ]; then res consumer/chat A PASS PASS "consumer-chat.txt: $R; CD hash $ECD attested and matches the pinned hash; control consumer-chat-control.txt: wrong CD hash refused"
    else res consumer/chat A INCONCLUSIVE FAIL "consumer-chat.txt: $R; control did not fire: $(tail -1 "$EV/consumer-chat-control.txt")"; fi
  else res consumer/chat A FAIL $CTL "consumer-chat.txt rc=$crc: $(tail -1 "$EV/consumer-chat.txt")"; fi
fi

# --- Level B: installed kit, then the root suite through the sudo grant
if [ "$LEVEL" = B ]; then
  log "level B"
  if [ -f "$RK/SHA256SUMS" ]; then
    (cd "$RK" && shasum -a 256 -c SHA256SUMS) > "$EV/kit-installed-check.txt" 2>&1 \
      && res kit/installed-hashes B PASS NA "kit-installed-check.txt: every file in $RK matches its SHA256SUMS" \
      || res kit/installed-hashes B FAIL NA "kit-installed-check.txt: $(grep -v ': OK$' "$EV/kit-installed-check.txt" | head -3 | paste -sd ';' -)"
    cmp -s "$RK/SHA256SUMS" "$KIT/SHA256SUMS" \
      && res kit/installed-equals-source B PASS NA "$RK/SHA256SUMS = $KIT/SHA256SUMS" \
      || res kit/installed-equals-source B FAIL NA "$RK/SHA256SUMS differs from $KIT/SHA256SUMS (rebuild and reinstall the kit)"
    ic=$(cat "$RK/engine-cdhash" 2>/dev/null); im=$(cat "$RK/engine-modelhash" 2>/dev/null); ia=$(cat "$RK/engine-appid" 2>/dev/null)
    if [ -n "$ECD" ] && [ "$ic" = "$ECD" ] && [ -n "$MH" ] && [ "$im" = "$MH" ] && [ "$ia" = "$APPID" ]; then
      res kit/engine-identity B PASS NA "installed kit pins engine CD hash $ic and model hash $im, equal to the measured artifacts"
    else res kit/engine-identity B FAIL NA "installed kit cdhash '$ic' modelhash '$im' appid '$ia'; measured '$ECD' '$MH' '$APPID'"; fi
  else
    res kit/installed-hashes B SKIP NA "no installed kit in $RK"
    res kit/installed-equals-source B SKIP NA "no installed kit in $RK"
    res kit/engine-identity B SKIP NA "no installed kit in $RK"
  fi
  # The grant: general sudo (sudo -n true) or the one sudoers line for ROOTCMD.
  GRANT=""
  if $SUDO -n true > /dev/null 2>&1; then GRANT="sudo -n true"
  elif $SUDO -n -l "$ROOTCMD" --yes > /dev/null 2>&1; then GRANT="sudoers line for $ROOTCMD --yes"
  fi
  fact sudo_grant "${GRANT:-absent}"
  KITFAIL=$(awk -F'\t' '$2=="B" && $1 ~ /^kit\// && $3!="PASS"' "$EV/results.tsv" | cut -f1 | paste -sd, -)
  if [ -z "$GRANT" ]; then step root SKIP "" "" "sudo grant absent (sudo -n true and sudo -n -l $ROOTCMD --yes both refused)"
  elif [ $DRY = 1 ]; then step root SKIP "" "" "dry run (grant present: $GRANT)"
  elif [ -n "$KITFAIL" ]; then step root SKIP "" "" "not run: kit checks not PASS ($KITFAIL)"
  elif ! b=$(wait_idle); then step root SKIP "" "" "another suite run did not end within ${WAIT}s (pids $b)"
  else
    log "root suite: sudo -n $ROOTCMD --yes (about 10 minutes)"
    snapshot "$EV/root-inputs-before.txt"
    run_step "$EV/root-foreign.txt" "$EV/root-pass.txt" $SUDO -n "$ROOTCMD" --yes
    rc=$?
    # Keep the root pass's small evidence files with the report, so every
    # citation resolves inside the report folder (audit R4-4-02).
    RPD=$(sed -n 's#^results: \(.*\)/ (copied as .*#\1#p' "$EV/root-pass.txt" | tail -1)
    if [ -n "$RPD" ] && [ -d "$RPD" ]; then
      mkdir -p "$EV/rootpass"
      (cd "$RPD" && find . -type f -size -2048k ! -name '*.pcap' -print0 | xargs -0 -I{} cp -p {} "$EV/rootpass/" 2>/dev/null)
      fact rootpass_dir "$RPD"
    fi
    snapshot "$EV/root-inputs-after.txt"
    isolated root "$EV/root-inputs-before.txt" "$EV/root-inputs-after.txt" "$EV/root-foreign.txt"
    step root RAN $rc root-pass.txt ""
  fi
fi

# (c) entitlement audit of the release binaries
run_step "$EV/ent-foreign.txt" "$EV/entitlement-audit.txt" bash "$M/tools/entitlement-audit.sh"
step ent RAN $? entitlement-audit.txt ""

# Leave the engine as it was found: stop the one evidence.sh started.
if [ $ENGINE_WAS_RUNNING = 0 ] && [ -n "$(engine_pids)" ]; then
  log "stopping the engine that this run started"
  pkill -f "$APP/Contents/MacOS/SealedEngine"
fi
fact finished_utc "$(date -u +%FT%TZ)"

# --- Assemble the report.
REPORT=$OUT/$BASE.json
python3 - "$EV" "$REPORT" "$SELF" <<'PY'
import json, os, re, sys
from pathlib import Path

ev, report = Path(sys.argv[1]), Path(sys.argv[2])
SELF_PATH = sys.argv[3]
rel = ev.name
NEG_EXPECTED = 95

# Checks that cannot PASS on any Mac of this fleet, with the documented cause.
# They stay visible as EXEMPT in the report and count as acceptable for the
# verdict; a new macOS or an Apple grant removes the reason for the exemption.
EXEMPT = {
    "root/A-4-endpoint-security": "AMFI kills the kit client at launch (exit 137): no provisioning profile permits its endpoint-security entitlement. Not measured: an Apple-signed client such as /usr/bin/eslogger, which shows events, not memory. artifacts/no-forbidden-entitlement proves the release holds no such entitlement",
    "root/R4-T5-pid-domain": "launchd refuses a foreign pid-domain bootstrap for any service name (structural)",
    "root/R4-T5-control": "same structural refusal; the harness C1-C6 supplies the user-level control",
    "root/A-2-dtrace-read": "SIP blocks the syscall provider; the control fails the same way",
}
ENGINE_EXPECTED = ["child-reproducible", "child-pin-in-engine", "engine-reproducible", "model-hash",
                   "verified-chat", "refuse-wrong-cdhash", "refuse-wrong-model", "refuse-wrong-appid",
                   "p10-canary-served", "p10-no-file-copy", "p10-no-log-copy", "p10-no-python-hop",
                   # Section 6 of evidence.sh (audit R4-E-01): a missing arm stops acceptance.
                   "padded-reply-1", "padded-reply-2", "padded-reply-4", "big-grapheme",
                   "refusal-503-control", "frame-v2-budget", "refusal-503-body", "refusal-log-line",
                   "serve-after-refusal", "budget-range-1", "budget-range-1099511627777"]
ROOT_EXPECTED = ["A-1-task-ports", "A-2-dtrace-attach", "A-2-dtrace-read", "A-4-endpoint-security",
                 "A-21-mount-over", "R4-T5-pid-domain", "R4-T5-control", "R4-T4-no-metal-cache-outside-tmpdir",
                 "P10-engine-task-ports", "P10-engine-dtrace-attach", "P10-engine-child-task-ports",
                 "P10-engine-child-dtrace-attach", "P10-lo0-ciphertext-only",
                 "P6-gcore-engine", "P6-gcore-engine-child", "P10-engine-identity"]
# Root arms whose own PASS rule needs its control to fire.
ROOT_CONTROLLED = {"A-1-task-ports", "A-2-dtrace-attach", "A-2-dtrace-read", "A-21-mount-over",
                   "R4-T4-no-metal-cache-outside-tmpdir", "P10-engine-task-ports", "P10-engine-dtrace-attach",
                   "P10-engine-child-task-ports", "P10-engine-child-dtrace-attach",
                   "P6-gcore-engine", "P6-gcore-engine-child"}

def tsv(name):
    p = ev / name
    return [l.rstrip("\n").split("\t") for l in p.read_text().splitlines() if l.strip()] if p.exists() else []

facts = {r[0]: (r[1] if len(r) > 1 else "") for r in tsv("facts.tsv")}
steps = {r[0]: {"state": r[1], "rc": r[2], "file": r[3], "reason": r[4] if len(r) > 4 else ""} for r in tsv("steps.tsv")}
results = []   # (level, dict)
def add(level, name, status, control, evidence):
    results.append((level, {"name": name, "status": status, "control": control, "evidence": evidence}))
for r in tsv("results.tsv"):
    r += [""] * (5 - len(r))
    add(r[1], r[0], r[2], r[3], r[4])

LINE = re.compile(r"^(PASS|FAIL|INCONCLUSIVE|INFO) \[([^\]]+)\] ?(.*)$")
def parse(fname):
    out = []
    for i, l in enumerate((ev / fname).read_text(errors="replace").splitlines(), 1):
        m = LINE.match(l)
        if m:
            out.append((m.group(1), m.group(2), i, l))
    return out
def cite(fname, i, line):
    # The whole line: a cut cite could hide text after the cut (audit R4-4-08).
    return f"{rel}/{fname}:{i} | {line}"
def control_of(statuses, names):
    if not names:
        return "NA"
    got = [statuses.get(n) for n in names]
    return "PASS" if all(g == "PASS" for g in got) else "FAIL"
def settle(status, control):
    # A PASS needs its control to have fired.
    return "INCONCLUSIVE" if status == "PASS" and control == "FAIL" else status

suites = {}

# (a) negative suite
s = steps.get("neg")
if not s or s["state"] != "RAN":
    add("A", "neg/suite", "SKIP", "NA", (s or {}).get("reason") or "not run")
    suites["neg"] = {"ran": False, "reason": (s or {}).get("reason", "")}
else:
    lines = [x for x in parse(s["file"]) if x[0] in ("PASS", "FAIL")]
    st = {t: v for v, t, _, _ in lines}
    S3 = {"S3-share-rw-alias": ["S3-share-rw-alias-dropped", "M-S3-share-rw-alias"],
          "S3-share-entry": ["S3-share-entry-ctl", "M-S3-share-entry"],
          "S3-bypass-open": ["S3-bypass-open-closed", "M-S3-bypass-open"],
          "S3-openlog-case": ["S3-openlog-case-ctl", "M-S3-openlog-case"]}
    for t in ("fd-hardlink", "fd-root", "fd-under-root", "fd-outside"):
        S3["S3-" + t] = ["S3-fd-system-ctl", "M-S3-" + t]
    def neg_controls(t):
        if t in ("control", "L-control") or t.endswith(("-ctl", "-closed", "-dropped")) or t.startswith("M-"):
            return []          # these cases are controls themselves
        if t in S3:
            return S3[t]
        if t.startswith("L-") or t == "N7-launcher-refuses-loaded-first":
            return ["L-control"]
        return ["control"]
    for v, t, i, l in lines:
        c = control_of(st, neg_controls(t))
        add("A", "neg/" + t, settle(v, c), c, cite(s["file"], i, l))
    text = (ev / s["file"]).read_text(errors="replace")
    fl = re.findall(r"^# result: (\d+) failed$", text, re.M)
    npass = sum(1 for x in lines if x[0] == "PASS"); nfail = len(lines) - npass
    ok = s["rc"] == "0" and fl == ["0"] and nfail == 0 and len(lines) == NEG_EXPECTED and len(st) == NEG_EXPECTED
    add("A", "neg/suite", "PASS" if ok else "FAIL", "NA",
        f"{rel}/{s['file']}: {len(lines)} cases ({len(st)} distinct, {NEG_EXPECTED} expected), {npass} PASS, {nfail} FAIL; "
        f"final line '# result: {fl[-1] if fl else '?'} failed'; exit {s['rc']}")
    suites["neg"] = {"ran": True, "cases": len(lines), "expected": NEG_EXPECTED, "pass": npass, "fail": nfail,
                     "final_line": f"# result: {fl[-1]} failed" if fl else None, "exit": int(s["rc"]),
                     "evidence": f"{rel}/{s['file']}"}

# (b) engine evidence suite
s = steps.get("engine")
if not s or s["state"] != "RAN":
    for n in ENGINE_EXPECTED:
        add("A", "engine/" + n, "SKIP", "NA", (s or {}).get("reason") or "not run")
    add("A", "engine/suite", "SKIP", "NA", (s or {}).get("reason") or "not run")
    add("A", "artifacts/evidence-agrees", "SKIP", "NA", "engine evidence suite not run")
    suites["engine"] = {"ran": False, "reason": (s or {}).get("reason", "")}
else:
    lines = [x for x in parse(s["file"]) if x[0] in ("PASS", "FAIL")]
    st = {t: v for v, t, _, _ in lines}
    ctl = {"verified-chat": ["refuse-wrong-cdhash", "refuse-wrong-model", "refuse-wrong-appid"],
           "p10-no-file-copy": ["p10-canary-served"], "p10-no-log-copy": ["p10-canary-served"],
           "refusal-503-body": ["refusal-503-control"]}
    seen = set()
    for v, t, i, l in lines:
        c = control_of(st, ctl.get(t, []))
        add("A", "engine/" + t, settle(v, c), c, cite(s["file"], i, l)); seen.add(t)
    for n in ENGINE_EXPECTED:
        if n not in seen:
            add("A", "engine/" + n, "SKIP", "NA", f"{rel}/{s['file']}: no line for {n}")
    text = (ev / s["file"]).read_text(errors="replace")
    fl = re.findall(r"^# result: (\d+) failed$", text, re.M)
    npass = sum(1 for x in lines if x[0] == "PASS"); nfail = len(lines) - npass
    ok = s["rc"] == "0" and fl == ["0"] and nfail == 0 and all(st.get(n) == "PASS" for n in ENGINE_EXPECTED)
    add("A", "engine/suite", "PASS" if ok else "FAIL", "NA",
        f"{rel}/{s['file']}: {npass} PASS, {nfail} FAIL; final line '# result: {fl[-1] if fl else '?'} failed'; exit {s['rc']}")
    suites["engine"] = {"ran": True, "pass": npass, "fail": nfail, "exit": int(s["rc"]),
                        "final_line": f"# result: {fl[-1]} failed" if fl else None, "evidence": f"{rel}/{s['file']}"}
    # evidence.sh writes the sealed-verify output only to its own file (copied here).
    own = facts.get("engine_evidence_file", "")
    if own and (ev / Path(own).name).exists():
        text += "\n" + (ev / Path(own).name).read_text(errors="replace")
    att = re.findall(r"App Attest (?:will report )?CD hash ([0-9a-f]{64})", text)
    mod = re.findall(r"engine reports model hash ([0-9a-f]{64})", text)
    ecd, mh = facts.get("engine_cdhash", ""), facts.get("model_hash", "")
    if not att or not mod:
        add("A", "artifacts/evidence-agrees", "SKIP", "NA", "the evidence output names no attested CD hash or model hash")
    else:
        ok = att[-1] == ecd and mod[-1] == mh
        add("A", "artifacts/evidence-agrees", "PASS" if ok else "FAIL", "NA",
            f"evidence: rebuild CD hash {att[-1]}, engine model hash {mod[-1]}; measured artifacts: {ecd}, {mh}")

s = steps.get("ent")
if not s or s["state"] != "RAN":
    add("A", "artifacts/no-forbidden-entitlement", "SKIP", "NA", (s or {}).get("reason") or "not run")
else:
    text = (ev / s["file"]).read_text(errors="replace")
    ok = "RESULT: PASS" in text
    add("A", "artifacts/no-forbidden-entitlement", "PASS" if ok else "FAIL", "NA",
        cite(s["file"], 1, "RESULT: PASS" if ok else "RESULT: FAIL"))
    cust = re.findall(r"^\s*(com\.apple\.[A-Za-z0-9._-]+)$", text, re.M)
    if cust:
        add("A", "artifacts/entitlement-list", "PASS", "NA", cite(s["file"], 1, "engine: " + ", ".join(sorted(set(cust)))))

# Level B root suite
info = []
if facts.get("requested_level") == "B":
    s = steps.get("root")
    if not s or s["state"] != "RAN":
        for n in ROOT_EXPECTED:
            add("B", "root/" + n, "SKIP", "NA", (s or {}).get("reason") or "not run")
        add("B", "root/suite", "SKIP", "NA", (s or {}).get("reason") or "not run")
        suites["root"] = {"ran": False, "reason": (s or {}).get("reason", "")}
    else:
        allv = parse(s["file"])
        lines = [x for x in allv if x[0] != "INFO"]
        info = [{"name": t, "evidence": cite(s["file"], i, l)} for v, t, i, l in allv if v == "INFO"]
        st = {t: v for v, t, _, _ in lines}
        seen = set()
        for v, t, i, l in lines:
            if t == "R4-T5-pid-domain":
                c = "PASS" if st.get("R4-T5-control") == "PASS" else "FAIL"
            elif t in ROOT_CONTROLLED:
                c = "PASS" if v == "PASS" else ("FAIL" if "control" in l.lower() and v == "INCONCLUSIVE" else "NA")
            else:
                c = "NA"
            add("B", "root/" + t, settle(v, c), c, cite(s["file"], i, l)); seen.add(t)
        info_line = {t: (i, l) for v, t, i, l in allv if v == "INFO"}
        for n in ROOT_EXPECTED:
            if n not in seen:
                if n in info_line:
                    i, l = info_line[n]
                    add("B", "root/" + n, "INCONCLUSIVE", "NA", cite(s["file"], i, l))
                else:
                    add("B", "root/" + n, "SKIP", "NA", f"{rel}/{s['file']}: no PASS/FAIL/INCONCLUSIVE line for {n}")
        text = (ev / s["file"]).read_text(errors="replace")
        fatal = [l for l in text.splitlines() if l.startswith("FAIL ") and not l.startswith("FAIL [")]
        end = re.findall(r"^=== TEE ROOT PASS end: (.*) ===$", text, re.M)
        ok = s["rc"] == "0" and end and not fatal
        add("B", "root/suite", "PASS" if ok else "FAIL", "NA",
            f"{rel}/{s['file']}: exit {s['rc']}; " + (f"end line: {end[-1]}" if end else "no end line") +
            (f"; stopped: {fatal[0]}" if fatal else ""))
        suites["root"] = {"ran": True, "exit": int(s["rc"]), "end_line": end[-1] if end else None,
                          "evidence": f"{rel}/{s['file']}"}
        bp = [l.strip() for l in text.splitlines()
              if re.match(r"^(Security Mode|SIP Status|Signed System Volume Status|Kernel CTRR Status|Boot Args Filtering Status|DEP-allowed MDM Control):", l)]
        if bp:
            facts["bputil"] = bp

# A step whose inputs changed, or that ran next to another suite, proves
# nothing either way: its PASS and FAIL lines become INCONCLUSIVE.
def isolation(step, prefixes, level):
    s = steps.get(step)
    if not s or s["state"] != "RAN":
        return
    changed = int(facts.get(f"{step}_inputs_changed") or 0)
    foreign = facts.get(f"{step}_foreign", "")
    if changed == 0 and not foreign:
        add(level, f"run/{step}-isolated", "PASS", "NA",
            f"no input changed ({rel}/{step}-inputs-before.txt = after); the shared suite lock was held; "
            f"3-second sampling saw no other suite process (a process shorter than 3 s can escape the sampling)")
        return
    why = (f"{changed} input lines changed ({rel}/{step}-inputs-before.txt vs -after.txt)" if changed else "") + \
          ("; " if changed and foreign else "") + (f"other suite processes ran: {foreign}" if foreign else "")
    for _, r in results:
        if any(r["name"].startswith(p) for p in prefixes) and r["status"] in ("PASS", "FAIL"):
            r["evidence"] = f"run not isolated (was {r['status']}): " + r["evidence"]
            r["status"] = "INCONCLUSIVE"
            r["not_isolated"] = True
    add(level, f"run/{step}-isolated", "INCONCLUSIVE", "NA", why)

isolation("neg", ["neg/"], "A")
isolation("engine", ["engine/", "artifacts/evidence-agrees"], "A")
isolation("root", ["root/"], "B")

for _, r in results:
    # A row that is INCONCLUSIVE only because the run was not isolated stays
    # INCONCLUSIVE: its arm may have been a FAIL (audit R4-4-10).
    if r.pop("not_isolated", False):
        continue
    if r["status"] == "INCONCLUSIVE" and r["name"] in EXEMPT:
        r["status"] = "EXEMPT"
        r["arm_evidence"] = r.get("evidence", "")
        r["evidence"] = "EXEMPT: " + EXEMPT[r["name"]] + " | " + r["arm_evidence"]

levels_order = ["A", "B"] if facts.get("requested_level") == "B" else ["A"]
# The required list comes from required.json, not from the checks that ran:
# a listed check with no result becomes SKIP, so a missing arm can never
# shorten the list (audit R3-4-06).
REQ = json.load(open(os.path.join(os.path.dirname(os.path.abspath(SELF_PATH)), "required.json")))
have = {r["name"] for _, r in results}
for L in levels_order:
    for n in REQ[L]:
        if n not in have:
            results.append((L, {"name": n, "status": "SKIP", "control": "NA", "evidence": "listed in required.json; no result in this run"}))
            have.add(n)
desc = {"A": "child negative suite, engine evidence suite, consumer chat (plus preflight, identity, artifacts)",
        "B": "A plus the installed root kit and the root suite with controls (sudo grant)"}
levels, totals, verdict = {}, {}, {}
for L in levels_order:
    inc = levels_order[: levels_order.index(L) + 1]
    req_names = sorted(set(REQ[L]))
    by_name = {r["name"]: r for _, r in results}
    req = [by_name[n] for n in req_names]
    levels[L] = {"description": desc[L], "required": req_names}
    if L == "B":
        levels[L]["info"] = info
    t = {k: sum(1 for r in req if r["status"] == k) for k in ("PASS", "FAIL", "SKIP", "INCONCLUSIVE", "EXEMPT")}
    t["required"] = len(req)
    totals[L] = t
    verdict[L] = "REJECTED" if t["FAIL"] else ("ACCEPTED" if req and t["PASS"] + t["EXEMPT"] == len(req) else "INCOMPLETE")

def num(k):
    try:
        return int(facts.get(k, ""))
    except ValueError:
        return None
doc = {
    "schema": 1,
    "tool_version": int(facts["tool_version"]),
    "tool_sha256": facts.get("tool_sha256"),
    "required_sha256": facts.get("required_sha256"),
    "requested_level": facts.get("requested_level"),
    "dry_run": facts.get("dry_run") == "1",
    "started_utc": facts.get("started_utc"),
    "finished_utc": facts.get("finished_utc"),
    "host": facts.get("host"),
    "device": {
        "hw.model": facts.get("hw.model"), "hw.ncpu": num("hw.ncpu"), "memsize": num("memsize"),
        "macos": facts.get("macos"), "macos_version": facts.get("macos_version"),
        "page_size": num("page_size"), "free_disk_bytes": num("free_disk_bytes"),
        "legal_boot": {"csrutil": facts.get("csrutil"), "sip": facts.get("sip"),
                       "authenticated_root": facts.get("authenticated_root"),
                       "bputil": facts.get("bputil", "SKIP: bputil -d needs root (recorded by the level B root suite)")},
    },
    "source": {
        "engine_repo": facts.get("engine_repo"), "engine_branch": facts.get("engine_branch_wanted"),
        "commit": facts.get("engine_commit") or None, "head": facts.get("engine_head"),
        "checked_out": facts.get("engine_branch_checked_out"), "dirty_tracked": facts.get("engine_dirty_tracked", ""),
        "child_source_hash": facts.get("child_source_hash") or None,
        "SPLASH_BUILD_ID": facts.get("SPLASH_BUILD_ID") or None,
        "splash_tree_build_id": facts.get("splash_tree_build_id") or None,
        "child_commit": facts.get("child_commit") or None, "child_dirty": facts.get("child_dirty", ""),
        "harness_commit": facts.get("harness_commit") or None, "harness_dirty": facts.get("harness_dirty", ""),
    },
    "artifacts": {
        "child_cdhash": facts.get("child_cdhash") or None, "child_cdhash_full": facts.get("child_cdhash_full") or None,
        "child_pin": facts.get("child_pin") or None,
        "engine_cdhash": facts.get("engine_cdhash") or None, "engine_identifier": facts.get("engine_identifier") or None,
        "engine_appid": facts.get("engine_appid") or None,
        "model_hash": facts.get("model_hash") or None,
        "kit_engine_cdhash": facts.get("kit_engine_cdhash") or None,
        "kit_engine_modelhash": facts.get("kit_engine_modelhash") or None,
    },
    "sudo_grant": facts.get("sudo_grant"),
    "engine_attempts": num("engine_attempts"),
    "levels": levels,
    "suites": suites,
    "results": [r for _, r in results],
    "totals": totals,
    "verdict": verdict,
    "evidence_dir": rel,
}
# sha256 of every file in the report folder (except harness/, which has its
# own hashes), so an edit to an evidence file after the run is refused
# (audit R4-4-02).
import hashlib
doc["evidence_sha256"] = {str(f.relative_to(ev)): hashlib.sha256(f.read_bytes()).hexdigest()
                          for f in sorted(ev.rglob("*")) if f.is_file() and f.parts[len(ev.parts)] != "harness"}
report.write_text(json.dumps(doc, indent=2) + "\n")
L = facts.get("requested_level")
print(f"report: {report}")
for lv in levels_order:
    t = totals[lv]
    print(f"level {lv}: {verdict[lv]} ({t['PASS']} PASS, {t['FAIL']} FAIL, {t['SKIP']} SKIP, {t['INCONCLUSIVE']} INCONCLUSIVE of {t['required']} required)")
if "neg" in suites and suites["neg"].get("ran"):
    n = suites["neg"]; print(f"neg suite: {n['cases']} cases, {n['pass']} PASS, {n['fail']} FAIL, {n['final_line']}")
if "engine" in suites and suites["engine"].get("ran"):
    n = suites["engine"]; print(f"engine evidence: {n['pass']} PASS, {n['fail']} FAIL, {n['final_line']}")
bad = [r for lv, r in results if r["status"] != "PASS" and lv in levels_order]
for r in bad[:20]:
    print(f"  {r['status']} {r['name']}: {r['evidence'][:200]}")
if len(bad) > 20:
    print(f"  ... {len(bad) - 20} more not PASS (see the report)")
sys.exit({"ACCEPTED": 0, "REJECTED": 1}.get(verdict[L], 2))
PY
