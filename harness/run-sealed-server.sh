#!/bin/bash
# Splash server on 127.0.0.1:8199 whose native engine is the SEALED Splash child,
# spawned by sealed-launch (staged spawn module, A-13 canary in strict mode).
cd "$(dirname "$0")"
export SEALED_CHILD=$PWD/child/splash SEALED_PIN=$(cat $PWD/child/pin.txt) SEALED_REQ=$PWD/child/req-splash.bin
export SEALED_DECOY=$PWD/tools/decoy SEALED_DECOY_PIN=3a86a25828fdfac91f5d00b3f217bbae66320000 SEALED_LOG=$PWD/launch.log
export PYTHONUNBUFFERED=1 TRANSFORMERS_VERBOSITY=error PYTHONDONTWRITEBYTECODE=1
exec "/opt/homebrew/opt/splash/libexec/python/bin/python3" -u "/opt/homebrew/opt/splash/libexec/server/server.py" "$HOME/projects/sealed-backends-spike/sealed-m5/pkg/qwen38-27b/target" "$HOME/projects/sealed-backends-spike/sealed-m5/pkg/qwen38-27b/draft" \
  --tokenizer "$HOME/projects/sealed-backends-spike/sealed-m5/pkg/qwen38-27b/tokenizer" --model audreyt/Qwen3.8-27B-Splash-abliterated \
  --binary "$PWD/launcher/sealed-launch" --host 127.0.0.1 --port 8199 \
  --max-memory auto --max-context 32768 --no-webui
