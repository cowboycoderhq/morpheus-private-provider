#!/bin/bash
# R3-5-04: do the child's tokens-frame sizes show how predictable the reply is?
# Each tokens frame seems to carry one speculative-decoding step (1 to 8
# tokens). If the draft model's acceptance shows in the frame sizes, root can
# tell a predictable reply from an unpredictable one of the same length.
#
# Criteria, written before the run:
#   SIGNAL     the predictable replies have a clearly larger mean tokens per
#              frame than the unpredictable replies (difference of the means
#              larger than 2 x the larger standard deviation over the runs).
#   NO SIGNAL  the means overlap within that margin.
#   VOID       fewer than 3 usable runs per kind, or no tokens frames seen.
# Root only observes (fs_usage). The user sends the chats.
#   sudo neg/LEN/spec-root.sh <engine-pid> <child-pid>
set -u
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 64; }
E=${1:?engine pid}; C=${2:?child pid}
U=${SUDO_USER:?run this with sudo from your own account}
OUT=$PWD/spec-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
exec > >(tee "$OUT/report.txt") 2>&1
echo "# spec-root $(date '+%F %T %Z') $(sw_vers -buildVersion) sip=$(csrutil status | sed 's/.*: //')"
echo "# engine=$E child=$C"
K=/usr/local/libexec/tee-rootkit
CD=$(cat "$K/engine-cdhash"); W=$(cat "$K/engine-modelhash"); APP=$(cat "$K/engine-appid")
chat() { sudo -u "$U" -H "$K/sealed-chat" --app-id "$APP" --cdhash "$CD" --weights "$W" --max-tokens 40 --prompt "$1" 2>&1 | grep -E "^REPLY" | cut -c1-140; }
# Predictable: a fixed sequence the draft model can guess. Unpredictable:
# random tokens the draft model cannot guess. Same requested length.
PRED="Write the numbers from 1 to 40 separated by single spaces, nothing else."
UNP="Repeat these words exactly, separated by single spaces, nothing else: $(LC_ALL=C tr -dc 'a-z' < /dev/urandom | fold -w 6 | head -20 | tr '\n' ' ')"
for k in 1 2 3 4; do
  for kind in pred unp; do
    P=$PRED; [ $kind = unp ] && P="$UNP"
    fs_usage -w -f filesys "$C" > "$OUT/fs-$kind-$k.txt" 2>&1 & FS=$!
    sleep 2; echo "== $kind $k"; chat "$P"; sleep 2
    kill "$FS" 2>/dev/null; sleep 1
  done
done
chown -R "$U" "$OUT"
echo "# grading"
python3 "$PWD/spec-grade.py" "$OUT" | tee "$OUT/verdict.txt"
