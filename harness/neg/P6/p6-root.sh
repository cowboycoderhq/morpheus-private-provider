#!/bin/bash
# P6 root arms (review/P6-GPU-MEMORY-2026-10-23.md). Run by the operator:
#   sudo neg/P6/p6-root.sh <child-pid>
# <child-pid> is a serving sealed child (child/splash, pin in child/pin.txt).
# Every arm on the child only asks for a port or writes a stack-only core,
# so the child keeps serving. Output: neg/P6/root-<time>.txt
set -u
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 64; }
CHILD=${1:?child pid}
OUT=$PWD/root-$(date +%Y%m%d-%H%M%S).txt
exec > >(tee "$OUT") 2>&1
C=P6ROOT$(date +%s)Q
W=$(mktemp -d /tmp/p6root.XXXXXX); chmod 700 "$W"
echo "# p6-root $(date '+%F %T %Z') uid=$(id -u) host=$(sysctl -n hw.model) $(sw_vers -buildVersion) sip=$(csrutil status | sed 's/.*: //')"
echo "# child pid=$CHILD comm=$(ps -o comm= -p "$CHILD") cdhash=$(codesign -dv --verbose=4 "$(ps -o comm= -p "$CHILD")" 2>&1 | sed -n 's/^CDHash=//p') pin=$(cat ../../child/pin.txt)"
for f in p6-victim p6-victim-hr p6-scan p6-gpuclient; do echo "# sha256 $f $(shasum -a 256 $f | cut -c1-64)"; done
start() { sudo -u "#${SUDO_UID:-501}" ./"$1" "$C" 300 > "$W/$1.out" 2>&1 & sleep 3; pgrep -n -f "./$1 $C"; }
hits() { echo "S=$(LC_ALL=C grep -a -o "S-$C" "$1" 2>/dev/null | wc -l | tr -d ' ') P=$(LC_ALL=C grep -a -o "P-$C" "$1" 2>/dev/null | wc -l | tr -d ' ')"; }

V=$(start p6-victim); H=$(start p6-victim-hr)
echo "# victims: ordinary pid=$V hardened pid=$H"

echo "## A1 task port + mach_vm_read (root)"
for p in $V $H $CHILD; do echo "ARM A1 pid=$p"; ./p6-scan "$p" "$C" | sed 's/^/  /'; done

echo "## A2 gcore (com.apple.security.cs.debugger.read.root)"
for p in $V $H; do
  rm -f "$W/core.$p"; gcore -o "$W/core.$p" "$p" > "$W/gcore.$p.txt" 2>&1; rc=$?
  echo "ARM A2 pid=$p rc=$rc $(tail -1 "$W/gcore.$p.txt") size=$(stat -f %z "$W/core.$p" 2>/dev/null || echo none) $(hits "$W/core.$p")"
  rm -f "$W/core.$p"
done
gcore -x stack -o "$W/core.child" "$CHILD" > "$W/gcore.child.txt" 2>&1; rc=$?
echo "ARM A2 pid=$CHILD (child, -x stack) rc=$rc $(tail -1 "$W/gcore.child.txt") size=$(stat -f %z "$W/core.child" 2>/dev/null || echo none)"
rm -f "$W/core.child"

echo "## A3 system-task-ports.read tools (root)"
for p in $V $H $CHILD; do
  echo "ARM A3 pid=$p stringdups: $(stringdups "$p" 2>&1 | grep -c "$C") hits; $(stringdups "$p" 2>&1 | grep -m1 -iE 'debuggable|restricted' || echo 'no restriction line')"
  echo "ARM A3 pid=$p vmmap: $(vmmap -summary "$p" 2>&1 | grep -E 'IOAccelerator \(graphics\)' | awk '{print "graphics_virtual=" $4}' | head -1) $(vmmap "$p" 2>&1 | grep -m1 -iE 'error|denied|not permitted' || echo 'no error line')"
done

echo "## A4 root GPU client self-scan (expect S=1 P=1 baseline: the pattern strings)"
./p6-gpuclient "$C" | sed 's/^/  /'

echo "## A5 powermetrics GPU sampler (metadata check)"
powermetrics --samplers gpu_power --show-process-gpu -n 1 -i 500 2>&1 | grep -iE "gpu|$C" | head -12 | sed 's/^/  /'
echo "  canary_in_powermetrics=$(powermetrics --samplers gpu_power --show-process-gpu -n 1 -i 500 2>&1 | grep -c "$C")"

kill "$V" "$H" 2>/dev/null
rm -rf "$W"
echo "# done $(date '+%T') child_alive=$(kill -0 "$CHILD" 2>/dev/null && echo yes || echo no)"
