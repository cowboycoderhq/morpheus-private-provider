#!/bin/bash
# Chunked-KV legs (run by neg/CKV/with-server.sh, which sets PORT, CHILD_PID,
# RUN_DIR and PY). review/CHUNKED-KV-2026-10-23.md.
# usage: neg/CKV/leg.sh grow|release|cap|prefix
cd "$(dirname "$0")/../.."
T=$PWD/pkg/qwen38-27b/tokenizer
RL=/tmp/sealed-reason.log
req() { "$PY" neg/CKV/req.py $PORT "$T" $CHILD_PID "$@" 2>> "$RUN_DIR/client.err"; }
lines() { [ -f $RL ] && wc -l < $RL | tr -d ' ' || echo 0; }
notes() {  # notes <label> <from> <to>: chunk notes written between two line counts
  local s
  s=$(sed -n "$(($2 + 1)),$3p" $RL 2>/dev/null | grep '^test: ckv')
  echo "NOTES $1 alloc=$(echo "$s" | grep -c 'ckv alloc') release=$(echo "$s" | grep -c 'ckv release') last=[$(echo "$s" | tail -1)] alloc_us=[$(echo "$s" | grep 'ckv alloc' | sed -E 's/.* us=([0-9.]+) .*/\1/' | paste -sd, -)] release_us=[$(echo "$s" | grep 'ckv release' | sed -E 's/.* us=([0-9.]+) .*/\1/' | paste -sd, -)]"
}
case $1 in
grow)
  # Within one chunk, across one boundary (prompt), across one boundary
  # (generation). Answers and their digests are compared with the dense
  # child in the driver.
  a=$(lines); req kestrel 300; b=$(lines); notes kestrel-300 $a $b
  req kestrel 700; c=$(lines); notes kestrel-700 $b $c
  req decode grow-fixed 700; d=$(lines); notes decode-700 $c $d
  ;;
release)
  a=$(lines); req kestrel 32000; b=$(lines); notes kestrel-32000 $a $b
  req decode release-after 64; c=$(lines); notes after-small $b $c
  ;;
cap)
  req kestrel 12000
  req kestrel 20000
  req decode cap-alive 64
  ;;
prefix)
  req prefix 6000 sysA user1
  req prefix 6000 sysA user2
  req prefix 6000 sysB user3
  ;;
*) echo "unknown leg $1"; exit 2 ;;
esac
grep -E ' Done · ' "$RUN_DIR/server.log" | sed 's/^/DONE /'
