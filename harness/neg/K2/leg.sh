#!/bin/bash
# K-2 leg (run by neg/CKV/with-server.sh, which sets PORT, CHILD_PID, RUN_DIR
# and PY). review/K2-FREED-KV-2026-10-23.md. Sends the canary request, waits
# for the child's chunk releases to stop, then runs the reader while the
# child still runs.
# usage: neg/K2/leg.sh CANARY LINES PRIV_GIB SHARED_GIB CPU_GIB
cd "$(dirname "$0")/../.."
CAN=$1; LINES=$2
RL=/tmp/sealed-reason.log
T=$PWD/pkg/qwen38-27b/tokenizer
n0=$(wc -l < $RL | tr -d ' ')
echo "REASON before_request lines=$n0 fresh_chunks=$(grep -c '^test: k2 fresh' $RL) fresh_nonzero_max=$(grep '^test: k2 fresh' $RL | sed -E 's/.* nonzero=([0-9]+) .*/\1/' | sort -n | tail -1)"
"$PY" neg/K2/req.py $PORT "$T" "$CAN" $LINES 2>> "$RUN_DIR/client.err"
# The control pass releases at most every 500 ms; wait until the release
# count holds for 4 s (at most 90 s).
last=-1; same=0
for i in $(seq 1 90); do
  c=$(sed -n "$((n0 + 1)),\$p" $RL | grep -c '^test: k2 release')
  if [ "$c" -gt 0 ] && [ "$c" = "$last" ]; then same=$((same + 1)); else same=0; fi
  [ $same -ge 4 ] && break
  last=$c; sleep 1
done
sed -n "$((n0 + 1)),\$p" $RL > "$RUN_DIR/after-request.reason"
grep '^test: k2 s ' "$RUN_DIR/after-request.reason" | awk '{print $NF}' > "$RUN_DIR/child.samples"
grep '^test: k2 release' "$RUN_DIR/after-request.reason" | sed 's/^/RELEASE /'
echo "REASON released_chunks=$(grep -c '^test: k2 release' "$RUN_DIR/after-request.reason") samples=$(wc -l < "$RUN_DIR/child.samples" | tr -d ' ') fresh_after=$(grep -c '^test: k2 fresh' "$RUN_DIR/after-request.reason") release_done=$(date '+%T')"
echo "CHILD alive_before_reader=$(kill -0 $CHILD_PID 2>/dev/null && echo yes || echo no) pid=$CHILD_PID reader_start=$(date '+%T')"
neg/K2/k2-reader scan "$RUN_DIR/child.samples" "$CAN" $3 $4 $5
echo "CHILD alive_after_reader=$(kill -0 $CHILD_PID 2>/dev/null && echo yes || echo no) reader_end=$(date '+%T')"
grep -E ' Done · ' "$RUN_DIR/server.log" | sed 's/^/DONE /'
