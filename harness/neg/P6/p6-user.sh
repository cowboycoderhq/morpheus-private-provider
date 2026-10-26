#!/bin/bash
# P6 user-level arms (review/P6-GPU-MEMORY-2026-10-23.md). No root.
#   neg/P6/p6-user.sh [child-pid]
# Arms on the child only ask for a task port or read metadata. Output: neg/P6/user-<time>.txt
set -u
cd "$(dirname "$0")"
CHILD=${1:-$(pgrep -f "sealed-m5/child/splash serve-native" | head -1)}
OUT=$PWD/user-$(date +%Y%m%d-%H%M%S).txt
exec > >(tee "$OUT") 2>&1
C=P6USER$(date +%s)Q
W=$(mktemp -d /tmp/p6user.XXXXXX)
echo "# p6-user $(date '+%F %T %Z') uid=$(id -u) host=$(sysctl -n hw.model) $(sw_vers -buildVersion) sip=$(csrutil status | sed 's/.*: //')"
echo "# child pid=${CHILD:-none} exe=$(ps -o comm= -p "${CHILD:-0}" 2>/dev/null) pin=$(cat ../../child/pin.txt)"
for f in p6-victim p6-victim-hr p6-victim-gta p6-scan p6-gpuclient p6-prefs; do echo "# sha256 $f $(shasum -a 256 $f | cut -c1-64) $(codesign -dv $f 2>&1 | grep -o 'flags=[^ ]*')"; done
start() { ./"$1" "$C" 300 > "$W/$1.out" 2>&1 & sleep 3; head -1 "$W/$1.out" >&2; pgrep -n -f "./$1 $C"; }
hits() { echo "S=$(LC_ALL=C grep -a -o "S-$C" "$1" 2>/dev/null | wc -l | tr -d ' ') P=$(LC_ALL=C grep -a -o "P-$C" "$1" 2>/dev/null | wc -l | tr -d ' ')"; }
G=$(start p6-victim-gta); V=$(start p6-victim); H=$(start p6-victim-hr)
echo "# victims: get-task-allow pid=$G ordinary pid=$V hardened pid=$H"
TARGETS="$G $V $H ${CHILD:-}"

echo "## A1 task port + mach_vm_read (user)"
for p in $TARGETS; do echo "ARM A1 pid=$p"; ./p6-scan "$p" "$C" | sed 's/^/  /'; done

echo "## A2 gcore (user)"
for p in $TARGETS; do
  if [ "$p" = "${CHILD:-x}" ]; then X="-x stack"; else X=""; fi
  rm -f "$W/core.$p"; gcore $X -o "$W/core.$p" "$p" > "$W/g.$p" 2>&1; rc=$?
  echo "ARM A2 pid=$p rc=$rc $(tail -1 "$W/g.$p") size=$(stat -f %z "$W/core.$p" 2>/dev/null || echo none) $(hits "$W/core.$p")"
  rm -f "$W/core.$p"
done

echo "## A3 system-task-ports.read tools (user)"
for p in $TARGETS; do
  echo "ARM A3 pid=$p stringdups_hits=$(stringdups "$p" 2>&1 | grep -c "$C") $(stringdups "$p" 2>&1 | grep -m1 -iE 'debuggable|restricted' || echo 'no restriction line')"
  echo "ARM A3 pid=$p vmmap $(vmmap -summary "$p" 2>&1 | grep -E '^IOAccelerator \(graphics\)' | awk '{print "graphics_virtual=" $4 " resident=" $5}') ; footprint: $(footprint "$p" 2>&1 | grep -E 'graphics' | tr -s ' ' | paste -sd ';' -)"
done

echo "## A4 GPU client self-scan (baseline S=1 P=1 are the pattern strings in the scanner)"
echo "  with victims running: $(./p6-gpuclient "$C")"
echo "  baseline other canary: $(./p6-gpuclient P6BASELINE$(date +%s)Q)"

echo "## A5 planted Metal preference file vs the child's read rules"
F=/Library/Preferences/com.apple.AppleFileServer.plist
echo "  control unsandboxed: $(./p6-prefs $F | tail -1)"
echo "  sandboxed existing root file: $(./p6-prefs $F sb | tail -1)"
echo "  sandboxed allowed path: $(./p6-prefs /usr/share/dict/words sb | tail -1)"

kill $G $V $H 2>/dev/null
rm -rf "$W"
echo "# done $(date '+%T') child_alive=$( [ -n "${CHILD:-}" ] && kill -0 "$CHILD" 2>/dev/null && echo yes || echo no)"
