#!/bin/bash
# Dense-KV long-context check (2026-10-23, review/DENSE-KV-2026-10-23.md):
# the server and launcher of neg/T2F/chat-arm.sh with a test child pinned by
# its own CD hash, then one long request per target size (neg/DKV/long-req.py)
# with the child's physical footprint sampled. child/ is not touched.
# usage: neg/DKV/long-arm.sh <build-folder> <tag> <max-context> <target tokens>...
cd "$(dirname "$0")/../.."
B=$1; TAG=$2; CTX=$3; shift 3
D=$PWD/neg/DKV/run/$TAG
rm -rf "$D"; mkdir -p "$D"
BIN=$D/splash
cp "splash/$B/splash" "$BIN" || { echo "FAIL long[$TAG]: no build splash/$B/splash"; exit 1; }
printf 'r5 owndir probe\n' > "$D/r5-owndir-probe"
codesign -f -s - --options runtime -i sealed.splash "$BIN" 2>/dev/null
PIN=$(codesign -d -r- "$BIN" 2>&1 | sed -nE 's/.*cdhash H"([0-9a-f]{40})".*/\1/p' | head -1)
REQ=$D/req.bin
tools/reqgen "$BIN" "$PIN" dummy "$REQ" >/dev/null 2>&1
[ -s "$REQ" ] || { echo "FAIL long[$TAG]: reqgen did not write $REQ"; exit 1; }
export SEALED_CHILD=$BIN SEALED_PIN=$PIN SEALED_REQ=$REQ
export SEALED_DECOY=$PWD/tools/decoy SEALED_DECOY_PIN=3a86a25828fdfac91f5d00b3f217bbae66320000
export SEALED_LOG=$D/launch.log
export PYTHONUNBUFFERED=1 TRANSFORMERS_VERBOSITY=error PYTHONDONTWRITEBYTECODE=1
PY=/opt/homebrew/opt/splash/libexec/python/bin/python3
PORT=8199
"$PY" -u /opt/homebrew/opt/splash/libexec/server/server.py \
  "$PWD/pkg/qwen38-27b/target" "$PWD/pkg/qwen38-27b/draft" \
  --tokenizer "$PWD/pkg/qwen38-27b/tokenizer" --model audreyt/Qwen3.8-27B-Splash-abliterated \
  --binary "$PWD/launcher/sealed-launch" --host 127.0.0.1 --port $PORT \
  --max-memory auto --max-context "$CTX" --no-webui > "$D/server.log" 2>&1 &
SP=$!
c=000
for i in $(seq 1 60); do
  c=$(curl -s -m 3 -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/v1/models)
  [ "$c" = 200 ] && break
  kill -0 $SP 2>/dev/null || break
  sleep 3
done
CP=$(pgrep -f "$BIN serve-native" | head -1)
echo "# long[$TAG] build=$B pin=$PIN max_context=$CTX http=$c child_pid=${CP:-none}"
if [ "$c" = 200 ] && [ -n "$CP" ]; then
  curl -s -m 10 http://127.0.0.1:$PORT/status > "$D/status-before.json"
  for T in "$@"; do
    "$PY" neg/DKV/long-req.py $PORT "$PWD/pkg/qwen38-27b/tokenizer" "$T" "$CP" 2>> "$D/client.err"
  done
  curl -s -m 10 http://127.0.0.1:$PORT/status > "$D/status-after.json"
else
  echo "FAIL long[$TAG] server not ready"
  tail -5 "$D/server.log" | sed 's/^/  server: /'
  tail -3 "$D/launch.log" 2>/dev/null | sed 's/^/  launch: /'
fi
kill -TERM $SP 2>/dev/null
for i in $(seq 1 30); do pgrep -f "sealed-launch|$BIN" >/dev/null || break; sleep 1; done
echo "# long[$TAG] left=$(pgrep -f "sealed-launch|$BIN" | wc -l | tr -d ' ')"
