#!/bin/bash
# P9/P10 evidence run for SealedEngineV2 on this Mac (no root):
#  1. child reproducibility: two folders, same bytes, same CD hash = the pin
#  2. engine reproducibility: a second checkout's unsigned rebuild matches the
#     signed app (sealed-verify rebuild)
#  3. start the engine (LaunchServices); verified chat: App Attest chain, app
#     ID, engine CD hash, session bound to the model hash; reply "Paris"
#  4. refusal controls: wrong CD hash, wrong model hash, wrong app ID
#  5. P10 canary: the canary prompt is answered, and is absent from the
#     engine log, the child TMPDIR, ~/Library/Logs, /private/tmp and the unified log
#  6. padded replies (1, 2, 4 frames), a >1024-byte grapheme, frame v2 at
#     512 MiB, the fixed 503 body and log line, serving after a refusal,
#     and the budget range refusal at start (output stored in this file)
# Writes build/evidence-<stamp>.txt with PASS/FAIL lines.
# Usage: scripts/evidence.sh <provisioning profile>
set -u
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
. "$HOME/projects/sealed-backends-spike/sealed-m5/tools/suite-lock.sh" && suite_lock evidence.sh
PROFILE=$1
M=$HOME/projects/sealed-backends-spike/sealed-m5
APPID=${SEALED_APPID:-$(scripts/app-id.sh 2>/dev/null || true)}
[ -n "$APPID" ] || { echo "cannot read the app ID from build/SealedEngineV2.app; set SEALED_APPID"; exit 1; }
O=build/evidence-$(date +%F-%H%M%S).txt
fails=0
: > "$O"
say() { echo "$*" | tee -a "$O"; }
v() { [ "$1" = FAIL ] && fails=$((fails + 1)); say "$1 [$2] $3"; }
say "# SealedEngineV2 evidence $(date '+%F %T') host=$(sysctl -n hw.model) $(sw_vers -buildVersion) $(xcodebuild -version 2>&1 | tr '\n' ' ') swift=$(swift --version 2>&1 | head -1) metal=$(xcrun -sdk macosx metal --version 2>&1 | head -1)"

# 1. child
R=$(scripts/child-repro-check.sh "$M/splash" 2>&1 | tail -6)
echo "$R" | sed 's/^/    /' >> "$O"
pin=$(cat "$M/child/pin.txt")
hl=$(echo "$R" | grep "^HOME a=")
ha=$(echo "$hl" | sed -n 's/^HOME a=\([^ ]*\) b=.*/\1/p'); hb=$(echo "$hl" | sed -n 's/^HOME a=[^ ]* b=\(.*\)$/\1/p')
echo "$R" | grep -q "SAME" && echo "$R" | grep -q "a=$pin b=$pin" && [ -n "$ha" ] && [ -n "$hb" ] && [ "$ha" != "$hb" ] && v PASS child-reproducible "two folders, HOME $ha and $hb, give the same bytes and CD hash $pin (= the pin compiled into the engine)" \
  || v FAIL child-reproducible "$(echo "$R" | tr '\n' ' ')"
grep -q "\"$pin\"" Sources/SealedEngineV2/ChildPin.swift && v PASS child-pin-in-engine "ChildPin.swift names $pin" || v FAIL child-pin-in-engine "ChildPin.swift does not name $pin"

# 2. engine
rm -rf /tmp/sev2-third && mkdir -p /tmp/sev2-third/checkout && rsync -a --exclude .build --exclude build --exclude Spikes ./ /tmp/sev2-third/checkout/
(cd /tmp/sev2-third/checkout && MODE=verify scripts/bundle.sh "$PROFILE" > /dev/null 2>&1)
(cd ../proxy-router && BENCH_OK=1 go build -o /tmp/sealed-verify ./cmd/sealed-verify && BENCH_OK=1 go build -o /tmp/sealed-chat ./cmd/sealed-chat)
C=$(/tmp/sealed-verify rebuild --published build/SealedEngineV2.app --rebuild /tmp/sev2-third/checkout/build/verify/SealedEngineV2.app --app-id $APPID 2>&1)
echo "$C" >> "$O"
E=$(echo "$C" | sed -n 's/.*App Attest will report CD hash \([0-9a-f]*\).*/\1/p')
echo "$C" | grep -q "^MATCH" && v PASS engine-reproducible "a second checkout's rebuild matches the signed app; App Attest CD hash $E" || v FAIL engine-reproducible "no match"

# 3. engine start and verified chat
W=$(python3 scripts/model-hash.py "$M/pkg/qwen38-27b" "$pin" | awk '/^model/{print $2}')
scripts/start-engine.sh > /dev/null || { v FAIL engine-start "$(tail -3 build/engine.log build/engine.err | tr '\n' ' ')"; }
grep -q "model=$W" build/engine.log && v PASS model-hash "engine reports model hash $W, equal to the hash computed from the package files and the pin by scripts/model-hash.py" \
  || v FAIL model-hash "engine: $(grep -o 'model=[0-9a-f]*' build/engine.log); computed $W"
if grep -q "boot posture: sip=0x0 bootargs=empty swap=encrypted hibernate=[03] kexts=apple-only ap=1 cert=1 sep=1" build/engine.log && grep -q "selftest posture-runtime rc=0 allowed" build/engine.log; then
  v PASS boot-posture "$(grep -m1 '^boot posture:' build/engine.log)"
else
  v FAIL boot-posture "missing boot posture or sandbox posture-runtime line in build/engine.log"
fi
PC=/tmp/sev2-posture-check
if clang -std=c17 -Wall -Wextra -I Sources/SealedSpawnC/include -framework CoreFoundation -framework IOKit \
     Sources/SealedSpawnC/sealed_posture.c scripts/posture-check.c -o "$PC" 2>&1 \
   && PO=$("$PC" 2>&1) && echo "$PO" | grep -q "^# posture-check: 0 failed$"; then
  echo "$PO" | sed 's/^/    /' >> "$O"
  v PASS boot-posture-unit "13 posture arms (live host + 12 refusal/allow mutations), 0 failed"
else
  v FAIL boot-posture-unit "${PO:-compile failed}"
fi
rm -f "$PC"
OUT=$(/tmp/sealed-chat --engine http://127.0.0.1:29452 --app-id $APPID --cdhash "$E" --weights "$W" 2>&1); echo "$OUT" >> "$O"
echo "$OUT" | grep -q '^REPLY.*"Paris"' && echo "$OUT" | grep -q "matches the pinned hash" && v PASS verified-chat "$(echo "$OUT" | grep ^REPLY)" || v FAIL verified-chat "$(echo "$OUT" | tail -1)"

# 4. refusals
x=$(/tmp/sealed-chat --engine http://127.0.0.1:29452 --app-id $APPID --cdhash "$(printf '%064d' 1)" --weights "$W" 2>&1 | grep ^FAIL)
echo "$x" | grep -q "code identity" && v PASS refuse-wrong-cdhash "$x" || v FAIL refuse-wrong-cdhash "${x:-no refusal}"
x=$(/tmp/sealed-chat --engine http://127.0.0.1:29452 --app-id $APPID --cdhash "$E" --weights "$(printf '%064d' 0)" 2>&1 | grep ^FAIL)
echo "$x" | grep -q "session binding" && v PASS refuse-wrong-model "$x" || v FAIL refuse-wrong-model "${x:-no refusal}"
x=$(/tmp/sealed-chat --engine http://127.0.0.1:29452 --app-id "${APPID%.*}.other" --cdhash "$E" --weights "$W" 2>&1 | grep ^FAIL)
echo "$x" | grep -q "app id" && v PASS refuse-wrong-appid "$x" || v FAIL refuse-wrong-appid "${x:-no refusal}"
x=$(/tmp/sealed-chat --engine http://127.0.0.1:29452 --app-id $APPID --cdhash "$E" --weights "$W" --min-os 99.0 2>&1 | grep ^FAIL)
echo "$x" | grep -q "older than the required minimum" && v PASS refuse-old-macos "$x" || v FAIL refuse-old-macos "${x:-no refusal}"

# 5. P10 canary (non-root part)
CAN="P10CANARY$(date +%s)$RANDOM"; START=$(date '+%Y-%m-%d %H:%M:%S')
OUT=$(/tmp/sealed-chat --engine http://127.0.0.1:29452 --app-id $APPID --cdhash "$E" --weights "$W" --prompt "Repeat this code exactly once: $CAN" --max-tokens 48 2>&1); echo "$OUT" >> "$O"
echo "$OUT" | grep -q "REPLY.*$CAN" && v PASS p10-canary-served "the child answered the sealed canary prompt" || v FAIL p10-canary-served "$(echo "$OUT" | tail -1)"
sleep 3
CH=$(awk '/child ready: pid/{print $4}' build/engine.log | tail -1)
D=$(ps -E -o command= -p "$CH" 2>/dev/null | tr ' ' '\n' | grep '^TMPDIR=' | cut -d= -f2)
# /tmp is a symlink, and grep -r does not follow a symlinked start path
# (audit A4-03). The search names /private/tmp directly, skips files over
# 64 MiB and stays on this volume, and a control canary written there first
# must be found, or the check is void.
tmpsearch() { find /private/tmp -xdev -type f -size -65536k -print0 2>/dev/null | xargs -0 grep -l "$1" 2>/dev/null | wc -l | tr -d ' '; }
CTL="$(mktemp -d /private/tmp/p10ctl.XXXX)"; echo "P10CTL$CAN" > "$CTL/ctl"
nctl=$(tmpsearch "P10CTL$CAN")
rm -rf "$CTL"
n=$(grep -rl "$CAN" build/engine.log build/engine.err "$D" ~/Library/Logs 2>/dev/null | wc -l | tr -d ' ')
n=$((n + $(tmpsearch "$CAN")))
if [ "$nctl" -lt 1 ]; then v FAIL p10-no-file-copy "control canary in /private/tmp not found: the /tmp search is void"
elif [ "$n" = 0 ]; then v PASS p10-no-file-copy "canary in none of engine.log, engine stderr, child TMPDIR, ~/Library/Logs, /private/tmp (control found $nctl)"
else v FAIL p10-no-file-copy "$n files hold it"; fi
n=$(log show --start "$START" --style compact 2>/dev/null | grep -c "$CAN")
[ "$n" = 0 ] && v PASS p10-no-log-copy "canary absent from the unified log" || v FAIL p10-no-log-copy "$n log lines"
n=$(pgrep -fl 'server.py.*8199|sealed-launch' | wc -l | tr -d ' ')
[ "$n" = 0 ] && v PASS p10-no-python-hop "no Splash Python server or stand-in launcher runs; plaintext exists only in the engine and the child" || v FAIL p10-no-python-hop "$n such processes"
# 6. engine refusal, frame v2 and padded replies (audit R3-E-01: these ran
#    only in session output before; each log is copied into this file before
#    the next start, because start-engine.sh empties the logs).
CH() { /tmp/sealed-chat --engine http://127.0.0.1:29452 --app-id $APPID --cdhash "$E" --weights "$W" "$@" 2>&1; }
keeplog() { say "--- $1: engine.log"; sed 's/^/    /' build/engine.log >> "$O"; say "--- $1: engine.err (last 5)"; tail -5 build/engine.err | sed 's/^/    /' >> "$O"; }
frames() { echo "$1" | sed -n 's/^FRAMES ciphertext bytes: //p'; }

# 6a. padded replies of 1, 2 and 4 frames on the default engine
for spec in "1:Name the capital of France in one word.:16" \
            "2:Write the numbers from 1 to 700 separated by single spaces, nothing else.:2000" \
            "4:Write the numbers from 1 to 1400 separated by single spaces, nothing else.:3000"; do
  want=${spec%%:*}; rest=${spec#*:}; prompt=${rest%:*}; mt=${rest##*:}
  OUT=$(CH --max-tokens "$mt" --prompt "$prompt"); echo "$OUT" | grep -E "^(FRAMES|REPLY)" | cut -c1-160 >> "$O"
  f=$(frames "$OUT"); n=$(echo "$f" | tr ',' '\n' | grep -c .); bad=$(echo "$f" | tr ',' '\n' | grep -vc '^1043$')
  rb=$(echo "$OUT" | sed -n 's/^REPLY.*: "\(.*\)"$/\1/p' | wc -c | tr -d ' ')
  if [ "$n" = "$want" ] && [ "$bad" = 0 ]; then v PASS padded-reply-$want "$n frames, every frame 1043 bytes (reply about $rb bytes)"
  else v FAIL padded-reply-$want "want $want frames of 1043 bytes, got [$f]"; fi
done

# 6b. a reply with one grapheme of more than 1024 bytes (audit R2-E-03,
#     R4-E-02): the reply bytes come from --reply-file, and the longest
#     grapheme cluster must exceed one frame body (1024 bytes).
BIG="a$(python3 -c 'print("\u0301"*700, end="")')"
RF=$(mktemp /tmp/sev2-reply.XXXX)
OUT=$(CH --max-tokens 1500 --reply-file "$RF" --prompt "Repeat this exactly once and nothing else: $BIG"); echo "$OUT" | grep -E "^(FRAMES|FAIL)" >> "$O"
f=$(frames "$OUT"); bad=$(echo "$f" | tr ',' '\n' | grep -vc '^1043$')
G=$(python3 - "$RF" <<'PYG'
import sys,unicodedata
t=open(sys.argv[1],"rb").read().decode("utf-8")
best=cur=0
for ch in t:
    n=len(ch.encode())
    if unicodedata.combining(ch): cur+=n
    else: best=max(best,cur); cur=n
print(len(t.encode()), max(best,cur))
PYG
)
rm -f "$RF"; rb=${G% *}; gb=${G#* }
say "    reply bytes $rb, longest grapheme cluster $gb bytes"
if echo "$OUT" | grep -q '^REPLY' && [ -n "$f" ] && [ "$bad" = 0 ] && [ "${gb:-0}" -gt 1024 ]; then v PASS big-grapheme "reply of $rb bytes holds one grapheme cluster of $gb bytes (> 1024); sealed in [$f] frames of 1043 bytes; no 500"
else v FAIL big-grapheme "frames [$f], reply bytes ${rb:-?}, longest cluster ${gb:-?} (needs > 1024); $(echo "$OUT" | tail -1 | cut -c1-80)"; fi

# 6c. frame v2 budget and the fixed refusal (needs a restart with a budget)
# 700 lines = 19,759 tokens: over the 512 MiB budget (15,872 tokens), under the
# engine context limit (32,768), so the CHILD refuses it, not the engine.
LONG=$(python3 - <<'PYP'
print("Remember the code word 7319-KESTREL. " + "\n".join(f"Log line {i:05d}: sensor {i % 97} in bay {i % 13} reported status at {(i*7)%24:02d}:{(i*11)%60:02d}." for i in range(700)) + "\nWhat is the code word? Then name the capital of France.")
PYP
)
# Control (audit R4-E-03): the same prompt on the default budget is served,
# so a 503 below comes from the 512 MiB budget and not from the prompt.
OUT=$(CH --max-tokens 32 --prompt "$LONG"); echo "$OUT" | grep -E "^(FAIL|REPLY)" | cut -c1-120 >> "$O"
if echo "$OUT" | grep -q '^REPLY.*7319-KESTREL'; then v PASS refusal-503-control "the long prompt on the default budget is served (reply names the code word)"
else v FAIL refusal-503-control "$(echo "$OUT" | tail -1 | cut -c1-120)"; fi
SEALED_KV_BUDGET_BYTES=536870912 scripts/start-engine.sh > /dev/null
if grep -q "kv budget: 536870912 bytes" build/engine.log; then v PASS frame-v2-budget "engine log: kv budget: 536870912 bytes"
else v FAIL frame-v2-budget "no kv budget line"; fi
OUT=$(CH --max-tokens 32 --prompt "$LONG"); echo "$OUT" | grep -E "^(FAIL|REPLY)" | cut -c1-120 >> "$O"
if echo "$OUT" | grep -q 'status 503: map\[error:refused\]$'; then v PASS refusal-503-body "long prompt over the 512 MiB budget: 503 with the fixed body {\"error\":\"refused\"}"
else v FAIL refusal-503-body "$(echo "$OUT" | tail -1 | cut -c1-120)"; fi
rl=$(grep -c '^.*request refused$' build/engine.log); rn=$(grep 'request refused' build/engine.log | grep -c '[0-9]')
if [ "$rl" -ge 1 ] && [ "$rn" = 0 ]; then v PASS refusal-log-line "engine log holds 'request refused' $rl time(s), with no number"
else v FAIL refusal-log-line "refusal lines=$rl, lines with a digit=$rn"; fi
OUT=$(CH --max-tokens 16 --prompt "Name the capital of France in one word."); echo "$OUT" | grep -E "^REPLY" >> "$O"
echo "$OUT" | grep -q '^REPLY.*Paris' && v PASS serve-after-refusal "short chat after the refusal answered Paris" || v FAIL serve-after-refusal "$(echo "$OUT" | tail -1 | cut -c1-120)"
keeplog budget-run

# 6d. budget range refusal at start
for bad in 1 1099511627777; do
  SEALED_KV_BUDGET_BYTES=$bad scripts/start-engine.sh > /dev/null 2>&1
  keeplog budget-range-$bad
  if grep -q "refusing to start: SEALED_KV_BUDGET_BYTES" build/engine.err build/engine.log 2>/dev/null && ! pgrep -f "SealedEngineV2.app/Contents/MacOS/SealedEngine" > /dev/null; then
    v PASS budget-range-$bad "engine refused to start with SEALED_KV_BUDGET_BYTES=$bad"
  else v FAIL budget-range-$bad "engine did not refuse $bad"; fi
done

# Leave the default engine running for the next steps.
scripts/start-engine.sh > /dev/null

say "# result: $fails failed"
exit $fails
