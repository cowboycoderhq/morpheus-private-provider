#!/bin/bash
# P6 A2 retry: root gcore with a working control.
# The first run's control failed to WRITE its core file (/tmp/p6root.* is
# chmod 700 and owned by root, and gcore drops to the target's uid before it
# opens the output). That made the control void, not a read refusal.
# Here each core goes to a folder gcore can write: /cores (root-owned, 755)
# for root-run gcore, with the decoy started fresh.
#   sudo neg/P6/p6-gcore-retry.sh <child-pid>
set -u
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 64; }
CHILD=${1:?child pid}
OUT=$PWD/gcore-retry-$(date +%Y%m%d-%H%M%S).txt
exec > >(tee "$OUT") 2>&1
C=P6GCORE$(date +%s)Q
# gcore opens the core as the target uid, so write into a folder that uid owns.
D=$(sudo -u "#${SUDO_UID:-501}" mktemp -d /private/tmp/p6gcore.XXXXXX)
echo "# p6-gcore-retry $(date '+%F %T %Z') uid=$(id -u) $(sw_vers -buildVersion) sip=$(csrutil status | sed 's/.*: //')"
echo "# child pid=$CHILD cdhash=$(codesign -dv --verbose=4 "$(ps -o comm= -p "$CHILD")" 2>&1 | sed -n 's/^CDHash=//p')"
hits() { echo "S=$(LC_ALL=C grep -a -o "S-$C" "$1" 2>/dev/null | wc -l | tr -d ' ') P=$(LC_ALL=C grep -a -o "P-$C" "$1" 2>/dev/null | wc -l | tr -d ' ')"; }

sudo -u "#${SUDO_UID:-501}" ./p6-victim "$C" 300 > /dev/null 2>&1 &
sleep 3; V=$(pgrep -n -f "./p6-victim $C")
echo "# control: ordinary decoy pid=$V"

# Control: root gcore of an ordinary decoy, full core, into /cores.
rm -f "$D/p6.ctl"
gcore -o "$D/p6.ctl" "$V" > /tmp/p6-gcore-ctl.txt 2>&1; rc=$?
echo "ARM A2-CTL pid=$V rc=$rc $(tail -1 /tmp/p6-gcore-ctl.txt) size=$(stat -f %z "$D/p6.ctl" 2>/dev/null || echo none) $(hits "$D/p6.ctl")"
rm -f "$D/p6.ctl" /tmp/p6-gcore-ctl.txt

# Target: root gcore of the sealed child, stack only (the child keeps serving).
rm -f "$D/p6.child"
gcore -x stack -o "$D/p6.child" "$CHILD" > /tmp/p6-gcore-child.txt 2>&1; rc=$?
echo "ARM A2-CHILD pid=$CHILD rc=$rc $(tail -1 /tmp/p6-gcore-child.txt) size=$(stat -f %z "$D/p6.child" 2>/dev/null || echo none)"
rm -f "$D/p6.child" /tmp/p6-gcore-child.txt

kill "$V" 2>/dev/null
rm -rf "$D"
echo "# done $(date '+%T') child_alive=$(kill -0 "$CHILD" 2>/dev/null && echo yes || echo no)"
