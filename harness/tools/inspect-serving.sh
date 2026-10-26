#!/bin/bash
# Starts the sealed server, sends one chat request, and records what the
# serving child looks like: raw answer, sandbox state, descriptors, file-backed
# regions outside the system volume and the executable, weight region
# protections, and the metal-cache entry count. Stops the server after.
# Usage: tools/inspect-serving.sh   (writes logs/inspect/inspect-<date>.txt)
cd "$(dirname "$0")/.."
mkdir -p logs/inspect
[ tools/regions -nt tools/regions.c ] || clang -O2 -o tools/regions tools/regions.c || exit 1
OUT=logs/inspect/inspect-$(date +%F).txt
: > launch.log
./run-sealed-server.sh > logs/inspect/server-$(date +%F).log 2>&1 &
SP=$!
for i in $(seq 1 60); do
  c=$(curl -s -m 3 -o /dev/null -w "%{http_code}" http://127.0.0.1:8199/v1/models)
  [ "$c" = 200 ] && break
  sleep 3
done
{
  date '+%F %T'
  curl -s -m 150 http://127.0.0.1:8199/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"model":"audreyt/Qwen3.8-27B-Splash-abliterated","messages":[{"role":"user","content":"Name the capital of France in one word."}],"max_tokens":64,"temperature":0}'
  echo
  P=$(awk '/spawn rc=0/{print $3}' launch.log | tail -1 | cut -d= -f2)
  echo "child pid=$P"
  echo "sandbox_check=$(python3 -c "import ctypes;print(ctypes.CDLL(None).sandbox_check($P,None,0))")"
  echo "rss_kb=$(ps -o rss= -p $P | tr -d ' ')"
  echo "--- launcher phase checks"
  grep -E "sandboxed:|loaded:|sandboxed report|manifest hash" launch.log
  echo "--- lsof"
  lsof -nP -p $P 2>/dev/null | awk 'NR>1 && $4!="txt"{print $4, $5, $9}'
  echo "--- file-backed regions (not system, not the executable)"
  tools/regions $P | sort -u | grep -vE "^/System/(Library|iOSSupport)/|^/usr/(lib|share)/|^/private/preboot/Cryptexes/|sealed-m5/child/splash "
  echo "--- weight regions"
  tools/regions --big $P
  vmmap $P > logs/inspect/vmmap-$(date +%F).txt 2>&1
  D=$(ps -E -o command= -p $P | tr ' ' '\n' | grep '^TMPDIR=' | cut -d= -f2)
  echo "--- metal-cache entries (TMPDIR=$D)"
  ls -A "$D/metal-cache" | wc -l | tr -d ' '
  ls -A "$D" "$D/metal-cache"
} > $OUT 2>&1
kill -TERM $SP; wait $SP 2>/dev/null; sleep 2
echo "left=$(pgrep -f 'sealed-m5/child/splash|sealed-launch' | wc -l | tr -d ' ')" >> $OUT
cat $OUT | cut -c1-240
