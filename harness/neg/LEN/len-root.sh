#!/bin/bash
# R2-5-03: can root learn the prompt and reply length from the engine-to-child
# channel? Root runs fs_usage on the engine and the child while the user sends
# two chats of different lengths. The script then compares the channel write
# sizes with the token counts that the wire format predicts:
#   request frame = 24 + 64 + 4 * prompt_tokens bytes (engine writes)
#   tokens  frame = 24 + 16 + 4 * n_tokens     bytes (child writes)
# Pass/fail criteria, written before the run:
#   CONFIRMED  the engine write sizes for the two chats differ and each equals
#              24+64+4*P for an integer P, and the child writes include
#              24+16+4*n frames: root can read prompt and reply token counts.
#   NOT SHOWN  no write size fits the formula (fs_usage does not show sizes,
#              or the channel is not visible): the limit is not demonstrated.
#   VOID       fs_usage captured no events for the pids (control failed).
# Read-only toward the sealed processes: fs_usage only observes.
#   sudo neg/LEN/len-root.sh <engine-pid> <child-pid>
set -u
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 64; }
E=${1:?engine pid}; C=${2:?child pid}
U=${SUDO_USER:?run this with sudo from your own account}
OUT=$PWD/len-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"; chown "$U" "$OUT"
exec > >(tee "$OUT/report.txt") 2>&1
echo "# len-root $(date '+%F %T %Z') $(sw_vers -buildVersion) sip=$(csrutil status | sed 's/.*: //')"
echo "# engine=$E child=$C"
K=/usr/local/libexec/tee-rootkit
CD=$(cat "$K/engine-cdhash"); W=$(cat "$K/engine-modelhash"); APP=$(cat "$K/engine-appid")

fs_usage -w -f network,filesys "$E" "$C" > "$OUT/fsusage.txt" 2>&1 & FS=$!
sleep 3
chat() { sudo -u "$U" -H "$K/sealed-chat" --app-id "$APP" --cdhash "$CD" --weights "$W" --max-tokens "$2" --prompt "$1" 2>&1; }
echo "== chat A (short prompt, short reply)"
chat "Name the capital of France in one word." 8 | tee "$OUT/chatA.txt" | grep -E "REPLY|SENT"
sleep 2
echo "== chat B (longer prompt, longer reply)"
chat "List the names of the twelve months of the year, separated by commas, and nothing else. Do not number them." 64 | tee "$OUT/chatB.txt" | grep -E "REPLY|SENT"
sleep 3
kill "$FS" 2>/dev/null; sleep 1
chown -R "$U" "$OUT"
echo "== fs_usage events: total=$(wc -l < "$OUT/fsusage.txt") engine=$(grep -c "SealedEngine" "$OUT/fsusage.txt") child=$(grep -c "splash" "$OUT/fsusage.txt")"
echo "# done; analyse with: python3 neg/LEN/len-grade.py $OUT"
