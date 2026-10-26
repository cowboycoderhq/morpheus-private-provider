#!/bin/bash
# Chunked-KV harness (2026-10-23, review/CHUNKED-KV-2026-10-23.md): the server
# and launcher of neg/DKV/long-arm.sh with a given child binary, pinned by its
# own CD hash, then one command with PORT, CHILD_PID and RUN_DIR set, then a
# clean stop. child/ is not touched. SEALED_KV_BUDGET_BYTES, when set, passes
# through to the launcher (config frame v2).
# usage: neg/CKV/with-server.sh <child-binary> <tag> <max-context> <command...>
cd "$(dirname "$0")/../.."
SRC=$1; TAG=$2; CTX=$3; shift 3
D=$PWD/neg/CKV/run/$TAG
rm -rf "$D"; mkdir -p "$D"
BIN=$D/splash
cp "$SRC" "$BIN" || { echo "FAIL serve[$TAG]: no binary $SRC"; exit 1; }
printf 'r5 owndir probe\n' > "$D/r5-owndir-probe"
codesign -f -s - --options runtime -i sealed.splash "$BIN" 2>/dev/null
PIN=$(codesign -d -r- "$BIN" 2>&1 | sed -nE 's/.*cdhash H"([0-9a-f]{40})".*/\1/p' | head -1)
REQ=$D/req.bin
tools/reqgen "$BIN" "$PIN" dummy "$REQ" >/dev/null 2>&1
[ -s "$REQ" ] || { echo "FAIL serve[$TAG]: reqgen did not write $REQ"; exit 1; }
export SEALED_CHILD=$BIN SEALED_PIN=$PIN SEALED_REQ=$REQ
export SEALED_DECOY=$PWD/tools/decoy SEALED_DECOY_PIN=3a86a25828fdfac91f5d00b3f217bbae66320000
export SEALED_LOG=$D/launch.log
export PYTHONUNBUFFERED=1 TRANSFORMERS_VERBOSITY=error PYTHONDONTWRITEBYTECODE=1
PY=/opt/homebrew/opt/splash/libexec/python/bin/python3
export PORT=${CKV_PORT:-8231}
if [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/v1/models)" != 000 ]; then
  echo "FAIL serve[$TAG]: port $PORT is already in use"; exit 1
fi
"$PY" -u /opt/homebrew/opt/splash/libexec/server/server.py \
  "$PWD/pkg/qwen38-27b/target" "$PWD/pkg/qwen38-27b/draft" \
  --tokenizer "$PWD/pkg/qwen38-27b/tokenizer" --model audreyt/Qwen3.8-27B-Splash-abliterated \
  --binary "$PWD/launcher/sealed-launch" --host 127.0.0.1 --port $PORT \
  --max-memory auto --max-context "$CTX" --no-webui > "$D/server.log" 2>&1 &
SP=$!
c=000
for i in $(seq 1 80); do
  c=$(curl -s -m 3 -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/v1/models)
  [ "$c" = 200 ] && break
  kill -0 $SP 2>/dev/null || break
  sleep 3
done
export CHILD_PID=$(pgrep -f "$BIN serve-native" | head -1) RUN_DIR=$D PY
echo "# serve[$TAG] binary=$SRC pin=$PIN max_context=$CTX budget=${SEALED_KV_BUDGET_BYTES:-default} http=$c child_pid=${CHILD_PID:-none}"
rc=1
if [ "$c" = 200 ] && [ -n "$CHILD_PID" ]; then
  "$@"; rc=$?
else
  echo "FAIL serve[$TAG] server not ready"
  tail -5 "$D/server.log" | sed 's/^/  server: /'
  tail -3 "$D/launch.log" 2>/dev/null | sed 's/^/  launch: /'
fi
kill -TERM $SP 2>/dev/null
for i in $(seq 1 30); do pgrep -f "sealed-launch|$BIN" >/dev/null || break; sleep 1; done
echo "# serve[$TAG] left=$(pgrep -f "sealed-launch|$BIN" | wc -l | tr -d ' ')"
exit $rc
