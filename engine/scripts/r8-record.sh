#!/bin/bash
# R8 measurement: starts the record build (SEALED_R8_TEST_RECORD: the profile
# allows everything with a report), runs one /attest, one verified chat and a
# /probe, and writes the sandbox reports of that engine pid, deduplicated.
# Usage: scripts/r8-record.sh <app dir> <port> <engine CD hash (64 hex)> <model hash>
cd "$(dirname "$0")/.."
D=$1; PORT=$2; E=$3; W=$4
APPID=${SEALED_APPID:-$(scripts/app-id.sh "$D/SealedEngineV2.app" 2>/dev/null || true)}
[ -n "$APPID" ] || { echo "cannot read the app ID from build/SealedEngineV2.app; set SEALED_APPID"; exit 1; }
RAW="$D/sandbox-reports.raw"
log stream --style compact --predicate 'eventMessage CONTAINS "Sandbox: SealedEngine("' > "$RAW" 2>&1 &
LP=$!
sleep 2
scripts/r8-start.sh "$D" "$PORT" || { kill $LP; exit 1; }
PID=$(pgrep -f "^$(cd "$D" && pwd -P)/SealedEngineV2.app/Contents/MacOS/SealedEngine" | head -1)
curl -s -m 10 -o /dev/null -w "attest %{http_code}\n" "http://127.0.0.1:$PORT/attest"
/tmp/sealed-chat --engine "http://127.0.0.1:$PORT" --app-id $APPID --cdhash "$E" --weights "$W" 2>&1 | tail -3
sleep 3
kill $LP
grep "SealedEngine($PID)" "$RAW" | sed -E 's/.*Sandbox: SealedEngine\([0-9]+\) //' | sed -E 's/^[0-9]+ duplicate reports? for //' | sort | uniq -c | sort -rn > "$D/sandbox-reports.txt"
echo "pid $PID: $(wc -l < "$D/sandbox-reports.txt") distinct operations -> $D/sandbox-reports.txt"
