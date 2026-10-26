#!/bin/bash
# Interleaved A/B speed bench (review/CHUNKED-KV-2026-10-23.md): the dense
# child (before) and the chunked child (after), same prompts (fixed nonces),
# twice each, MAX_CONTEXT 65529. GPU utilization is sampled before each run.
# usage: neg/CKV/bench-ab.sh <dense-binary> <chunked-binary>
cd "$(dirname "$0")/../.."
O=neg/CKV/run/bench-ab.txt
: > $O
gpu() { ioreg -r -d 1 -w 0 -c IOAccelerator | grep -o '"Device Utilization %"=[0-9]*' | head -1; }
for round in 1 2; do
  for pair in "dense|$1" "ckv|$2"; do
    L=${pair%%|*}; B=${pair#*|}
    echo "# round=$round build=$L gpu_before=[$(gpu)] other_gpu_jobs=[$(pgrep -fl 'mlx-serve|llama-server|lms ' | cut -c1-80 | paste -sd';' -)] $(date '+%T')" >> $O
    neg/CKV/with-server.sh "$B" "ab-$L-$round" 65529 neg/CKV/bench-body.sh bench fixed >> $O 2>&1
    grep -E ' Done · ' neg/CKV/run/ab-$L-$round/server.log | sed "s/^/DONE $L $round /" >> $O
  done
done
echo "# end $(date '+%T')" >> $O
