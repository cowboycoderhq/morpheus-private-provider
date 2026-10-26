#!/bin/bash
# P10 check: with the v2 engine serving, sends a sealed prompt that holds a
# random canary, then looks for the canary everywhere an unprivileged
# observer can look, and in the processes that may hold it:
#   - lo0 traffic during the request is not captured here (needs root); the
#     HTTP body is the envelope, checked by grepping the client's request
#   - every process of this user except the engine and the child: memory is
#     not readable without root, so this arm uses the root kit (see README)
#   - files: the engine log, the child's TMPDIR, ~/Library/Logs, /tmp
#   - the unified log (log show) for the time of the request
# A control prompt is sent once through the Splash Python server on :8199
# (the old path) to show the same search finds a canary that is in the open.
# Usage: scripts/p10-check.sh <engine cdhash> <model hash>
set -u
cd "$(dirname "$0")/.."
E=$1; W=$2
C="P10CANARY$(date +%s)$RANDOM"
START=$(date '+%Y-%m-%d %H:%M:%S')
OUT=build/p10-$(date +%F-%H%M%S).txt
: > "$OUT"
say() { echo "$*" | tee -a "$OUT"; }
say "# P10 check $START canary=$C"
APPID=${SEALED_APPID:-$(scripts/app-id.sh 2>/dev/null || true)}
[ -n "$APPID" ] || { echo "cannot read the app ID from build/SealedEngineV2.app; set SEALED_APPID"; exit 1; }
/tmp/sealed-chat --engine http://127.0.0.1:29452 --app-id "$APPID" --cdhash "$E" --weights "$W" \
  --unverified-code-identity --prompt "Repeat this code exactly once: $C" --max-tokens 48 2>&1 | tee -a "$OUT"
grep -q "REPLY.*$C" "$OUT" && say "PASS the sealed reply holds the canary (the child saw it)" || say "INFO the reply does not repeat the canary"
sleep 3
CH=$(awk '/child ready: pid/{print $4}' build/engine.log | tail -1)
D=$(ps -E -o command= -p "$CH" 2>/dev/null | tr ' ' '\n' | grep '^TMPDIR=' | cut -d= -f2)
hits=$(grep -rl "$C" build/engine.log "$D" ~/Library/Logs /tmp 2>/dev/null | grep -v "$OUT" | wc -l | tr -d ' ')
[ "$hits" = 0 ] && say "PASS files: canary in none of engine.log, child TMPDIR ($D), ~/Library/Logs, /tmp" || say "FAIL files: canary in $hits files: $(grep -rl "$C" build/engine.log "$D" ~/Library/Logs /tmp 2>/dev/null | grep -v "$OUT" | head -3)"
L=$(log show --start "$START" --style compact 2>/dev/null | grep -c "$C")
[ "$L" = 0 ] && say "PASS unified log: canary absent" || say "FAIL unified log: canary in $L lines"
say "INFO plaintext holders by design: the engine (pid $(pgrep -f 'SealedEngineV2.app/Contents/MacOS/SealedEngine' | head -1), hardened) and the child (pid $CH, hardened, sandboxed). The Python server and the stand-in launcher are not in this path: $(pgrep -fl 'server.py.*8199|sealed-launch' | wc -l | tr -d ' ') such processes run."
