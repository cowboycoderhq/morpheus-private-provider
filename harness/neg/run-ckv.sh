#!/bin/bash
# Chunked-KV check (2026-10-23, review/CHUNKED-KV-2026-10-23.md). The
# production backend allocates the KV cache as private 512-token chunk
# buffers on demand and releases them when a request ends. Legs, each with
# its control:
#   grow     prompts inside one chunk and across one boundary, and a
#            generation across one boundary; answers and digests must equal
#            the dense child's (control) on the same prompts
#   release  a 31,940-token prompt: footprint before, peak and 4 s after;
#            the dense child (control) keeps its pool
#   cap      a 512 MiB budget (31 chunks): 11,934 tokens answer, 19,941
#            tokens get 503 with the reason, the child still answers
#   prefix   one system prompt twice, then a different one (control); the
#            dense child is the second control
#   long     15,932 / 31,940 / 63,935-token prompts (neg/DKV/long-arm.sh),
#            and 119,9xx tokens with MAX_CONTEXT 131072 (above the dense pool)
# Writes neg/ckv-<date>.txt. No sudo. Run neg/build-all.sh first.
# usage: neg/run-ckv.sh <dense-binary>
cd "$(dirname "$0")/.."
if [ $# -ne 1 ]; then
  echo "usage: neg/run-ckv.sh <dense-binary>" >&2
  exit 2
fi
DENSE=$1
O=neg/ckv-$(date +%F).txt
RUN=$PWD/neg/CKV/run
export BENCH_OK=1
mkdir -p "$RUN"
: > $O
echo "# build: $(date '+%F %T') host=$(sysctl -n hw.model) $(sw_vers -buildVersion) uid=$(id -u)" >> $O
for b in splash/build/splash splash/build-ckv-notes/splash "$DENSE"; do
  echo "# binary: $b sha256=$(shasum -a 256 "$b" | cut -c1-64)" >> $O
done
gpu() { ioreg -r -d 1 -w 0 -c IOAccelerator | grep -o '"Device Utilization %"=[0-9]*' | head -1; }
leg() {  # leg <binary> <tag> <max-context> <leg>
  echo "## [$2] gpu_before=[$(gpu)] $(date '+%T')" >> $O
  rm -f /tmp/sealed-reason.log
  neg/CKV/with-server.sh "$1" "$2" "$3" neg/CKV/leg.sh "$4" > "$RUN/$2.txt" 2>&1
  sed "s/^/## [$2] /" "$RUN/$2.txt" >> $O
}
leg splash/build-ckv-notes/splash ckv-grow 32768 grow
leg "$DENSE" dense-grow 32768 grow
leg splash/build-ckv-notes/splash ckv-release 32768 release
leg "$DENSE" dense-release 32768 release
SEALED_KV_BUDGET_BYTES=536870912 leg splash/build/splash ckv-cap 32768 cap
grep -h 'kv budget' "$RUN/ckv-cap/launch.log" | sed 's/^/## [ckv-cap] launch: /' >> $O
leg splash/build/splash ckv-prefix 32768 prefix
leg "$DENSE" dense-prefix 32768 prefix
echo "## [long] gpu_before=[$(gpu)] $(date '+%T')" >> $O
neg/DKV/long-arm.sh build ckv-long-32k 32768 16000 32000 > "$RUN/ckv-long-32k.txt" 2>&1
neg/DKV/long-arm.sh build ckv-long-64k 65529 64000 > "$RUN/ckv-long-64k.txt" 2>&1
neg/DKV/long-arm.sh build ckv-long-128k 131072 120000 > "$RUN/ckv-long-128k.txt" 2>&1
for t in 32k 64k 128k; do sed "s/^/## [long-$t] /" "$RUN/ckv-long-$t.txt" >> $O; done

# Checks and the verdict.
fails=0; v() { [ "$1" = FAIL ] && fails=$((fails + 1)); echo "$1 $2" >> $O; }
res() { grep -E "^## \[$1\] RESULT" $O | sed -n "${2}p"; }
field() { echo "$1" | sed -nE "s/.* $2=([^ ]+).*/\1/p"; }
mem() { grep -E "^## \[$1\] MEM" $O | sed -n "${2}p"; }
g=0
for i in 1 2 3; do
  c=$(res ckv-grow $i); d=$(res dense-grow $i)
  if echo "$c" | grep -q 'RESULT PASS' && [ -n "$(field "$c" answer_sha)" ] && [ "$(field "$c" answer_sha)" = "$(field "$d" answer_sha)" ]; then g=$((g + 1)); fi
done
a=$(grep -E '^## \[ckv-grow\] NOTES kestrel-700' $O)
if [ $g = 3 ]; then v PASS "[grow] 3 of 3 answers correct and equal to the dense child (digests); kestrel-700 chunk notes: ${a#*NOTES }"
else v FAIL "[grow] $g of 3 equal; $(grep -E '^## \[(ckv|dense)-grow\] RESULT' $O | sed -E 's/.*(mode=[a-z]+ args=[^ ]+).*(answer_sha=[0-9a-f]+).*/\1 \2/' | paste -sd';' -)"; fi
gib() { awk -v b="$1" 'BEGIN { printf "%.3f", b / 2^30 }'; }
cm=$(mem ckv-release 1); dm=$(mem dense-release 1)
cp=$(field "$cm" peak); cs=$(field "$cm" settled); cb=$(field "$cm" before)
dp=$(field "$dm" peak); ds=$(field "$dm" settled)
cr=$(grep -E '^## \[ckv-release\] NOTES kestrel-32000' $O | sed -nE 's/.*resident_after=([0-9]+).*/\1/p')
echo "MEAS [release] chunked: before=$(gib $cb) peak=$(gib $cp) settled=$(gib $cs) GiB, released=$(gib $((cp - cs))) GiB, KV resident after=$cr bytes; dense: peak=$(gib $dp) settled=$(gib $ds) GiB, released=$(gib $((dp - ds))) GiB" >> $O
if res ckv-release 1 | grep -q 'RESULT PASS' && [ $((cp - cs)) -gt 536870912 ] && [ -n "$cr" ] && [ "$cr" -le 289669120 ] && [ $((dp - ds)) -lt 268435456 ]; then
  v PASS "[release] the chunked child returned $(gib $((cp - cs))) GiB after the request (KV resident $cr bytes = prefix window + runway); the dense control returned $(gib $((dp - ds))) GiB"
else v FAIL "[release] chunked released $((cp - cs)) bytes, KV after=$cr; dense released $((dp - ds))"; fi
c1=$(res ckv-cap 1); c2=$(res ckv-cap 2); c3=$(res ckv-cap 3)
if echo "$c1" | grep -q 'RESULT PASS.*http=200' && echo "$c2" | grep -q 'http=503.*KV budget exceeded' && echo "$c3" | grep -q 'RESULT PASS.*http=200'; then
  v PASS "[cap] 11,934 tokens answered; 19,941 tokens got 503: $(echo "$c2" | sed -E 's/.*"message":"([^"]+)".*/\1/'); the child answered after it"
else v FAIL "[cap] $(echo "$c1 ;; $c2 ;; $c3" | cut -c1-600)"; fi
p1=$(grep -E '^## \[ckv-prefix\] DONE' $O | sed -n 1p); p2=$(grep -E '^## \[ckv-prefix\] DONE' $O | sed -n 2p); p3=$(grep -E '^## \[ckv-prefix\] DONE' $O | sed -n 3p)
t() { echo "$1" | sed -nE 's/.*TTFT ([0-9.]+)s.*/\1/p'; }
k() { echo "$1" | sed -nE 's/.*cached ([0-9,]+) .*/\1/p' | tr -d ,; }
ok3=$(grep -cE '^## \[ckv-prefix\] RESULT PASS' $O)
if [ "$ok3" = 3 ] && [ "$(k "$p2")" -ge 4096 ] && [ "$(k "$p3")" = 0 ] && awk -v a="$(t "$p1")" -v b="$(t "$p2")" 'BEGIN { exit !(b < 0.7 * a) }'; then
  v PASS "[prefix] same system prompt: cached $(k "$p2") tokens, TTFT $(t "$p2") s vs $(t "$p1") s; other system prompt: cached $(k "$p3"), TTFT $(t "$p3") s; 3 of 3 correct"
else v FAIL "[prefix] correct=$ok3 | $p1 | $p2 | $p3"; fi
q2=$(grep -E '^## \[dense-prefix\] DONE' $O | sed -n 2p)
echo "MEAS [prefix-dense-control] second request on the dense child: cached $(k "$q2"), TTFT $(t "$q2") s" >> $O
for f in "$RUN"/ckv-long-*.txt; do
  grep -E '^(PASS|FAIL) long|^MEM' "$f" | while read -r l; do echo "MEAS [$(basename "$f" .txt)] $l" >> $O; done
done
n=$(cat "$RUN"/ckv-long-*.txt | grep -c "^PASS long.*answer='7319-KESTREL, Paris'")
if [ "$n" = 4 ]; then v PASS "[long] 4 of 4 long prompts answered 7319-KESTREL, Paris (15,932 / 31,940 / 63,935 and the 131072 limit)"
else v FAIL "[long] $n of 4: $(grep -hE '^(FAIL|#)' "$RUN"/ckv-long-*.txt | paste -sd';' -)"; fi
echo "# result: $fails failed" >> $O
cat $O
[ $fails = 0 ]
