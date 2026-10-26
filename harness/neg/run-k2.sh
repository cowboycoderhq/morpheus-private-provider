#!/bin/bash
# K-2 freed-KV check (2026-10-23, review/K2-FREED-KV-2026-10-23.md). Legs:
#   control  k2-reader control: one process writes random bytes to private,
#            heap-placed and shared buffers, releases them without a clear,
#            then scans fresh ones with the same scan code
#   plant    an ordinary process writes random bytes to private buffers,
#            frees them and exits; a new reader process scans (measured)
#   child    the K-2 test child (scratch/k2-src/build-k2, production code
#            plus SEALED_TEST_K2_KVDUMP) answers a canary prompt through
#            server.py and sealed-launch; after its chunk releases the reader
#            scans fresh memory while the child runs
#   exit     the reader again after the child exits (measured)
# Writes neg/k2-<date>.txt. No sudo.
# usage: neg/run-k2.sh [PRIV_GIB SHARED_GIB CPU_GIB]
cd "$(dirname "$0")/.."
PG=${1:-10}; SG=${2:-1}; CG=${3:-2}
O=neg/k2-$(date +%F).txt
RUN=$PWD/neg/K2/run
TEST=scratch/k2-src/build-k2/splash
P=splash/build/splash
mkdir -p "$RUN"
: > $O
echo "# build: $(date '+%F %T') host=$(sysctl -n hw.model) $(sw_vers -buildVersion) uid=$(id -u)" >> $O
for b in $TEST $P neg/K2/k2-reader; do echo "# binary: $b sha256=$(shasum -a 256 $b | cut -c1-64)" >> $O; done
echo "# production strings: SEALED_TEST=$(strings -a $P | grep -c SEALED_TEST) test:=$(strings -a $P | grep -c 'test: ') k2=$(strings -a $P | grep -c 'test: k2')" >> $O
echo "# test child strings: k2=$(strings -a $TEST | grep -c 'test: k2')" >> $O
echo "# memory before: $(vm_stat | awk '/Pages free/ {f=$3} /Pages inactive/ {i=$3} END {printf "free=%.1fGiB inactive=%.1fGiB", f*16384/2^30, i*16384/2^30}')" >> $O

neg/K2/k2-reader control 1 > "$RUN/control.txt" 2>&1
sed 's/^/## [control] /' "$RUN/control.txt" >> $O

neg/K2/k2-reader plant "$RUN/plant.samples" 2 > "$RUN/plant.txt" 2>&1
neg/K2/k2-reader scan "$RUN/plant.samples" K2-PLANT-NO-TEXT "$PG" "$SG" "$CG" >> "$RUN/plant.txt" 2>&1
sed 's/^/## [plant] /' "$RUN/plant.txt" >> $O

CAN=K2CANARY-$(openssl rand -hex 8)
echo "# canary: $CAN" >> $O
rm -f /tmp/sealed-reason.log
neg/CKV/with-server.sh $TEST k2-child 32768 neg/K2/leg.sh "$CAN" 500 "$PG" "$SG" "$CG" > "$RUN/child.txt" 2>&1
sed 's/^/## [child] /' "$RUN/child.txt" >> $O
D=$PWD/neg/CKV/run/k2-child
cp /tmp/sealed-reason.log "$RUN/child.reason" 2>/dev/null
grep -E '^(spawn rc|sandboxed:|loaded:|child loaded)' "$D/launch.log" 2>/dev/null | sed 's/^/## [child] launch: /' >> $O
neg/K2/k2-reader scan "$D/child.samples" "$CAN" "$PG" "$SG" "$CG" > "$RUN/exit.txt" 2>&1
sed 's/^/## [exit] /' "$RUN/exit.txt" >> $O
echo "# memory after: $(vm_stat | awk '/Pages free/ {f=$3} /Pages inactive/ {i=$3} END {printf "free=%.1fGiB inactive=%.1fGiB", f*16384/2^30, i*16384/2^30}')" >> $O

# Checks and the verdict.
fails=0; voids=0
v() { case $1 in FAIL) fails=$((fails + 1)) ;; VOID) voids=$((voids + 1)) ;; esac; echo "$1 $2" >> $O; }
field() { echo "$1" | sed -nE "s/.* $2=([^ ]+).*/\1/p"; }
pct() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(b > 0 && a * 2 >= b) }'; }
cf=0
for t in control-private control-heap control-shared; do
  l=$(grep -E "^SCAN $t " "$RUN/control.txt")
  d=$(field "$l" distinct); n=$(echo "$l" | sed -nE 's/.* of ([0-9]+) .*/\1/p')
  pct "$d" "$n" && cf=1
  echo "MEAS [control] $t: found $d of $n samples, nonzero=$(field "$l" nonzero) bytes=$(field "$l" bytes)" >> $O
done
[ $cf = 1 ] && v PASS "[control] the same-process reader found at least 50 % of the helper's released, uncleared bytes in one variant" \
  || v VOID "[control] no variant found 50 % of its samples"
l=$(grep '^TOTAL' "$RUN/plant.txt")
echo "MEAS [plant] cross-process ordinary target: $(grep '^PLANT' "$RUN/plant.txt"); reader $l" >> $O
r=$(grep -E '^RESULT' "$RUN/child.txt")
if echo "$r" | grep -q 'RESULT PASS http=200' && grep -q '^sandboxed: .*cdhash matches the pin' "$D/launch.log" && grep -q '^loaded: .*cdhash matches the pin' "$D/launch.log"; then
  v PASS "[child] the test child answered the canary request: $(echo "$r" | cut -c1-260)"
else v VOID "[child] $(echo "$r" | cut -c1-300)"; fi
rel=$(grep -E '^REASON released_chunks' "$RUN/child.txt")
nr=$(field "$rel" released_chunks); ns=$(field "$rel" samples)
if [ "${nr:-0}" -ge 8 ] && [ "${ns:-0}" -ge 1000 ] && grep -q 'alive_before_reader=yes' "$RUN/child.txt"; then
  v PASS "[release] the child released $nr chunks with $ns samples before the reader started, and it still ran"
else v VOID "[release] $rel $(grep '^CHILD' "$RUN/child.txt" | paste -sd' ' -)"; fi
t=$(grep '^TOTAL' "$RUN/child.txt"); p=$(grep '^SCAN private' "$RUN/child.txt")
min=$((8 * 1073741824))
fp=$(grep '^FOOTPRINT' "$RUN/child.txt")
echo "MEAS [reader] $fp" >> $O
if [ -z "$t" ] || [ "$(field "$p" bytes)" -lt $min ]; then v VOID "[reader] the reader did not scan 8 GiB of private buffers: $p"
elif [ "$(field "$fp" private_growth)" -lt $(( $(field "$p" bytes) * 9 / 10 )) ]; then v VOID "[reader] the private buffers were not backed: $fp"
elif [ "$(field "$t" hits)" = 0 ] && [ "$(field "$t" canary)" = 0 ]; then
  v PASS "[reader] $t ($(grep '^SCAN' "$RUN/child.txt" | sed -E 's/^SCAN ([a-z]+) .* bytes=([0-9]+) nonzero=([0-9]+) .*/\1 bytes=\2 nonzero=\3/' | paste -sd';' -))"
else v FAIL "[reader] $t"; fi
echo "MEAS [exit] after the child exit: $(grep '^TOTAL' "$RUN/exit.txt")" >> $O
fz=$(grep '^test: k2 fresh' "$RUN/child.reason" | sed -E 's/.* nonzero=([0-9]+) .*/\1/' | sort -n | tail -1)
echo "MEAS [fresh] fresh chunks in the child: $(grep -c '^test: k2 fresh' "$RUN/child.reason"), largest nonzero count=${fz:-na}" >> $O
[ "$(strings -a $P | grep -c SEALED_TEST)" = 0 ] && v PASS "[hygiene] splash/build/splash holds 0 SEALED_TEST strings" || v FAIL "[hygiene] SEALED_TEST strings in the production child"
echo "# result: $fails failed, $voids void" >> $O
cat $O
[ $fails = 0 ] && [ $voids = 0 ]
