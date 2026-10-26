#!/bin/bash
# R8 end-to-end check on a running sandboxed test copy:
#   self-test lines in the log, /attest 200, verified chat "Paris", refusal
#   controls, a /probe assertion, a second chat, the engine sandboxed as seen
#   from outside, no listener but 127.0.0.1:<port>, and every sandbox denial
#   report of the engine pid during the run.
# Usage: scripts/r8-check.sh <app dir> <port>     (writes <app dir>/r8-check.txt)
cd "$(dirname "$0")/.."
D=$(cd "$1" && pwd -P); PORT=$2
APPID=${SEALED_APPID:-$(scripts/app-id.sh "$D/SealedEngineV2.app" 2>/dev/null || true)}
[ -n "$APPID" ] || { echo "cannot read the app ID from build/SealedEngineV2.app; set SEALED_APPID"; exit 1; }
W=$(python3 scripts/model-hash.py "$HOME/projects/sealed-backends-spike/sealed-m5/pkg/qwen38-27b" \
      "$(cat "$HOME/projects/sealed-backends-spike/sealed-m5/child/pin.txt")" | awk '/^model/{print $2}')
E=$(codesign -dvvv "$D/SealedEngineV2.app" 2>&1 | awk -F= '/^CandidateCDHashFull sha256/{print $2}')
PID=$(pgrep -f "^$D/SealedEngineV2.app/Contents/MacOS/SealedEngine" | head -1)
O=$D/r8-check.txt; : > "$O"; fails=0
say() { echo "$*" | tee -a "$O"; }
v() { [ "$1" = FAIL ] && fails=$((fails + 1)); say "$1 [$2] $3"; }
say "# R8 check $(date '+%F %T') pid=$PID port=$PORT engine CD hash $E model $W"
[ -n "$PID" ] || { v FAIL engine "not running"; exit 1; }
log stream --style compact --predicate "eventMessage CONTAINS \"SealedEngine($PID)\"" > "$D/r8-check.sandbox.log" 2>&1 &
LP=$!
sleep 2
n=$(grep -c "denied$" "$D/engine.log"); c=$(grep -c "^sealed-r8 control .* ok$" "$D/engine.log")
grep -q "selftest done: all denials held" "$D/engine.log" && v PASS self-test "$n arms denied in the sandbox, $c controls reached their target before it; child-pidinfo and child-signal0 allowed" || v FAIL self-test "no 'all denials held' line"
sb=$(python3 -c "import ctypes;l=ctypes.CDLL('/usr/lib/libSystem.B.dylib');print(l.sandbox_check($PID,None,0))")
[ "$sb" = 1 ] && v PASS sandboxed "sandbox_check($PID) = 1 from outside" || v FAIL sandboxed "sandbox_check = $sb"
L=$(lsof -nP -a -p "$PID" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | sort -u | tr '\n' ' ')
[ "$L" = "127.0.0.1:$PORT " ] && v PASS listeners "only $L" || v FAIL listeners "listeners: $L"
a=$(curl -s -m 10 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/attest")
[ "$a" = 200 ] && v PASS attest "GET /attest 200" || v FAIL attest "GET /attest $a"
OUT=$(/tmp/sealed-chat --engine "http://127.0.0.1:$PORT" --app-id $APPID --cdhash "$E" --weights "$W" 2>&1); echo "$OUT" >> "$O"
echo "$OUT" | grep -q '^REPLY.*"Paris"' && echo "$OUT" | grep -q "matches the pinned hash" && v PASS verified-chat "$(echo "$OUT" | grep ^REPLY)" || v FAIL verified-chat "$(echo "$OUT" | tail -1)"
x=$(/tmp/sealed-chat --engine "http://127.0.0.1:$PORT" --app-id $APPID --cdhash "$(printf '%064d' 1)" --weights "$W" 2>&1 | grep ^FAIL)
echo "$x" | grep -q "code identity" && v PASS refuse-wrong-cdhash "$x" || v FAIL refuse-wrong-cdhash "${x:-no refusal}"
x=$(/tmp/sealed-chat --engine "http://127.0.0.1:$PORT" --app-id $APPID --cdhash "$E" --weights "$(printf '%064d' 0)" 2>&1 | grep ^FAIL)
echo "$x" | grep -q "session binding" && v PASS refuse-wrong-model "$x" || v FAIL refuse-wrong-model "${x:-no refusal}"
p=$(curl -s -m 10 -w " %{http_code}" -H 'Content-Type: application/json' \
      -d "{\"challenge\":\"$(head -c 32 /dev/urandom | base64)\"}" "http://127.0.0.1:$PORT/probe")
echo "$p" | grep -q '"assertion".* 200$' && v PASS probe "POST /probe 200 with an assertion" || v FAIL probe "${p: -80}"
OUT=$(/tmp/sealed-chat --engine "http://127.0.0.1:$PORT" --app-id $APPID --cdhash "$E" --weights "$W" \
      --prompt "What is 2+3? Answer with one digit." --max-tokens 16 2>&1); echo "$OUT" >> "$O"
echo "$OUT" | grep -q '^REPLY.*5' && v PASS second-chat "$(echo "$OUT" | grep ^REPLY)" || v FAIL second-chat "$(echo "$OUT" | tail -1)"
sleep 3
kill $LP
say "# sandbox denial reports of pid $PID during the run (count, operation):"
grep -o "Sandbox: SealedEngine($PID) deny.*" "$D/r8-check.sandbox.log" | sed -E 's/Sandbox: SealedEngine\([0-9]+\) //' | sort | uniq -c | tee -a "$O"
pgrep -f "^$D/SealedEngineV2.app" > /dev/null && v PASS still-running "engine pid $PID still serves after the run" || v FAIL still-running "engine exited"
say "# result: $fails failed"
exit $fails
