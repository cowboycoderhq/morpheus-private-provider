#!/bin/bash
# TEE root pass: root's attacks on the REAL sealed Splash child while it
# serves, each with a control that shows the attack works on an ordinary
# process. Nothing compiles at root time; the kit's hashes are checked first.
#
# Usage (operator): sudo tools/tee-rootpass.sh --yes
# Build first, as the user: tools/tee-rootkit/build.sh
#
# Arms (PASS/FAIL/INCONCLUSIVE/INFO lines in logs/tee-rootpass-<stamp>.log;
# INCONCLUSIVE = the arm did not test the property: empty evidence, a control
# that did not fire, or a missing precondition):
#   A-1  task ports for the child (control, read, inspect, name) vs ctlproc
#   A-2  dtrace attach, and dtrace copyin of the child's read() buffers vs ctlproc
#   R5-T3 lsmp (port list) on the child vs ctlproc
#   A-4  Endpoint Security client as root (ad-hoc, with the entitlement)
#   A-4  BPF: capture on lo0 during a request (the channel is AF_UNIX)
#   A-21 mount over a sealed-volume folder; hypervisor flag; authenticated root
#   R4-T5 root bootstraps a fake MTLCompilerService into a Metal client's pid domain
#   A-5  sleep image: who can read it, zero-page share, entropy; can root set
#        hibernatemode 25 (restored at once)
#   A-8/A-9/A-11 checklist: boot policy (bputil -d), csrutil, kmem, boot-args,
#        panic and core settings
#   R4-T4 fs_usage of the child's start: files touched before the sandbox
#   P10  engine: task port and dtrace attach on the engine pid, and the same
#        two checks on the engine's own child/splash (not the kit's child)
# Every change is undone on exit (trap): the kit's own server tree stopped
# by recorded pid (never by name: the v2 engine runs the same child binary),
# mounts removed,
# hibernatemode restored, fake service removed.
#
# Two layouts: run from tools/ (operator mode; the kit is tools/tee-rootkit),
# or installed root-owned in /usr/local/libexec/tee-rootkit by
# tools/tee-rootkit/grant-agent-sudo.sh (agent mode, one sudoers line).
# Root never writes into, reads secrets from, or chowns anything in the
# user's tree: root writes only into a fresh mktemp folder, and every step in
# the user's tree runs as the user.
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 64; }
[ "${1:-}" = "--yes" ] || { echo "read the header, then run: sudo $0 --yes"; exit 64; }
U=${SUDO_USER:?run through sudo}
SELF=$(cd "$(dirname "$0")" && pwd -P)
UHOME=$(dscl . -read "/Users/$U" NFSHomeDirectory | awk '{print $2}')
if [ -d "$SELF/tee-rootkit" ]; then K=$SELF/tee-rootkit; ROOT=$(cd "$SELF/.." && pwd -P)
else K=$SELF; ROOT=$UHOME/projects/sealed-backends-spike/sealed-m5; fi
cd /
STAMP=$(date +%F-%H%M%S)
W=$(mktemp -d /private/tmp/tee-rootpass.XXXXXXXX) || exit 70
chmod 755 "$W"; LOG=$W/tee-rootpass-$STAMP.log; : > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
v() { say "$1 [$2] $3"; }
as_user() { sudo -u "$U" -H "$@"; }
ucat() { as_user cat "$1" 2>/dev/null; }
HIB0=$(pmset -g | awk '/hibernatemode/{print $2}')
SP=""; CTL=""; FEED=""; WC=""
# The v2 engine spawns the same child/splash binary, so the kit never kills
# by name: it records the pids of its own server tree (pid plus start time,
# against pid reuse) and kills only those.
KIDS=$W/kit-pids.txt; : > "$KIDS"
tree() { echo "$1"; for c in $(pgrep -P "$1"); do tree "$c"; done; }
# A pid that exits between pgrep and ps has no start time; it is not
# recorded, because an empty field would match any dead pid (audit R4-3-05).
record_tree() { local p st; for p in $(tree "$1"); do st=$(ps -o lstart= -p "$p" 2>/dev/null | tr -s ' ' _); [ -n "$st" ] && echo "$p $st" >> "$KIDS"; done; }
alive_recorded() { while read -r p st; do [ -n "$p" ] && [ -n "$st" ] && [ "$(ps -o lstart= -p "$p" 2>/dev/null | tr -s ' ' _)" = "$st" ] && echo "$p"; done < "$KIDS"; }
port_busy() { lsof -nP -iTCP:8199 -sTCP:LISTEN -t > /dev/null 2>&1; }
port_pid() { lsof -nP -iTCP:8199 -sTCP:LISTEN -t 2>/dev/null; }
# The :8199 listener only when it is one of the kit's recorded pids: a foreign
# listener is never signalled (audit R4-3-04).
kit_port_pid() { local p; for p in $(port_pid); do alive_recorded | grep -qx "$p" && echo "$p"; done; }
server_pids() { alive_recorded | sort -u | grep .; }
# Recorded pids other than the wrapper $SP, deepest first (KIDS is in tree order).
inner_pids() { alive_recorded | grep -vx "$SP" | tail -r; }
# Stops the kit's server tree, by recorded pid only (pid plus start time).
# The tree is recorded again first, so children started since the last record
# are covered. SIGTERM goes to the kit's :8199 listener only, so the server
# stops its own children; the wrapper $SP stays alive, because if it dies
# first the tree moves to launchd and the harness watcher counts it as
# foreign (accept report 20261025T001248Z). After a grace period SIGKILL goes
# to the recorded pids deepest first, the wrapper last. A foreign :8199
# listener is never signalled. Returns 1, with STOP_WHY set, if a recorded pid
# is still alive or the port stays busy (audits R4-3-03, R4-3-04).
STOP_WHY=""
stop_server() {
  [ -n "$SP" ] || return 0
  local pids p i
  kill -0 "$SP" 2>/dev/null && record_tree "$SP"
  pids=$(kit_port_pid); [ -n "$pids" ] || pids=$(inner_pids)
  for p in $pids; do kill -TERM "$p" 2>/dev/null; done
  # A clean stop took 66 s once, so give it 90 s before SIGKILL.
  for i in $(seq 1 90); do [ -z "$(inner_pids)" ] && break; sleep 1; done
  for p in $(inner_pids); do kill -KILL "$p" 2>/dev/null; done
  for i in $(seq 1 10); do [ -z "$(server_pids)" ] && break; sleep 1; done
  for p in $(server_pids); do kill -KILL "$p" 2>/dev/null; done
  for i in $(seq 1 300); do port_busy || break; sleep 1; done
  if [ -n "$(server_pids)" ]; then
    STOP_WHY="recorded kit pids still alive after SIGTERM and SIGKILL: $(server_pids | tr '\n' ' ')"
    return 1
  fi
  if port_busy; then
    STOP_WHY=":8199 stayed busy after a 300 s wait, held by a pid that is not the kit's: $(port_pid | tr '\n' ' ')"
    return 1
  fi
  SP=""; return 0
}
cleanup() {
  local stop_rc=0 left ctlleft
  [ -n "$FEED" ] && kill "$FEED" 2>/dev/null
  [ -n "${CTLPID:-}" ] && kill "$CTLPID" 2>/dev/null
  [ -n "$CTL" ] && kill "$CTL" 2>/dev/null
  [ -n "$WC" ] && kill "$WC" 2>/dev/null
  stop_server || { stop_rc=1; say "cleanup: server stop failed: $STOP_WHY"; }
  for p in $(alive_recorded); do kill -KILL "$p" 2>/dev/null; done
  mount | grep -q " on /usr/share/man " && umount /usr/share/man
  [ -n "$HIB0" ] && [ "$(pmset -g | awk '/hibernatemode/{print $2}')" != "$HIB0" ] && pmset -a hibernatemode "$HIB0"
  [ -n "${WCPID:-}" ] && launchctl bootout "pid/$WCPID" "$K/fake/MTLCompilerService.xpc" 2>/dev/null
  rm -f /private/tmp/tee-fake-ran-* 2>/dev/null
  [ -n "${WCPID:-}" ] && launchctl bootout "pid/$WCPID" "$K/fake/TEEFakeCtl.xpc" 2>/dev/null
  sleep 1
  left=$(alive_recorded | wc -l | tr -d ' '); ctlleft=$(pgrep -u "$U" -x ctlproc | wc -l | tr -d ' ')
  # The cleanup line goes into the log before the copy, so the run folder holds it.
  say "cleanup: hibernatemode=$(pmset -g | awk '/hibernatemode/{print $2}') (was $HIB0); man mount=$(mount | grep -c ' on /usr/share/man '); leftover=$left kit pids, $ctlleft control pids, server stop rc=$stop_rc"
  chmod -R a+rX "$W"
  as_user mkdir -p "$ROOT/logs/tee-rootpass-$STAMP" && as_user cp -R "$W/." "$ROOT/logs/tee-rootpass-$STAMP/"
  # A server or control that does not stop is a fault of the run (audit R4-3-03).
  if [ "$stop_rc" != 0 ] || [ "$left" != 0 ] || [ "$ctlleft" != 0 ]; then echo "FAIL cleanup left processes alive (see the cleanup line)"; exit 71; fi
}
trap cleanup EXIT

say "=== TEE ROOT PASS $STAMP host=$(sysctl -n hw.model) build=$(sw_vers -buildVersion) user=$U ==="
(cd "$K" && shasum -a 256 -c SHA256SUMS) >> "$LOG" 2>&1 || { say "FAIL kit hashes differ from SHA256SUMS; stop"; exit 70; }
# SHA256SUMS lists tee-rootpass.sh too; the running copy must be that one
# (in operator mode it runs from tools/, the listed copy is in the kit).
MYSUM=$(shasum -a 256 "$SELF/$(basename "$0")" | awk '{print $1}')
grep -q "^$MYSUM  tee-rootpass.sh\$" "$K/SHA256SUMS" || { say "FAIL this script is not the one in SHA256SUMS; rebuild the kit; stop"; exit 70; }
say "kit=$K tree=$ROOT (the tree is used only as $U)"
pgrep -f "server.py.*8199|sealed-launch" > /dev/null && { say "FAIL another sealed server is running; stop"; exit 70; }
port_busy && { say "FAIL :8199 is in use by pid $(lsof -nP -iTCP:8199 -sTCP:LISTEN -t | head -1); stop"; exit 70; }

# --- Checklist (A-8, A-9, A-11, A-21)
say "--- checklist"
csrutil status | tee -a "$LOG"
csrutil authenticated-root status 2>&1 | tail -1 | tee -a "$LOG"
bputil -d < /dev/null 2>&1 | grep -iE "security mode|kernel extensions|kernel debugging|SIP|boot-args|DEP" | grep -viE "nonce|hash" | tee -a "$LOG"
say "kern.hv_vmm_present=$(sysctl -n kern.hv_vmm_present) /dev/kmem=$( [ -e /dev/kmem ] && echo present || echo absent ) /dev/mem=$( [ -e /dev/mem ] && echo present || echo absent )"
say "boot-args=$(nvram boot-args 2>&1 | tr '\t' ' ')"
sysctl -a 2>/dev/null | grep -iE "^kern\.(coredump|corefile|sugid_coredump|panic|debug|development)|^debug\.(kdp|panic)" | tee -a "$LOG"
say "vm.swapusage=$(sysctl -n vm.swapusage)"
v INFO checklist "recorded above (the oracle for A-8 is the list: no kmem, Full Security, SIP on, no hypervisor)"

# --- Start the sealed server as the user; one request puts the child in serving.
say "--- start the sealed server"
as_user sh -c ': > "$1/launch.log"' _ "$ROOT"
as_user env BENCH_OK=1 "$ROOT/run-sealed-server.sh" > "$W/server.log" 2>&1 &
SP=$!
for i in $(seq 1 60); do [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8199/v1/models)" = 200 ] && break; sleep 3; done
record_tree "$SP"
CANARY="TEEPROMPTCANARY$(date +%s)"
req() { curl -s -m 150 http://127.0.0.1:8199/v1/chat/completions -H 'Content-Type: application/json' \
  -d "{\"model\":\"audreyt/Qwen3.8-27B-Splash-abliterated\",\"messages\":[{\"role\":\"user\",\"content\":\"Repeat this word once: $CANARY\"}],\"max_tokens\":48,\"temperature\":0}"; }
req > "$W/answer1.json"
CHILD=$(ucat "$ROOT/launch.log" | awk '/spawn rc=0/{print $3}' | tail -1 | cut -d= -f2)
[ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null || { say "FAIL no serving child; stop"; exit 70; }
record_tree "$SP"
grep -q "^$CHILD " "$KIDS" || { say "FAIL child pid $CHILD is not in the kit's server tree (another server's child?); stop"; exit 70; }
say "child pid=$CHILD exe=$(ps -o comm= -p "$CHILD") answer=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["choices"][0]["message"]["content"].strip()[:80])' "$W/answer1.json" 2>/dev/null)"

# Unhardened control process (same user), fed a canary through a pipe.
mkfifo -m 644 "$W/feed"
as_user "$K/ctlproc" < "$W/feed" & CTL=$!
( while :; do echo "TEE-CONTROL-PIPE-CANARY"; sleep 0.5; done > "$W/feed" ) & FEED=$!
sleep 1; CTLPID=$(pgrep -n -u "$U" -x ctlproc)   # the user's ctlproc, not the root sudo wrapper (audit R4-3-06)

# --- A-1 task ports
say "--- A-1 task ports"
"$K/taskports" "$CHILD" > "$W/tp-child.txt" 2>&1; "$K/taskports" "$CTLPID" > "$W/tp-ctl.txt" 2>&1
sed 's/^/  child: /' "$W/tp-child.txt" | tee -a "$LOG"; sed 's/^/  control: /' "$W/tp-ctl.txt" | tee -a "$LOG"
c_for=$(awk '/^task_for_pid/{print $2}' "$W/tp-child.txt"); c_read=$(awk '/^task_read_for_pid/{print $2}' "$W/tp-child.txt")
k_for=$(awk '/^task_for_pid/{print $2}' "$W/tp-ctl.txt"); k_read=$(grep -c "read kr=0" "$W/tp-ctl.txt")
if [ "$c_for" != "kr=0" ] && [ "$c_read" != "kr=0" ] && [ "$k_for" = "kr=0" ] && [ "$k_read" -ge 1 ]; then
  v PASS A-1-task-ports "child: control and read ports refused ($c_for, $c_read); control process: port granted and memory read"
else v FAIL A-1-task-ports "child for=$c_for read=$c_read; control for=$k_for reads=$k_read"; fi

# --- A-2 dtrace attach and read
say "--- A-2 dtrace"
dtrace -p "$CHILD" -n 'pid$target::malloc:entry{}' > "$W/dt-attach-child.txt" 2>&1 & DA=$!; sleep 6; kill "$DA" 2>/dev/null
dtrace -p "$CTLPID" -n 'pid$target::read:entry{}' > "$W/dt-attach-ctl.txt" 2>&1 & DB=$!; sleep 6; kill "$DB" 2>/dev/null
a_child=$(grep -c "failed to grab pid" "$W/dt-attach-child.txt"); a_ctl=$(grep -c "matched" "$W/dt-attach-ctl.txt")
[ "$a_child" -ge 1 ] && [ "$a_ctl" -ge 1 ] && v PASS A-2-dtrace-attach "child: failed to grab pid; control: probes matched" \
  || v FAIL A-2-dtrace-attach "child: $(head -2 "$W/dt-attach-child.txt" | tr '\n' ' ') | control: $(head -2 "$W/dt-attach-ctl.txt" | tr '\n' ' ')"
dtrace -q -s "$K/dtrace-read.d" "$CHILD" > "$W/dt-read-child.txt" 2>&1 & DC=$!
dtrace -q -s "$K/dtrace-read.d" "$CTLPID" > "$W/dt-read-ctl.txt" 2>&1 & DD=$!
sleep 2; req > "$W/answer2.json"; sleep 3; kill "$DC" "$DD" 2>/dev/null; sleep 1
r_child=$(grep -c "^COPY" "$W/dt-read-child.txt"); r_ctl=$(grep -c "^COPY.*TEE-CONTROL-PIPE-CANARY" "$W/dt-read-ctl.txt")
# A child copy is a FAIL whatever the control did (audit R3-06, F-3): the
# INFO branch is only for "nothing seen anywhere".
if [ "$r_child" -gt 0 ]; then v FAIL A-2-dtrace-read "child: $r_child buffers copied: $(grep -m2 '^COPY' "$W/dt-read-child.txt" | tr '\n' ' ')"
elif [ "$r_ctl" -ge 1 ]; then v PASS A-2-dtrace-read "child: 0 buffers copied during a request; control: $r_ctl canary copies"
elif [ "$r_ctl" = 0 ]; then v INFO A-2-dtrace-read "control got no copies either (dtrace syscall copyin unavailable under SIP for all processes): child=$r_child; $(head -2 "$W/dt-read-ctl.txt" | tr '\n' ' ')"
else v FAIL A-2-dtrace-read "child: $r_child buffers copied: $(grep -m2 '^COPY' "$W/dt-read-child.txt" | tr '\n' ' ')"; fi

# --- R5-T3 lsmp
say "--- lsmp"
lsmp -p "$CHILD" > "$W/lsmp-child.txt" 2>&1; lsmp -p "$CTLPID" > "$W/lsmp-ctl.txt" 2>&1
v INFO lsmp "child: $(wc -l < "$W/lsmp-child.txt") lines, first: $(head -1 "$W/lsmp-child.txt"); control: $(wc -l < "$W/lsmp-ctl.txt") lines (full output in $W)"

# --- A-4 Endpoint Security and BPF
say "--- A-4"
# PASS needs proof that es_new_client ran and returned an error. An exit by
# signal (AMFI kills an ad-hoc binary with the restricted ES entitlement at
# exec, exit 137) or an empty es.txt means the call never ran.
"$K/esclient" > "$W/es.txt" 2>&1; es_rc=$?
if grep -q "result=0 " "$W/es.txt"; then v FAIL A-4-endpoint-security "root created an ES client: $(cat "$W/es.txt")"
elif [ "$es_rc" -ge 128 ] || ! grep -q "es_new_client result=" "$W/es.txt"; then
  v INCONCLUSIVE A-4-endpoint-security "es_new_client never ran (exit=$es_rc, es.txt $(wc -c < "$W/es.txt" | tr -d ' ') bytes): AMFI refuses the exec without a provisioning profile that grants com.apple.developer.endpoint-security.client"
else v PASS A-4-endpoint-security "es_new_client ran and refused: $(head -2 "$W/es.txt" | tr '\n' ' ')"; fi
tcpdump -i lo0 -s 0 -w "$W/lo0.pcap" > /dev/null 2>&1 & TD=$!; sleep 2; req > "$W/answer3.json"; sleep 2; kill "$TD" 2>/dev/null; sleep 1
on8199=$(strings "$W/lo0.pcap" | grep -c "$CANARY")
v INFO A-4-bpf "lo0 capture holds the prompt canary $on8199 times: this is the HTTP request to the Python server on :8199 (outside the seal, P10). The engine-to-child channel is an AF_UNIX socketpair; ifconfig lists no interface for it: $(ifconfig -l)"

# --- A-21 mount over a sealed-volume folder
say "--- A-21"
mkdir -p "$W/mnt"
mount_tmpfs -s 1048576 "$W/mnt" > "$W/mount-ctl.txt" 2>&1; mc_rc=$?
# The control's own evidence: its exit code and the mount table line while
# it is mounted (audit R4-3-01).
{ echo "# control mount_tmpfs rc=$mc_rc"; echo "# mount line: $(mount | grep " on $W/mnt " | head -1)"; } >> "$W/mount-ctl.txt"
[ $mc_rc = 0 ] && umount "$W/mnt"
mount_tmpfs -s 1048576 /usr/share/man > "$W/mount.txt" 2>&1; m_rc=$?
if [ $m_rc = 0 ]; then umount /usr/share/man; v FAIL A-21-mount-over "root mounted tmpfs over /usr/share/man (removed at once)"
elif [ $mc_rc = 0 ] && grep -q "^# mount line: .* on $W/mnt " "$W/mount-ctl.txt"; then v PASS A-21-mount-over "refused over /usr/share/man ($(head -1 "$W/mount.txt" | tr -d '\n')); control: the same tmpfs mount on a scratch folder worked (mount-ctl.txt: rc=0 and its mount line)"
else v INFO A-21-mount-over "no valid control: tmpfs mount failed on a scratch folder too ($(head -1 "$W/mount-ctl.txt" | tr -d '\n'))"; fi
v INFO A-21-hypervisor "kern.hv_vmm_present=$(sysctl -n kern.hv_vmm_present); $(csrutil authenticated-root status 2>&1 | tail -1)"

# --- R4-T5 fake compiler service in a Metal client's pid domain
say "--- R4-T5"
FLAG=$W/wc-go
as_user "$K/waitclient" "$FLAG" > "$W/wc.txt" 2>&1 & WC=$!
sleep 1; WCPID=$(awk -F= '/waitclient pid=/{print $2}' "$W/wc.txt")
launchctl bootstrap "pid/$WCPID" "$K/fake/MTLCompilerService.xpc" > "$W/bootstrap.txt" 2>&1; b_rc=$?
launchctl bootstrap "pid/$WCPID" "$K/fake/TEEFakeCtl.xpc" > "$W/bootstrap-ctl.txt" 2>&1; bc_rc=$?
launchctl print "pid/$WCPID" > "$W/piddomain.txt" 2>&1
touch "$FLAG"; sleep 8
ran=$(ls /private/tmp/tee-fake-ran-com.apple.MTLCompilerService-* 2>/dev/null | wc -l | tr -d ' ')
ctl=$(ls /private/tmp/tee-fake-ran-com.tee.fakectl-* 2>/dev/null | wc -l | tr -d ' ')
res=$(grep "library=" "$W/wc.txt")
# launchd accepts a pid-domain bootstrap only from the domain's own process
# (2026-10-21: root gets "failed to uncork PID domain on first bootstrap: 131",
# the user gets "exec count or caller mismatch"; xpc_add_bundle from inside
# the process does start TEEFakeCtl). So the control normally does not fire,
# and the Apple-name refusal is then not specific: the arm says INCONCLUSIVE.
if [ "$ran" -ge 1 ] || ! echo "$res" | grep -q "pipeline=ok"; then
  v FAIL R4-T5-pid-domain "Apple-named fake: bootstrap rc=$b_rc, ran=$ran; client: $res; domain: $(grep -A3 'services =' "$W/piddomain.txt" | tr '\n' ' ')"
elif [ "$ctl" -ge 1 ]; then
  v PASS R4-T5-pid-domain "Apple-named fake: bootstrap rc=$b_rc ($(head -1 "$W/bootstrap.txt" | tr -d '\n')), never ran; the client compiled with the real service ($res); the test-named control ran"
else
  v INCONCLUSIVE R4-T5-pid-domain "CONTROL DID NOT FIRE: Apple-named fake never ran (rc=$b_rc), but the test-named fake did not run either (rc=$bc_rc), so the refusal is not specific to the Apple name"
fi
if [ "$ctl" -ge 1 ]; then v PASS R4-T5-control "test-named fake bootstrapped by root (rc=$bc_rc) ran when the client connected: root's pid-domain injection works, so the Apple-name refusal is meaningful"
else v INCONCLUSIVE R4-T5-control "CONTROL DID NOT FIRE: test-named fake did not run (bootstrap rc=$bc_rc: $(head -1 "$W/bootstrap-ctl.txt" | tr -d '\n')); launchd refuses outside bootstraps into a pid domain"; fi

# --- A-5 sleep image
say "--- A-5"
SI=/var/vm/sleepimage
if [ -f "$SI" ]; then
  ls -lO "$SI" | tee -a "$LOG"
  python3 - "$SI" <<'PY' | tee -a "$LOG"
import math, sys
f = open(sys.argv[1], 'rb'); size = f.seek(0, 2); f.seek(0)
pages = zero = 0; hist = [0] * 256; sampled = 0
step = max(1, size // (64 * 1024 * 1024)) * 4096
for off in range(0, size, step):
    f.seek(off); p = f.read(4096)
    if not p: break
    pages += 1
    if p.count(0) == len(p): zero += 1
    else:
        for b in p: hist[b] += 1
        sampled += len(p)
ent = -sum(c / sampled * math.log2(c / sampled) for c in hist if c) if sampled else 0
print(f"sleepimage size={size} sampled_pages={pages} zero_pages={zero} nonzero_entropy_bits_per_byte={ent:.3f}")
PY
  v INFO A-5-sleepimage "root can read the file; zero share and entropy above (all-zero = no image written; ~8.0 bits = encrypted or random; lower = possible plaintext)"
else v INFO A-5-sleepimage "no $SI"; fi
pmset -a hibernatemode 25 > "$W/pmset.txt" 2>&1; now=$(pmset -g | awk '/hibernatemode/{print $2}'); pmset -a hibernatemode "$HIB0"
v INFO A-5-hibernatemode "root set hibernatemode 25 -> reads back $now (restored to $HIB0). A forced standby with a canary is still needed to settle A-5."

# --- R4-T4 files the child touches before its sandbox (fresh start under fs_usage)
# fs_usage traces by pid list when the kit child is known; before it starts,
# it traces by name. One request goes to the second server, so a compile at
# the first request is covered. Positive control (audit R4-3-02): an
# unsandboxed Metal client (waitclient) compiles a fresh kernel under the same
# capture, and the capture must show its write into com.apple.metal.
say "--- R4-T4"
R4T4_OK=1
if ! stop_server; then
  R4T4_OK=0; say "R4-T4: the first server did not stop: $STOP_WHY; no second start"
else
  fs_usage -w -f pathname splash waitclient MTLCompilerService > "$W/fsusage.txt" 2>&1 & FU=$!
  as_user sh -c ': > "$1/launch.log"' _ "$ROOT"; as_user env BENCH_OK=1 "$ROOT/run-sealed-server.sh" > "$W/server2.log" 2>&1 & SP=$!
  for i in $(seq 1 60); do [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8199/v1/models)" = 200 ] && break
    kill -0 "$SP" 2>/dev/null || break; sleep 3; done
  record_tree "$SP"
  req > "$W/answer4.json"
  CHILD2=$(ucat "$ROOT/launch.log" | awk '/spawn rc=0/{print $3}' | tail -1 | cut -d= -f2)
  record_tree "$SP"
  # The control window starts here: compiler-service rows before it belong to
  # the child's start, rows after it to the control client.
  T_CTL=$(date +%H:%M:%S); FLAG2=$W/wc2-go; touch "$FLAG2"
  as_user "$K/waitclient" "$FLAG2" > "$W/wc2.txt" 2>&1; wc2_rc=$?
  sleep 2; kill "$FU" 2>/dev/null; sleep 1
  kill -0 "$SP" 2>/dev/null || { R4T4_OK=0; say "R4-T4: the second server exited: $(tail -1 "$W/server2.log")"; }
  grep -q "^$CHILD2 " "$KIDS" 2>/dev/null || { R4T4_OK=0; say "R4-T4: second child pid '$CHILD2' is not in the kit's server tree"; }
fi
: >> "$W/fsusage.txt"
# fs_usage names rows by thread (splash.<tid>), and the engine's own child is
# also named splash. Its rows can only add matches, so they can turn a PASS
# into a FAIL but never hide a write of the kit's child (fail closed).
say "R4-T4: second child pid=${CHILD2:-none} answer=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["choices"][0]["message"]["content"].strip()[:40])' "$W/answer4.json" 2>/dev/null)"
grep -E "splash\." "$W/fsusage.txt" > "$W/fsusage-child.txt"
started=$(grep -c . "$W/fsusage-child.txt")
mc=$(grep -iE "com\.apple\.metal|/Library/Caches/" "$W/fsusage-child.txt" | grep -v "sealed-child-" | grep -vE "\[\s*-?[0-9]+\] \(" | grep -c .)
wr=$(grep -E "WrData|open .*W|mkdir|rename|unlink|create" "$W/fsusage-child.txt" | grep -v "sealed-child-" | grep -vE "\[\s*-?[0-9]+\] \(" | grep -c .)
ctlw=$(grep -E "waitclient|MTLCompilerService" "$W/fsusage.txt" | awk -v t="${T_CTL:-99}" '$1 >= t' | grep -iE "com\.apple\.metal" | grep -vE "\[\s*-?[0-9]+\] \(" | grep -c .)
echo "# control: waitclient rc=${wc2_rc:-none} $(tail -1 "$W/wc2.txt" 2>/dev/null); window from ${T_CTL:-none}; successful com.apple.metal rows of waitclient or MTLCompilerService=$ctlw" > "$W/r4t4-control.txt"
if [ "$R4T4_OK" = 0 ] || [ "$started" = 0 ]; then v INCONCLUSIVE R4-T4-no-metal-cache-outside-tmpdir "not valid this run: second start ok=$R4T4_OK, fs_usage child events=$started ($(wc -c < "$W/fsusage.txt" | tr -d ' ') bytes)"
elif [ "$mc" != 0 ]; then v FAIL R4-T4-no-metal-cache-outside-tmpdir "$mc lines: $(grep -iE 'com\.apple\.metal|/Library/Caches/' "$W/fsusage-child.txt" | grep -v sealed-child- | head -3 | tr '\n' ';')"
elif [ "$ctlw" -lt 1 ]; then v INCONCLUSIVE R4-T4-no-metal-cache-outside-tmpdir "CONTROL DID NOT FIRE: the unsandboxed Metal client's cache write is not in the same capture (r4t4-control.txt), so absence in the child proves nothing"
else v PASS R4-T4-no-metal-cache-outside-tmpdir "$started child events incl. one request; none touch a Metal cache outside the private TMPDIR; control: the unsandboxed client's $ctlw com.apple.metal rows are in the same capture"; fi
if [ "$R4T4_OK" = 0 ] || [ "$started" = 0 ]; then v INCONCLUSIVE R4-T4-writes "not valid this run: fsusage.txt holds no child start"
else v INFO R4-T4-writes "write-like file events outside the private TMPDIR during start: $wr (list in fsusage-child.txt)"; fi

# --- P10: the v2 engine (if it serves on :29452). The prompt canary must
#     never be on lo0 in plain text, and root must not get the engine's task
#     port or attach dtrace to it. Control: the same capture finds the canary
#     on the Python server's :8199 hop above (A-4-bpf).
say "--- P10 engine"
EPID=$(pgrep -f "SealedEngineV2.app/Contents/MacOS/SealedEngine" | head -1)
if [ -n "$EPID" ] && [ -x "$K/sealed-chat" ]; then
  # Bind the pid to the pinned engine before the arms (audit R3-03).
  ECDH=$(codesign -dvvv "$EPID" 2>&1 | sed -n 's/^CandidateCDHashFull sha256=//p')
  echo "pid=$EPID lstart=$(ps -o lstart= -p "$EPID" | tr -s ' ' _) cdhash=$ECDH pinned=$(cat "$K/engine-cdhash")" > "$W/engine-pid.txt"
  say "engine $(cat "$W/engine-pid.txt")"
  if [ "$ECDH" != "$(cat "$K/engine-cdhash")" ]; then
    v FAIL P10-engine-identity "engine pid $EPID has CD hash '$ECDH', not the pinned $(cat "$K/engine-cdhash")"
  else v PASS P10-engine-identity "engine pid $EPID runs the pinned CD hash $ECDH"; fi
  "$K/taskports" "$EPID" > "$W/tp-engine.txt" 2>&1
  e_for=$(awk '/^task_for_pid/{print $2}' "$W/tp-engine.txt"); e_read=$(awk '/^task_read_for_pid/{print $2}' "$W/tp-engine.txt")
  # The shared ctlproc control from A-1 is part of the rule (audit F-11).
  if [ "$e_for" = "kr=0" ] || [ "$e_read" = "kr=0" ]; then v FAIL P10-engine-task-ports "engine pid $EPID: for=$e_for read=$e_read"
  elif [ "$k_for" != "kr=0" ] || [ "$k_read" -lt 1 ]; then v INCONCLUSIVE P10-engine-task-ports "engine refused ($e_for, $e_read), but the shared ctlproc control did not fire"
  else v PASS P10-engine-task-ports "engine pid $EPID: control and read ports refused ($e_for, $e_read); shared ctlproc control read memory"; fi
  dtrace -p "$EPID" -n 'pid$target::malloc:entry{}' > "$W/dt-attach-engine.txt" 2>&1 & DE=$!; sleep 6; kill "$DE" 2>/dev/null
  if ! grep -q "failed to grab pid" "$W/dt-attach-engine.txt"; then v FAIL P10-engine-dtrace-attach "$(head -2 "$W/dt-attach-engine.txt" | tr '\n' ' ')"
  elif [ "$a_ctl" -lt 1 ]; then v INCONCLUSIVE P10-engine-dtrace-attach "dtrace could not grab the engine, but the shared control did not fire"
  else v PASS P10-engine-dtrace-attach "dtrace could not grab the engine; shared control matched probes"; fi
  # The engine checks its child only when a request arrives (and then exits,
  # fail closed, if the child is gone), and /attest answers without a child.
  # So check the child directly: a live splash process whose parent is the
  # engine. Without one, do not send the request (it would stop the engine)
  # and do not grade the arms. The child pid is kept in engine-child.txt (and
  # engine-child-pid.txt) for the two child arms below.
  ECHILD=""; for c in $(pgrep -P "$EPID"); do case "$(ps -o comm= -p "$c")" in */child/splash) ECHILD=$c ;; esac; done
  if [ -n "$ECHILD" ]; then
    echo "$ECHILD" > "$W/engine-child-pid.txt"
    echo "pid=$ECHILD ppid=$EPID lstart=$(ps -o lstart= -p "$ECHILD" | tr -s ' ' _) comm=$(ps -o comm= -p "$ECHILD")" > "$W/engine-child.txt"
  else
    : > "$W/engine-child-pid.txt"
    echo "pid=none ppid=$EPID" > "$W/engine-child.txt"
  fi
  # P10 child arms: the kit's A-1/A-2 target its own server child; these two
  # target the engine's sealed child/splash. Same grade rule: refusal, a fired
  # control (the shared ctlproc control from A-1/A-2), and non-empty evidence.
  if [ -z "$ECHILD" ]; then
    v INCONCLUSIVE P10-engine-child-task-ports "the engine (pid $EPID) has no live child/splash process: the engine was not touched"
    v INCONCLUSIVE P10-engine-child-dtrace-attach "the engine (pid $EPID) has no live child/splash process: the engine was not touched"
    v INCONCLUSIVE P10-lo0-ciphertext-only "the engine (pid $EPID) has no live child/splash process; the chat request was not sent (it would stop the engine)"
  else
  say "engine child pid=$ECHILD (parent $EPID)"
  "$K/taskports" "$ECHILD" > "$W/tp-engine-child.txt" 2>&1
  ec_for=$(awk '/^task_for_pid/{print $2}' "$W/tp-engine-child.txt"); ec_read=$(awk '/^task_read_for_pid/{print $2}' "$W/tp-engine-child.txt")
  if [ "$ec_for" = "kr=0" ] || [ "$ec_read" = "kr=0" ]; then
    v FAIL P10-engine-child-task-ports "engine child pid $ECHILD: a task port was granted (for=$ec_for read=$ec_read)"
  elif [ ! -s "$W/tp-engine-child.txt" ]; then
    v INCONCLUSIVE P10-engine-child-task-ports "engine child pid $ECHILD: empty evidence"
  elif [ "$k_for" != "kr=0" ] || [ "$k_read" -lt 1 ]; then
    v INCONCLUSIVE P10-engine-child-task-ports "engine child refused ($ec_for, $ec_read), but the shared ctlproc control did not fire (control for=$k_for reads=$k_read)"
  else
    v PASS P10-engine-child-task-ports "engine child pid $ECHILD: control and read ports refused ($ec_for, $ec_read); shared ctlproc control read memory"
  fi
  dtrace -p "$ECHILD" -n 'pid$target::malloc:entry{}' > "$W/dt-attach-engine-child.txt" 2>&1 & DCE=$!; sleep 6; kill "$DCE" 2>/dev/null
  ec_dt=$(grep -c "failed to grab pid" "$W/dt-attach-engine-child.txt")
  if [ "$ec_dt" -lt 1 ]; then
    v FAIL P10-engine-child-dtrace-attach "engine child pid $ECHILD: $(head -2 "$W/dt-attach-engine-child.txt" | tr '\n' ' ')"
  elif [ ! -s "$W/dt-attach-engine-child.txt" ]; then
    v INCONCLUSIVE P10-engine-child-dtrace-attach "engine child pid $ECHILD: empty evidence"
  elif [ "$a_ctl" -lt 1 ]; then
    v INCONCLUSIVE P10-engine-child-dtrace-attach "dtrace could not grab the engine child, but the shared control did not fire (matched=$a_ctl)"
  else
    v PASS P10-engine-child-dtrace-attach "engine child pid $ECHILD: dtrace could not grab it; shared control matched probes"
  fi
  PC="P10ROOTCANARY$(date +%s)$RANDOM"
  tcpdump -i lo0 -s 0 -w "$W/lo0-engine.pcap" "tcp port 29452" > /dev/null 2>&1 & TE=$!; sleep 2
  as_user "$K/sealed-chat" --engine http://127.0.0.1:29452 --app-id "$(cat "$K/engine-appid")" --cdhash "$(cat "$K/engine-cdhash")" \
    --weights "$(cat "$K/engine-modelhash")" --prompt "Repeat this code exactly once: $PC" --max-tokens 48 > "$W/p10-chat.txt" 2>&1
  sleep 2; kill "$TE" 2>/dev/null; sleep 1
  got=$(grep -c "REPLY.*$PC" "$W/p10-chat.txt"); onwire=$(strings "$W/lo0-engine.pcap" | grep -c "$PC"); bytes=$(stat -f %z "$W/lo0-engine.pcap")
  e_alive=$(kill -0 "$ECHILD" 2>/dev/null && echo yes || echo no)
  if [ "$onwire" -ge 1 ]; then v FAIL P10-lo0-ciphertext-only "the prompt canary is on lo0 $onwire times (capture=$bytes bytes)"
  elif [ "$got" -ge 1 ] && [ "$bytes" -gt 1000 ]; then v PASS P10-lo0-ciphertext-only "the reply held the canary, and a $bytes-byte capture of :29452 holds it 0 times"
  else v INCONCLUSIVE P10-lo0-ciphertext-only "no reply with the canary (reply-has-canary=$got, child alive after=$e_alive, capture=$bytes bytes, on-wire=0): the reply leg was not tested"; fi
  # P6-gcore: Apple's root-entitled gcore (cs.debugger.read.root) on the engine
  # and the engine's child, with a decoy control in the same run. gcore opens
  # the core file as the target's uid, so cores go to a folder the user owns.
  # The control uses -x stack, the same core kind as the targets (audits
  # R2-08, R2-09, R2-5-12).
  GD=$(as_user mktemp -d /private/tmp/teegcore.XXXXXX)
  as_user "$K/ctlproc" < /dev/null > /dev/null 2>&1 & GCTL=$!; sleep 2
  # The decoy is the ctlproc under this job's sudo, never the A-1 control
  # (audit R4-3-07). Its flags come from the running process.
  GCTLPID=""; for c in $(tree "$GCTL"); do [ "$(ps -o comm= -p "$c" 2>/dev/null)" = "$K/ctlproc" ] && [ "$(ps -o user= -p "$c")" = "$U" ] && GCTLPID=$c; done
  [ "$GCTLPID" = "${CTLPID:-x}" ] && GCTLPID=""
  {
    if [ -n "$GCTLPID" ]; then
      echo "# decoy pid=$GCTLPID user=$(ps -o user= -p "$GCTLPID") flags=$(codesign -dv "$GCTLPID" 2>&1 | sed -n 's/.*flags=\(0x[0-9a-f]*\).*/\1/p')"
    else echo "# decoy did not start (no ctlproc under job $GCTL)"; fi
    gcore -x stack -o "$GD/ctl" "$GCTLPID" 2>&1; echo "# gcore rc=$?"
  } > "$W/gcore-ctl.txt"
  g_ctl=$(sed -n 's/^# gcore rc=//p' "$W/gcore-ctl.txt")
  g_ctl_sz=$(stat -f %z "$GD/ctl" 2>/dev/null || echo 0)
  echo "# core bytes=$g_ctl_sz sha256=$(shasum -a 256 "$GD/ctl" 2>/dev/null | cut -c1-64)" >> "$W/gcore-ctl.txt"
  # Stop the decoy and its sudo parent by pid (the bash job alone leaks them).
  for c in $(tree "$GCTL" | tail -r); do kill "$c" 2>/dev/null; done; sleep 1
  # Check the decoy by pid: the A-1 control is also a ctlproc and lives on.
  [ -n "$GCTLPID" ] && kill -0 "$GCTLPID" 2>/dev/null && echo "# decoy still alive after cleanup" >> "$W/gcore-ctl.txt"
  for tgt in engine:$EPID engine-child:$ECHILD; do
    nm=${tgt%%:*}; pid=${tgt#*:}
    gcore -x stack -o "$GD/$nm" "$pid" > "$W/gcore-$nm.txt" 2>&1; g_rc=$?
    g_sz=$(stat -f %z "$GD/$nm" 2>/dev/null || echo 0)
    arm=P6-gcore-$nm
    if [ "$g_rc" = 0 ] || [ "$g_sz" -gt 0 ]; then v FAIL $arm "root gcore dumped pid $pid (rc=$g_rc, core=$g_sz bytes)"
    elif [ "$g_ctl" != 0 ] || [ "$g_ctl_sz" -lt 1 ] || ! grep -q "^# decoy pid=[0-9]" "$W/gcore-ctl.txt"; then v INCONCLUSIVE $arm "pid $pid refused ($(tail -1 "$W/gcore-$nm.txt")), but the decoy control did not dump (rc=$g_ctl, core=$g_ctl_sz bytes)"
    elif ! grep -q "insufficient privilege" "$W/gcore-$nm.txt"; then v INCONCLUSIVE $arm "pid $pid: no core, but the error is not the kernel refusal: $(tail -1 "$W/gcore-$nm.txt")"
    else v PASS $arm "root gcore refused on pid $pid (rc=$g_rc, insufficient privilege); decoy control dumped a $g_ctl_sz-byte stack core in the same run"; fi
  done
  rm -rf "$GD"
  fi
else v INFO P10-engine "no v2 engine on :29452 or no sealed-chat in the kit: arms not run"; fi

say "results: $ROOT/logs/tee-rootpass-$STAMP/ (copied as $U on exit)"
say "=== TEE ROOT PASS end: $(grep -c '^PASS' "$LOG") PASS, $(grep -c '^FAIL' "$LOG") FAIL, $(grep -c '^INCONCLUSIVE' "$LOG") INCONCLUSIVE, $(grep -c '^INFO' "$LOG") INFO ==="
