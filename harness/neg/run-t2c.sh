#!/bin/bash
# T2 client-need check (2026-10-23): can the sealed child run Metal without
# IOSurfaceRootUserClient, so the profile can deny that class outright?
# See review/T2-CLIENT-NEED-2026-10-23.md.
#
# Legs:
#   screen  neg/T2C/client-probe under the R5 profile shape (deny, allow,
#           no sandbox) with neg/T2C/open-trace.dylib: each Metal call Splash
#           uses, and the caller stack of every IOServiceOpen of IOSurfaceRoot
#   load    v1 (legacy queue + MTLEvent), v2 (no placement-sparse probe) and
#           v2b (dense KV, no MTL4 queue, no shared event) under the class
#           deny, with the kernel log of every open attempt
#   chat    one chat request through the engine per build, plus the
#           production child (control) and v2b under the production profile
#   reader  v2b with the T2F surface probe: global and non-global make after
#           "sandboxed" and after the load; neg/T2/t2-reader reads while the
#           child holds
# Writes neg/t2c-<date>.txt. No sudo. Run neg/build-all.sh first.
cd "$(dirname "$0")/.."
PKG=$PWD/pkg/qwen38-27b
O=neg/t2c-$(date +%F).txt
RUN=$PWD/neg/T2C/run
export BENCH_OK=1
mkdir -p "$RUN"
: > $O
echo "# build: $(date '+%F %T') host=$(sysctl -n hw.model) $(sw_vers -buildVersion) uid=$(id -u)" >> $O

# 1. Screen.
S=$RUN/screen
rm -rf "$S"; mkdir -p "$S"
for m in allow deny nosb; do
  DYLD_INSERT_LIBRARIES=$PWD/neg/T2C/open-trace.dylib neg/T2C/client-probe $m > "$S/$m.txt" 2>&1
  echo "rc=$?" >> "$S/$m.txt"
  grep -E '^(step|trace open|rc=)' "$S/$m.txt" | grep -v '^step sandbox' | paste -sd ' ' - | sed "s/^/## screen $m: /" >> $O
done
grep -A12 '^trace open IOSurfaceRoot' "$S/deny.txt" | grep '^trace  ' | sed 's/^trace  */## screen deny stack: /' >> $O

# 2. Loads under the test spawner.
for v in v1-legacy v2-noprobe v2b-dense; do
  neg/T2C/load-arm.sh build-t2c-$v load-$v > /dev/null
  D=$RUN/load-$v
  echo "## load $v: spawner: $(cat "$D/r2neg.txt")" >> $O
  grep -E '^(test: t2c|bootstrap error)' "$D/child.reason" | grep -v 'dense buffer' | sed "s/^/## load $v: reason: /" >> $O
  echo "## load $v: dense buffers: $(grep -c 'dense buffer.*ok=1' "$D/child.reason")" >> $O
  grep -E 'deny\(1\) iokit-open-user-client IOSurfaceRootUserClient|IOUC IOSurfaceRootUserClient' "$D/kernel.log" \
    | sed "s/^/## load $v: kernel: /" >> $O
done

# 3. Chats through the engine.
C=$RUN/chat.txt; : > $C
for v in v1-legacy v2-noprobe v2b-dense v2b-dense-allow; do
  neg/T2C/chat-log.sh build-t2c-$v $v >> $C
  K=$RUN/chat-$v/kernel.log
  echo "## chat $v kernel: attempts=$(grep -c 'IOUC IOSurfaceRootUserClient failed MACF' "$K") $(grep -m1 'deny(1) iokit-open-user-client IOSurfaceRootUserClient' "$K")" >> $O
done
neg/T2C/chat-log.sh build control >> $C
sed 's/^/## /' $C >> $O

# 4. Reader against v2b with the T2F probe (both phases).
D=$RUN/reader; rm -rf "$D"; mkdir -p "$D"
E=$D/splash; cp splash/build-t2c-v2b-dense-t2f/splash "$E"
printf 'r5 owndir probe\n' > "$D/r5-owndir-probe"
codesign -f -s - --options runtime -i sealed.splash "$E" 2>/dev/null
/usr/bin/log stream --style compact --predicate 'eventMessage CONTAINS "IOSurfaceRootUserClient"' > "$D/kernel.log" 2>&1 &
LP=$!; sleep 2
rm -f /tmp/sealed-reason.log
R2NEG_POLL_MS=600000 neg/B/r2neg "$E" "$PKG" control > "$D/r2neg.txt" 2>&1 &
RP=$!
for ph in sandboxed loaded; do
  line=""; t=0
  while [ $t -lt 240 ]; do
    line=$(grep -m1 "^test: t2f $ph hold=" /tmp/sealed-reason.log 2>/dev/null)
    [ -n "$line" ] && break
    kill -0 $RP 2>/dev/null || break
    sleep 1; t=$((t + 1))
  done
  if [ -n "$line" ]; then
    gl=$(echo "$line" | sed -E 's/.* global=([0-9]+) .*/\1/')
    ng=$(echo "$line" | sed -E 's/.* nonglobal=([0-9]+) .*/\1/')
    can=$(echo "$line" | sed -E 's/.* canary=([0-9a-f]{64}).*/\1/')
    max=$(( (gl > ng ? gl : ng) + 4096 ))
    { echo "HOLD $line"; neg/T2/t2-reader "$can" "$max" "$gl" "$ng"; } > "$D/$ph.reader" 2>&1
  else
    echo "NOHOLD (no $ph hold line)" > "$D/$ph.reader"
  fi
done
wait $RP
sleep 2; kill $LP 2>/dev/null; wait $LP 2>/dev/null
cp /tmp/sealed-reason.log "$D/child.reason" 2>/dev/null
echo "## reader: spawner: $(tail -1 "$D/r2neg.txt")" >> $O
grep -E '^test: t2f ' "$D/child.reason" | sed 's/^/## reader: reason: /' >> $O
for ph in sandboxed loaded; do sed "s/^/## reader $ph: /" "$D/$ph.reader" >> $O; done
echo "## reader: kernel attempts=$(grep -c 'IOUC IOSurfaceRootUserClient failed MACF' "$D/kernel.log")" >> $O

# Validity checks (INVALID if one fails) and the verdict.
fails=0; v() { [ "$1" = FAIL ] && fails=$((fails + 1)); echo "$1 $2" >> $O; }
m() { echo "MEAS $1" >> $O; }
ctl=$(grep -m1 '^PASS chat\[t2c-control\]' $C)
if [ -n "$ctl" ]; then v PASS "[valid-control-chat] $ctl"; else v FAIL "[valid-control-chat] $(grep -m1 'chat\[t2c-control\]' $C)"; fi
sa=$(grep -m1 '^## screen allow:' $O)
case "$sa" in *"step mtl4queue 1"*"step sharedevent 1"*"step mtl4map 1"*) v PASS "[valid-screen-allow] MTL4 queue, shared event and a sparse map work with the class allowed" ;;
  *) v FAIL "[valid-screen-allow] $sa" ;; esac
sd=$(grep -m1 '^## screen deny:' $O)
case "$sd" in *"IOSurfaceRoot type=0 rc=0xe00002e2"*) v PASS "[valid-screen-deny] the class deny refused the open (0xe00002e2)" ;;
  *) v FAIL "[valid-screen-deny] $sd" ;; esac
if grep -q 'deny(1) iokit-open-user-client IOSurfaceRootUserClient' "$RUN/load-v2b-dense/kernel.log"; then
  v PASS "[valid-kernel-log] the kernel log recorded the class deny for the test child"
else v FAIL "[valid-kernel-log] no deny line for the test child"; fi

# Measurements.
m "[screen-deny] $(echo "$sd" | sed 's/## screen deny: //')"
d=$(grep -m1 '^PASS chat\[t2c-v2b-dense\]' $C)
m "[v2b-chat] ${d:-$(grep -m1 'chat\[t2c-v2b-dense\]' $C)}"
m "[v2b-load] $(cat "$RUN/load-v2b-dense/r2neg.txt")"
okopen=$(grep -hE 'create=ok|mtl4Queue=1|sharedEvent=1' "$D/child.reason" 2>/dev/null | head -2 | paste -sd ';' -)
hit=$(grep -hE 'FOUND|with_canary=[1-9]|prop=hit' "$D"/*.reader 2>/dev/null | head -2 | paste -sd ';' -)
m "[v2b-client-use] ${okopen:-no surface make, MTL4 queue or shared event succeeded in the class-deny child}"
m "[v2b-reader] ${hit:-the reader found no surface and no canary in either phase}"
for x in v1-legacy v2-noprobe; do m "[$x] $(grep -m1 'bootstrap error' "$RUN/load-$x/child.reason")"; done

if [ $fails -gt 0 ]; then echo "VERDICT INVALID ($fails checks failed)" >> $O
elif [ -n "$d" ] && [ -z "$okopen" ] && [ -z "$hit" ] && grep -q 'SANDBOXED then LOADED' "$RUN/load-v2b-dense/r2neg.txt"; then
  echo "VERDICT CLOSED (v2b: the child starts, loads and serves a chat with IOSurfaceRootUserClient denied; its only open attempt is refused)" >> $O
elif [ -n "$d" ]; then
  echo "VERDICT UNCHANGED (v2b serves a chat, but the child still used the client: ${okopen}${hit})" >> $O
else
  echo "VERDICT NOT POSSIBLE (no variant served a chat with the class denied)" >> $O
fi
cat $O
