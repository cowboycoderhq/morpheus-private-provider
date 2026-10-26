#!/bin/bash
# Dense-KV production check (2026-10-23): the production backend has dense KV
# and no MTL4 queue or MTLSharedEvent, and the R5 profile has no
# IOSurfaceRootUserClient rule. See review/DENSE-KV-2026-10-23.md.
#
# Legs:
#   load    the reason-file child (production code) under neg/B/r2neg, with
#           the kernel log of every IOSurfaceRootUserClient open attempt
#   chat    one chat request through the engine (server.py, sealed-launch)
#           with the production child splash/build, pinned by its own CD hash
#   reader  build-dkv-t2f (production profile and backend plus the T2F
#           surface probe): global and non-global make after "sandboxed" and
#           after the load; neg/T2/t2-reader reads while the child holds
#   long    the production child with max context 32768 and with the pool
#           maximum; long prompts, answer check and physical footprint
# Writes neg/dkv-<date>.txt. No sudo. Run neg/build-all.sh first.
cd "$(dirname "$0")/.."
PKG=$PWD/pkg/qwen38-27b
O=neg/dkv-$(date +%F).txt
RUN=$PWD/neg/DKV/run
export BENCH_OK=1
mkdir -p "$RUN"
: > $O
echo "# build: $(date '+%F %T') host=$(sysctl -n hw.model) $(sw_vers -buildVersion) uid=$(id -u)" >> $O
echo "# production child: splash/build/splash cdhash=$(codesign -dvvv splash/build/splash 2>&1 | awk -F= '/^CDHash=/{print $2}') sha256=$(shasum -a 256 splash/build/splash | cut -c1-64)" >> $O
P=splash/build/splash
echo "# production strings: SEALED_TEST=$(strings -a $P | grep -c SEALED_TEST) test:=$(strings -a $P | grep -c 'test: ') newMTL4CommandQueue=$(strings -a $P | grep -c newMTL4CommandQueue) newSharedEvent=$(strings -a $P | grep -c newSharedEvent) updateBufferMappings=$(strings -a $P | grep -c updateBufferMappings) IOSurfaceRootUserClient=$(strings -a $P | grep -c IOSurfaceRootUserClient)" >> $O

# 1. Load with the kernel log.
neg/T2C/load-arm.sh build-reason dkv-load > /dev/null
D=$PWD/neg/T2C/run/dkv-load
echo "## load: spawner: $(cat "$D/r2neg.txt")" >> $O
grep -E '^sealed-r5 selftest iosurface-open|^bootstrap error' "$D/child.reason" | sed 's/^/## load: reason: /' >> $O
grep -E 'deny\(1\) iokit-open-user-client IOSurfaceRootUserClient|IOUC IOSurfaceRootUserClient' "$D/kernel.log" \
  | sed 's/^/## load: kernel: /' >> $O

# 2. Chat through the engine with the production child.
C=$(neg/T2C/chat-log.sh build dkv-prod)
K=$PWD/neg/T2C/run/chat-dkv-prod/kernel.log
echo "## chat: $C" >> $O
echo "## chat kernel: attempts=$(grep -c 'IOUC IOSurfaceRootUserClient failed MACF' "$K") $(grep -m1 'deny(1) iokit-open-user-client IOSurfaceRootUserClient' "$K")" >> $O

# 3. Reader against build-dkv-t2f (both phases).
D=$RUN/reader; rm -rf "$D"; mkdir -p "$D"
E=$D/splash; cp splash/build-dkv-t2f/splash "$E"
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
grep -E '^test: t2f |^sealed-r5 selftest iosurface-open' "$D/child.reason" | sed 's/^/## reader: reason: /' >> $O
for ph in sandboxed loaded; do sed "s/^/## reader $ph: /" "$D/$ph.reader" >> $O; done
echo "## reader: kernel attempts=$(grep -c 'IOUC IOSurfaceRootUserClient failed MACF' "$D/kernel.log")" >> $O

# 4. Long context and memory. LONG_POOL_CTX is the pool maximum (the plan's
#    KV tokens minus the speculative scratch).
neg/DKV/long-arm.sh build long-32k 32768 16000 32000 > "$RUN/long-32k.txt" 2>&1
sed 's/^/## /' "$RUN/long-32k.txt" >> $O
if [ -n "$LONG_POOL_CTX" ]; then
  neg/DKV/long-arm.sh build long-pool "$LONG_POOL_CTX" "${LONG_POOL_TARGET:-64000}" > "$RUN/long-pool.txt" 2>&1
  sed 's/^/## /' "$RUN/long-pool.txt" >> $O
fi

# Checks and the verdict.
fails=0; v() { [ "$1" = FAIL ] && fails=$((fails + 1)); echo "$1 $2" >> $O; }
grep -q '^## load: spawner: .*exit=-9 SANDBOXED then LOADED' $O && v PASS "[load] the production-code child loads" || v FAIL "[load] $(grep -m1 '^## load: spawner' $O)"
grep -q '^## load: reason: sealed-r5 selftest iosurface-open rc=0xe00002e2' $O && v PASS "[selftest] the probe open was refused (0xe00002e2)" || v FAIL "[selftest] no refused probe open"
grep -q '^## load: kernel: .*deny(1) iokit-open-user-client IOSurfaceRootUserClient' $O && v PASS "[kernel] the kernel log recorded the class deny" || v FAIL "[kernel] no deny line in the kernel log"
echo "$C" | grep -q '^PASS chat\[t2c-dkv-prod\].*answer=Paris' && v PASS "[chat] $C" || v FAIL "[chat] $C"
r=$(grep -E '^## reader: reason: test: t2f (sandboxed|loaded) surface global create=' $O)
if [ "$(echo "$r" | grep -c 'global create=NULL')" = 2 ] && ! grep -q 'create=ok' "$D/child.reason"; then
  v PASS "[reader-make] global and non-global surface make returned NULL in both phases"
else v FAIL "[reader-make] $(echo "$r" | paste -sd ';' -)"; fi
hit=$(grep -hE 'FOUND|with_canary=[1-9]|prop=hit' "$D"/*.reader 2>/dev/null | head -2 | paste -sd ';' -)
nohold=$(grep -l NOHOLD "$D"/*.reader 2>/dev/null)
if [ -z "$hit" ] && [ -z "$nohold" ]; then v PASS "[reader] the external reader found no surface and no canary in either phase"
else v FAIL "[reader] ${hit}${nohold}"; fi
for f in "$RUN"/long-*.txt; do
  grep -E '^(PASS|FAIL) long' "$f" | while read -r l; do echo "MEAS [$(basename "$f" .txt)] $l" >> $O; done
done
if [ "$(grep -c '^PASS long' "$RUN/long-32k.txt")" = 2 ]; then v PASS "[long-32k] both long requests at max context 32768 answered correctly"
else v FAIL "[long-32k] $(grep -E '^(FAIL|#)' "$RUN/long-32k.txt" | paste -sd ';' -)"; fi
echo "# result: $fails failed" >> $O
cat $O
[ $fails = 0 ]
