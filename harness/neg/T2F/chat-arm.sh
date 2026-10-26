#!/bin/bash
# T2 follow-up (2026-10-22): one chat request through the engine with a test
# child (a build folder under splash/). Same server and launcher as
# run-sealed-server.sh; only the child, its pin and its requirement change.
# The requirement names the test child's own CD hash, so child/ is not touched.
# usage: neg/T2F/chat-arm.sh <build-folder> <tag>   (prints one PASS/FAIL line)
cd "$(dirname "$0")/../.."
B=$1; TAG=${2:-$1}
[ -n "$B" ] || { echo "usage: chat-arm.sh <build-folder> <tag>"; exit 2; }
D=$PWD/neg/T2F/run/$TAG
rm -rf "$D"; mkdir -p "$D"
BIN=$D/splash
cp "splash/$B/splash" "$BIN" || { echo "FAIL chat[$TAG]: no build splash/$B/splash"; exit 1; }
# The R5 self-test reads this file beside the child (run-all.sh plants it too).
printf 'r5 owndir probe\n' > "$D/r5-owndir-probe"
codesign -f -s - --options runtime -i sealed.splash "$BIN" 2>/dev/null
PIN=$(codesign -d -r- "$BIN" 2>&1 | sed -nE 's/.*cdhash H"([0-9a-f]{40})".*/\1/p' | head -1)
REQ=$D/req.bin
# Same generator and blob form as stage-child.sh, so the child's status words
# match the pinned 0x22011311 of this pair.
tools/reqgen "$BIN" "$PIN" dummy "$REQ" >/dev/null 2>&1
[ -s "$REQ" ] || { echo "FAIL chat[$TAG]: reqgen did not write $REQ"; exit 1; }
export SEALED_CHILD=$BIN SEALED_PIN=$PIN SEALED_REQ=$REQ
export SEALED_DECOY=$PWD/tools/decoy SEALED_DECOY_PIN=3a86a25828fdfac91f5d00b3f217bbae66320000
export SEALED_LOG=$D/launch.log
export PYTHONUNBUFFERED=1 TRANSFORMERS_VERBOSITY=error PYTHONDONTWRITEBYTECODE=1
rm -f /tmp/sealed-reason.log
"/opt/homebrew/opt/splash/libexec/python/bin/python3" -u "/opt/homebrew/opt/splash/libexec/server/server.py" \
  "$PWD/pkg/qwen38-27b/target" "$PWD/pkg/qwen38-27b/draft" \
  --tokenizer "$PWD/pkg/qwen38-27b/tokenizer" --model audreyt/Qwen3.8-27B-Splash-abliterated \
  --binary "$PWD/launcher/sealed-launch" --host 127.0.0.1 --port 8199 \
  --max-memory auto --max-context 32768 --no-webui > "$D/server.log" 2>&1 &
SP=$!
# The reason path is shared with the negative suite (/tmp/sealed-reason.log),
# so snapshot it early: another run on this Mac may reset it at any time.
: > "$D/child.reason.first"
c=000
for i in $(seq 1 40); do
  c=$(curl -s -m 3 -o /dev/null -w "%{http_code}" http://127.0.0.1:8199/v1/models)
  [ -s "$D/child.reason.first" ] || { [ -s /tmp/sealed-reason.log ] && cp /tmp/sealed-reason.log "$D/child.reason.first" 2>/dev/null; }
  [ "$c" = 200 ] && break
  kill -0 $SP 2>/dev/null || break
  sleep 3
done
ANS=""
if [ "$c" = 200 ]; then
  ANS=$(curl -s -m 150 http://127.0.0.1:8199/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"model":"audreyt/Qwen3.8-27B-Splash-abliterated","messages":[{"role":"user","content":"Name the capital of France in one word."}],"max_tokens":64,"temperature":0}' \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["choices"][0]["message"]["content"].strip())
except Exception as e: print("ERR", e)')
fi
kill -TERM $SP 2>/dev/null
for i in $(seq 1 30); do pgrep -f "sealed-m5/child/splash|sealed-launch|$TAG/splash" >/dev/null || break; sleep 1; done
LEFT=$(pgrep -f "sealed-launch|$TAG/splash" | wc -l | tr -d ' ')
cp /tmp/sealed-reason.log "$D/child.reason" 2>/dev/null
if [ "$c" = 200 ] && echo "$ANS" | grep -qi paris; then
  echo "PASS chat[$TAG] build=$B pin=$PIN answer=$ANS left=$LEFT"
else
  echo "FAIL chat[$TAG] build=$B pin=$PIN http=$c answer=${ANS:-none} left=$LEFT"
  tail -3 "$D/launch.log" 2>/dev/null | sed 's/^/  launch: /'
  tail -3 "$D/server.log" 2>/dev/null | sed 's/^/  server: /'
  grep -E "sealed-r5|sealed-r6|error" "$D/child.reason" 2>/dev/null | head -3 | sed 's/^/  child: /'
  grep -E "sealed-r5: sandbox_init|sealed-r5 reported|test: t2f" "$D/child.reason.first" 2>/dev/null | head -3 | sed 's/^/  child(first): /'
fi
