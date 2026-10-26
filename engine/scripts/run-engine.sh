#!/bin/bash
# Starts SealedEngineV2.app against the staged Splash child and the model
# package, with a clean environment (the engine refuses unknown variables).
# Usage: scripts/run-engine.sh [port]     (log: build/engine.log)
cd "$(dirname "$0")/.."
M=$HOME/projects/sealed-backends-spike/sealed-m5
PORT=${1:-29452}
: > build/engine.log
exec env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin TMPDIR="$TMPDIR" \
  SEALED_ENGINE_PORT=$PORT SEALED_PACKAGE="$M/pkg/qwen38-27b" SEALED_CHILD_DIR="$M/child" \
  SEALED_DECOY="$M/tools/decoy" SEALED_MAX_CONTEXT=32768 SEALED_ENGINE_LOG="$PWD/build/engine.log" \
  "$PWD/build/SealedEngineV2.app/Contents/MacOS/SealedEngine"
