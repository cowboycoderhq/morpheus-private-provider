#!/bin/bash
# Regression check: start the sealed server on :8199, send one chat request,
# check the serving pid's CD hash against the pin, stop the server, check
# that nothing is left. Prints one PASS/FAIL line. Usage: ./smoke.sh <tag>
cd "$(dirname "$0")"
TAG=${1:-smoke}; LOG=logs/$TAG; mkdir -p logs
: > launch.log
./run-sealed-server.sh > $LOG.server.log 2>&1 &
SP=$!
c=000
for i in $(seq 1 60); do
  c=$(curl -s -m 3 -o /dev/null -w "%{http_code}" http://127.0.0.1:8199/v1/models)
  [ "$c" = 200 ] && break
  kill -0 $SP 2>/dev/null || break
  sleep 3
done
ANS=""; CDH=""
if [ "$c" = 200 ]; then
  ANS=$(curl -s -m 150 http://127.0.0.1:8199/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"model":"audreyt/Qwen3.8-27B-Splash-abliterated","messages":[{"role":"user","content":"Name the capital of France in one word."}],"max_tokens":64,"temperature":0}' \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["choices"][0]["message"]["content"].strip())
except Exception as e: print("ERR", e)')
  P=$(awk '/spawn rc=0/{print $3}' launch.log | tail -1 | cut -d= -f2)
  CDH=$(python3 - "$P" <<'PY'
import ctypes,sys
b=(ctypes.c_ubyte*20)(); rc=ctypes.CDLL(None).csops(int(sys.argv[1]),5,b,20)
print(bytes(b).hex() if rc==0 else "none")
PY
)
fi
kill -TERM $SP 2>/dev/null
for i in $(seq 1 30); do pgrep -f "sealed-m5/child/splash|sealed-launch" >/dev/null || break; sleep 1; done
LEFT=$(pgrep -f "sealed-m5/child/splash|sealed-launch|server.py.*8199" | wc -l | tr -d ' ')
cp launch.log $LOG.launch.log
PIN=$(cat child/pin.txt)
if [ "$c" = 200 ] && echo "$ANS" | grep -qi paris && [ "$CDH" = "$PIN" ] && [ "$LEFT" = 0 ]; then
  echo "PASS smoke[$TAG]: answer=$ANS cdhash=pin left=0"
else
  echo "FAIL smoke[$TAG]: http=$c answer=$ANS cdhash=$CDH pin=$PIN left=$LEFT"
  tail -5 $LOG.server.log | sed 's/^/  server: /'
  tail -5 $LOG.launch.log | sed 's/^/  launch: /'
fi
