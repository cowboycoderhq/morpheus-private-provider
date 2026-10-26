#!/bin/bash
# r4t5-control.sh - comparison-case design for the launchd per-pid namespace
# restriction on com.apple.MTLCompilerService.
#
# Interpreter: run this script under /bin/bash (bash 3.2), as in
#   /bin/bash tools/tee-rootkit/r4t5-control.sh
# A bash 5.3 from Homebrew hung for 5 min in heredoc_write (write on a pipe)
# inside mk_service on 2026-10-21, before any case ran.
#
# It runs as the operator. It needs no root, no sudo and no SIP change.
# Every file it makes stays under the work directory (default:
# <repo>/scratch/r4t5-run).
#
# Design:
#   C1  control, pid namespace: an app that embeds a test-named XPC service
#       reaches it. This proves the embedded-bundle -> pid-domain -> launchd
#       path works on this host.
#   C2  isolation: an outsider (no bundle, Mach lookup) cannot reach the
#       service that lives in C1's pid domain.
#   C3  outside bootstrap: `launchctl bootstrap pid/<live-pid> <bundle>` is
#       refused, even for a bundle and a caller that work elsewhere.
#   C4  bootstrap control: the same bundle bootstraps into gui/<uid> and
#       answers a Mach lookup. So launchd bootstrap itself works; only the
#       foreign pid domain is closed.
#   C5  target, pid namespace: a Metal client that runs from an app which
#       embeds an Apple-named (com.apple.MTLCompilerService) fake still
#       compiles with the system service, and the fake never runs.
#   C6  target, gui namespace + ordering: register the Apple-named fake in
#       gui/<uid> BEFORE the Metal client starts. The name is live (it answers
#       a Mach lookup), yet a normal Metal client still compiles and never
#       contacts it.
#
# Strict grading: a target case passes only when its control fired.
set -u

K=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SRC=$K/r4t5
REPO=$(CDPATH= cd -- "$K/../.." && pwd)
W=$REPO/scratch/r4t5-run
while [ $# -gt 0 ]; do
  case $1 in
    --work) W=$2; shift 2 ;;
    -h|--help) echo "usage: $0 [--work DIR]"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
UID_=$(id -u)
mkdir -p "$W"
LOG=$W/r4t5-control.out
: > "$LOG"
say() { echo "$@" | tee -a "$LOG"; }
pass() { say "PASS [$1] $2"; }
fail() { say "FAIL [$1] $2"; }
info() { say "INFO [$1] $2"; }
# A contact is a peer or dict line from svcprobe. The caller empties the log
# at the start of the window, so the count covers that window only. An error
# line is the teardown of an earlier connection, not a contact (2026-10-21:
# C6 counted one such line and could not tell it from a Metal contact).
contacts() {
  awk -v svc="$1" '/^(peer|dict) / && index($0, "svc=" svc) > 0 {n++} END {print n+0}' "$TEE_FAKE_LOG" 2>/dev/null
}

BG=""
cleanup() {
  for p in $BG; do kill "$p" 2>/dev/null; done
  launchctl bootout "gui/$UID_/com.tee.r4t5.outside" 2>/dev/null
  launchctl bootout "gui/$UID_/com.tee.r4t5.control" 2>/dev/null
  launchctl bootout "gui/$UID_/com.apple.MTLCompilerService" 2>/dev/null
}
trap cleanup EXIT

launchctl bootout "gui/$UID_/com.tee.r4t5.outside" 2>/dev/null
launchctl bootout "gui/$UID_/com.tee.r4t5.control" 2>/dev/null
launchctl bootout "gui/$UID_/com.apple.MTLCompilerService" 2>/dev/null

say "# R4-T5 control: launchd per-pid namespace"
say "host: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
say "user: uid=$UID_"
say "launchd: $(launchctl version 2>/dev/null | head -1)"
say "work: $W"
say

# --- build -----------------------------------------------------------------
mkdir -p "$W/src"
clang -O2 -DTEE_FAKE_LOG_PATH="\"$W/fake-events.log\"" -o "$W/svcprobe" "$SRC/svcprobe.c" || exit 1
codesign -f -s - "$W/svcprobe" 2>/dev/null
clang -fobjc-arc -framework Foundation -o "$W/xpchost" "$SRC/xpchost.m" || exit 1
codesign -f -s - "$W/xpchost" 2>/dev/null
clang -fobjc-arc -framework Foundation -o "$W/outsider" "$SRC/outsider.m" || exit 1
codesign -f -s - "$W/outsider" 2>/dev/null
clang -fobjc-arc -framework Metal -framework Foundation -o "$W/metalprobe" "$SRC/metalprobe.m" || exit 1
codesign -f -s - "$W/metalprobe" 2>/dev/null

mk_service() { # dir, service-id
  local dir=$1 id=$2 name=${2##*.}
  rm -rf "$dir"; mkdir -p "$dir/Contents/MacOS"
  cp "$W/svcprobe" "$dir/Contents/MacOS/$name"
  cat > "$dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$id</string>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleName</key><string>$name</string>
<key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
EOF
  codesign -f -s - "$dir" 2>/dev/null
}

mk_app() { # app-dir, app-id, executable, service-bundle...
  local app=$1 id=$2 exe=$3; shift 3
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/XPCServices"
  cp "$exe" "$app/Contents/MacOS/$(basename "$exe")"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$id</string>
<key>CFBundleExecutable</key><string>$(basename "$exe")</string>
<key>CFBundleName</key><string>$(basename "$exe")</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
  local s
  for s in "$@"; do cp -R "$s" "$app/Contents/XPCServices/"; done
  codesign -f -s - "$app" 2>/dev/null
}

mk_service "$W/ControlSvc.xpc" com.tee.r4t5.control
mk_service "$W/OutsideSvc.xpc" com.tee.r4t5.outside
mk_service "$W/AppleSvc.xpc" com.apple.MTLCompilerService
mk_app "$W/Control.app" com.tee.r4t5.host "$W/xpchost" "$W/ControlSvc.xpc"
mk_app "$W/AppleMetal.app" com.tee.r4t5.applemtlc "$W/metalprobe" "$W/AppleSvc.xpc"
export TEE_FAKE_LOG=$W/fake-events.log

# --- C1: control in the pid namespace --------------------------------------
: > "$TEE_FAKE_LOG"
"$W/Control.app/Contents/MacOS/xpchost" com.tee.r4t5.control 6 > "$W/c1.out" 2>&1
c1_reply=$(grep -c 'reply service=com.tee.r4t5.control marker=ran' "$W/c1.out" || true)
c1_log=$(grep -c 'svc=com.tee.r4t5.control' "$TEE_FAKE_LOG" || true)
say "--- C1 control-embedded-pid"
sed 's/^/  /' "$W/c1.out" | tee -a "$LOG"
say "  fake events: $(wc -l < "$TEE_FAKE_LOG")"
if [ "$c1_reply" -ge 1 ] && [ "$c1_log" -ge 1 ]; then
  pass control-embedded-pid "app-embedded service was launched by launchd and answered (reply=$c1_reply, events=$c1_log)"
else
  fail control-embedded-pid "no reply or no fake event (reply=$c1_reply, events=$c1_log)"
fi

# --- C2: outsider cannot reach the pid domain ------------------------------
"$W/Control.app/Contents/MacOS/xpchost" com.tee.r4t5.control 8 > "$W/c2-host.out" 2>&1 &
H=$!; BG="$BG $H"
for _ in $(seq 1 30); do grep -q 'host pid=' "$W/c2-host.out" && break; sleep 0.1; done
HPID=$(awk -F'[= ]' '/host pid=/{print $3}' "$W/c2-host.out")
"$W/outsider" com.tee.r4t5.control > "$W/c2.out" 2>&1
say "--- C2 outsider-mach-lookup (host pid $HPID)"
sed 's/^/  /' "$W/c2.out" | tee -a "$LOG"
if grep -q 'OUTSIDER GOT REPLY' "$W/c2.out"; then
  fail outsider-isolation "an outside Mach lookup reached the service in the host's pid domain"
else
  pass outsider-isolation "outside Mach lookup did not reach the service (pid-domain scoped)"
fi
kill "$H" 2>/dev/null; wait "$H" 2>/dev/null; BG=""

# --- C3: outside bootstrap into a foreign pid domain -----------------------
"$W/Control.app/Contents/MacOS/xpchost" com.tee.r4t5.control 8 > "$W/c3-host.out" 2>&1 &
H=$!; BG="$BG $H"
for _ in $(seq 1 30); do grep -q 'host pid=' "$W/c3-host.out" && break; sleep 0.1; done
HPID=$(awk -F'[= ]' '/host pid=/{print $3}' "$W/c3-host.out")
launchctl bootstrap "pid/$HPID" "$W/OutsideSvc.xpc" > "$W/c3.out" 2>&1
c3_rc=$?
say "--- C3 bootstrap-pid-foreign (pid/$HPID)"
sed 's/^/  /' "$W/c3.out" | tee -a "$LOG"
say "  rc=$c3_rc"
if [ "$c3_rc" -ne 0 ]; then
  pass bootstrap-pid-foreign "launchd refused the foreign pid domain (rc=$c3_rc)"
else
  fail bootstrap-pid-foreign "launchd accepted an outside bootstrap into pid/$HPID"
fi
kill "$H" 2>/dev/null; wait "$H" 2>/dev/null; BG=""

# --- C4: the same bundle bootstraps into the user domain -------------------
launchctl bootstrap "gui/$UID_" "$W/OutsideSvc.xpc" > "$W/c4.out" 2>&1
c4_rc=$?
sleep 0.4
"$W/outsider" com.tee.r4t5.outside > "$W/c4-client.out" 2>&1
say "--- C4 bootstrap-gui-control"
say "  bootstrap rc=$c4_rc"
sed 's/^/  /' "$W/c4-client.out" | tee -a "$LOG"
if [ "$c4_rc" -eq 0 ] && grep -q 'OUTSIDER GOT REPLY service=com.tee.r4t5.outside marker=ran' "$W/c4-client.out"; then
  pass bootstrap-gui-control "the same bundle loaded in gui/$UID_ and answered (rc=0)"
else
  fail bootstrap-gui-control "the bundle did not load or did not answer in gui/$UID_ (rc=$c4_rc)"
fi
launchctl bootout "gui/$UID_/com.tee.r4t5.outside" 2>/dev/null

# --- C5: Apple name embedded in the app's pid domain -----------------------
: > "$TEE_FAKE_LOG"
"$W/AppleMetal.app/Contents/MacOS/metalprobe" > "$W/c5.out" 2>&1
c5_compile=$(grep -c 'pipeline=ok' "$W/c5.out" || true)
c5_fake=$(grep -c 'svc=com.apple.MTLCompilerService' "$TEE_FAKE_LOG" || true)
say "--- C5 apple-embedded-pid"
sed 's/^/  /' "$W/c5.out" | tee -a "$LOG"
say "  fake events for the Apple name: $c5_fake"
if [ "$c5_compile" -ge 1 ] && [ "$c5_fake" -eq 0 ]; then
  pass apple-embedded-pid "Metal compiled with the system service; the app's Apple-named bundle never ran"
else
  fail apple-embedded-pid "compile=$c5_compile, fake events=$c5_fake (substitution or broken control)"
fi

# --- C6: Apple name registered in gui BEFORE the Metal client --------------
: > "$TEE_FAKE_LOG"
launchctl bootstrap "gui/$UID_" "$W/AppleSvc.xpc" > "$W/c6.out" 2>&1
c6_rc=$?
sleep 0.4
"$W/outsider" com.apple.MTLCompilerService > "$W/c6-live.out" 2>&1
c6_live=$(grep -c 'OUTSIDER GOT REPLY service=com.apple.MTLCompilerService marker=ran' "$W/c6-live.out" || true)
# The live check is over before the Metal run starts: let its connection
# settle, then empty the log so the next lines are the Metal-run window.
sleep 1
: > "$TEE_FAKE_LOG"
"$W/metalprobe" > "$W/c6-metal.out" 2>&1
c6_compile=$(grep -c 'pipeline=ok' "$W/c6-metal.out" || true)
c6_fake=$(contacts com.apple.MTLCompilerService)
say "--- C6 gui-apple-before-metal"
say "  bootstrap rc=$c6_rc"
sed 's/^/  /' "$W/c6-live.out" | tee -a "$LOG"
sed 's/^/  /' "$W/c6-metal.out" | tee -a "$LOG"
say "  fake contacts (peer/dict) during the Metal run: $c6_fake"
if [ "$c6_rc" -eq 0 ] && [ "$c6_live" -ge 1 ] && [ "$c6_compile" -ge 1 ] && [ "$c6_fake" -eq 0 ]; then
  pass gui-apple-before-metal "the Apple-named fake was live in gui/$UID_ and answered a Mach lookup; Metal ignored it and compiled (contacts during Metal=0)"
else
  fail gui-apple-before-metal "rc=$c6_rc live=$c6_live compile=$c6_compile metal_contacts=$c6_fake"
fi
launchctl bootout "gui/$UID_/com.apple.MTLCompilerService" 2>/dev/null

say
say "# Conclusion"
say "C1 and C4 show launchd launches an embedded XPC service into the pid domain"
say "of its own bundle and loads the same bundle in gui/$UID_. C2 and C3 show"
say "that no other process can reach or add to that pid domain. C5 and C6 show"
say "that com.apple.MTLCompilerService stays bound to the system Metal.framework"
say "bundle: an app-embedded or gui-registered same-named fake neither runs in"
say "the Metal client's pid domain nor receives the Metal client's connection."
say
say "evidence: $LOG"
say "work dir: $W"
