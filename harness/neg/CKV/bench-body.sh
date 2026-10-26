#!/bin/bash
# Chunked-KV speed bench body (run by neg/CKV/with-server.sh): decode speed on
# three short prompts and prefill speed at four lengths. Every prompt starts
# with a fresh nonce, so no request reuses a cached prefix.
# usage: neg/CKV/with-server.sh <child> <tag> 65529 neg/CKV/bench-body.sh <label>
cd "$(dirname "$0")/../.."
L=${1:-run}
T=$PWD/pkg/qwen38-27b/tokenizer
N=${2:-fixed}
for i in 1 2 3; do
  "$PY" neg/CKV/req.py $PORT "$T" $CHILD_PID decode "$L-d$i-$N" 512 2>> "$RUN_DIR/client.err"
done
for t in 8000 16000 32000 64000; do
  "$PY" neg/CKV/req.py $PORT "$T" $CHILD_PID filler $t "$L-p$t-$N" 8 2>> "$RUN_DIR/client.err"
done
