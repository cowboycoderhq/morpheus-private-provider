#!/bin/bash
# Starts one R8 test copy of the engine through LaunchServices, next to any
# engine that already runs from build/ (no pkill by name: it would match that
# one too). Stops only an earlier copy started from the same APP_DIR.
# Usage: scripts/r8-start.sh <app dir> <port>
#   log: <app dir>/engine.log, stdout+stderr: <app dir>/engine.err
cd "$(dirname "$0")/.."
D=$(cd "$1" && pwd -P); PORT=$2
M=$HOME/projects/sealed-backends-spike/sealed-m5
EXE="$D/SealedEngineV2.app/Contents/MacOS/SealedEngine"
for p in $(pgrep -f "^$EXE"); do kill "$p"; done
for i in $(seq 1 30); do pgrep -f "^$EXE" > /dev/null || break; sleep 1; done
: > "$D/engine.log"; : > "$D/engine.err"
env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin TMPDIR="$TMPDIR" /usr/bin/open -n -a "$D/SealedEngineV2.app" \
  --stdout "$D/engine.err" --stderr "$D/engine.err" \
  --env SEALED_ENGINE_PORT=$PORT --env SEALED_PACKAGE="$M/pkg/qwen38-27b" --env SEALED_CHILD_DIR="$M/child" \
  --env SEALED_DECOY="$M/tools/decoy" --env SEALED_MAX_CONTEXT=32768 --env SEALED_ENGINE_LOG="$D/engine.log"
for i in $(seq 1 100); do
  grep -q "listening" "$D/engine.log" && { grep listening "$D/engine.log" | cut -c1-200; pgrep -f "^$EXE"; exit 0; }
  grep -qE "failed|refus" "$D/engine.log" "$D/engine.err" && break
  pgrep -f "^$EXE" > /dev/null || { [ "$i" -gt 3 ] && break; }
  sleep 3
done
echo "engine did not start:"; tail -5 "$D/engine.log" "$D/engine.err"
exit 1
