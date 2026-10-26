#!/bin/bash
# Starts SealedEngineV2.app through LaunchServices (open), with a clean
# environment (the engine refuses unknown variables), against the staged
# Splash child and the model package. Waits for "listening" or a failure.
# Usage: scripts/start-engine.sh [port]   (log: build/engine.log, stderr: build/engine.err)
# SEALED_KV_BUDGET_BYTES in the caller's environment passes through (unset = child default 16 GiB).
cd "$(dirname "$0")/.."
M=$HOME/projects/sealed-backends-spike/sealed-m5
PORT=${1:-29452}
KVENV=()
[ -n "${SEALED_KV_BUDGET_BYTES:-}" ] && KVENV=(--env "SEALED_KV_BUDGET_BYTES=$SEALED_KV_BUDGET_BYTES")
pkill -f "SealedEngineV2.app/Contents/MacOS/SealedEngine" 2>/dev/null
for i in $(seq 1 30); do pgrep -f "SealedEngineV2.app/Contents/MacOS/SealedEngine" > /dev/null || break; sleep 1; done
: > build/engine.log; : > build/engine.err
env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin TMPDIR="$TMPDIR" /usr/bin/open -n -a "$PWD/build/SealedEngineV2.app" \
  --stdout "$PWD/build/engine.err" --stderr "$PWD/build/engine.err" \
  --env SEALED_ENGINE_PORT=$PORT --env SEALED_PACKAGE="$M/pkg/qwen38-27b" --env SEALED_CHILD_DIR="$M/child" \
  --env SEALED_DECOY="$M/tools/decoy" --env SEALED_MAX_CONTEXT=32768 --env SEALED_ENGINE_LOG="$PWD/build/engine.log" "${KVENV[@]}"
for i in $(seq 1 80); do
  grep -q "listening" build/engine.log && { grep listening build/engine.log | cut -c1-200; exit 0; }
  grep -qE "failed|refus" build/engine.log build/engine.err && break
  sleep 3
done
echo "engine did not start:"; tail -5 build/engine.log build/engine.err
exit 1
