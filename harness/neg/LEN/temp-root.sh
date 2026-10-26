#!/bin/bash
# R4-5-03: does the frame-size pattern of a reply repeat for the same prompt
# at temperature 0, and does it carry a content signal at temperature 0.6?
# Root only observes the child's writes with fs_usage. The user sends the
# chats through the installed kit's sealed-chat.
#
# Design: 4 open-ended prompts on different topics (the reply is not in the
# prompt), 3 runs each at temperature 0 and 3 runs each at temperature 0.6,
# 64 tokens. Each run gives a sequence of tokens per frame.
#
# Criteria, written before the run:
#   REPEATS-AT-0     at temperature 0, for at least 3 of the 4 prompts, the 3
#                    runs give the same sequence. Then root can check a
#                    guessed prompt by running it on the same open models.
#   DISTINCT-AT-0    at temperature 0, the 4 prompts give 4 different
#                    sequences (a prompt's sequence identifies it among them).
#   SIGNAL-AT-0.6    at temperature 0.6, the per-prompt means of tokens per
#                    frame differ by more than 2 x the largest per-prompt
#                    standard deviation for at least one pair of prompts.
#   VOID             a prompt has fewer than 2 usable runs at a temperature.
# Usage: sudo neg/LEN/temp-root.sh
set -u
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 64; }
U=${SUDO_USER:?run through sudo}
K=/usr/local/libexec/tee-rootkit
E=$(pgrep -f "sealed-engine-v2/build/SealedEngineV2.app/Contents/MacOS/SealedEngine" | head -1)
[ -n "$E" ] || { echo "no SealedEngineV2 running"; exit 70; }
C=""; for c in $(pgrep -P "$E"); do case "$(ps -o comm= -p "$c")" in */child/splash) C=$c ;; esac; done
[ -n "$C" ] || { echo "the engine (pid $E) has no child/splash"; exit 70; }
OUT=$PWD/temp-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
exec > >(tee "$OUT/report.txt") 2>&1
echo "# temp-root $(date '+%F %T %Z') $(sw_vers -buildVersion) sip=$(csrutil status | sed 's/.*: //')"
echo "# engine=$E cdhash=$(codesign -dvvv "$E" 2>&1 | sed -n 's/^CandidateCDHashFull sha256=//p') child=$C pinned=$(cat "$K/engine-cdhash")"
CD=$(cat "$K/engine-cdhash"); W=$(cat "$K/engine-modelhash"); APP=$(cat "$K/engine-appid")
chat() { sudo -u "$U" -H "$K/sealed-chat" --app-id "$APP" --cdhash "$CD" --weights "$W" --max-tokens 64 --temperature "$1" --prompt "$2" 2>&1 | grep -E "^(REPLY|FAIL)" | cut -c1-160; }
PROMPTS=(
  "Describe a lighthouse on a stormy night in three sentences."
  "Explain how a bicycle gear system works to a ten-year-old."
  "Write a short complaint letter about a late train."
  "List some reasons people keep houseplants, and explain one of them."
)
for t in 0 0.6; do
  for i in 0 1 2 3; do
    for k in 1 2 3; do
      f="$OUT/fs-t$t-p$i-r$k.txt"
      fs_usage -w -f filesys "$C" > "$f" 2>&1 & FS=$!
      sleep 2; echo "== t=$t p=$i r=$k"; chat "$t" "${PROMPTS[$i]}"; sleep 2
      kill "$FS" 2>/dev/null; sleep 1
    done
  done
done
chown -R "$U" "$OUT"
echo "# grading"
python3 "$PWD/temp-grade.py" "$OUT" | tee "$OUT/verdict.txt"
