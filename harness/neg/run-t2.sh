#!/bin/bash
# T2 settling test (review/TRACKED-ITEMS-CLOSURE-2026-10-22.md, T2.4): can the
# sandboxed child publish an IOSurface that a same-user outside process reads?
# The test build makes a global and a non-global surface with a fresh canary
# after the "sandboxed" report and again after the load, and holds each pair
# 60 s. While it holds, neg/T2/t2-reader (same user, no sandbox) does a lookup
# of each recorded ID, an ID sweep, and a property read. The control is the
# same build without the sandbox. Writes neg/t2-<date>.txt and a verdict line.
# Usage: neg/run-t2.sh   (run neg/build-all.sh first; no sudo)
cd "$(dirname "$0")/.."
PKG=$PWD/pkg/qwen38-27b
O=neg/t2-$(date +%F).txt
RUN=$PWD/neg/run-t2
export BENCH_OK=1
: > $O
echo "# build: $(date '+%F %T') host=$(sysctl -n hw.model) $(sw_vers -buildVersion) uid=$(id -u)" >> $O
sign() { codesign -f -s - --options runtime -i sealed.splash "$1" 2>/dev/null; }
rm -rf "$RUN"; mkdir -p "$RUN"
printf 'r5 owndir probe\n' > "$RUN/r5-owndir-probe"   # the R5 self-test reads it next to the child

# arm <tag> <build folder>: runs the child through the test spawner and the
# reader once per phase, while the child holds its surfaces.
arm() {
  local tag=$1 b=$2 ph line gl ng can max t
  cp splash/$b/splash "$RUN/splash-$b" && sign "$RUN/splash-$b"
  rm -f /tmp/sealed-reason.log
  R2NEG_POLL_MS=600000 neg/B/r2neg "$RUN/splash-$b" "$PKG" control > "$RUN/$tag.r2" 2>&1 &
  local rp=$!
  for ph in sandboxed loaded; do
    line=""; t=0
    while [ $t -lt 900 ]; do
      line=$(grep -m1 "^test: t2 $ph hold=" /tmp/sealed-reason.log 2>/dev/null)
      [ -n "$line" ] && break
      kill -0 $rp 2>/dev/null || break
      sleep 1; t=$((t + 1))
    done
    if [ -z "$line" ]; then echo "NOHOLD phase=$ph" > "$RUN/$tag-$ph.reader"; continue; fi
    gl=$(echo "$line" | sed -E 's/.* global=([0-9]+) .*/\1/')
    ng=$(echo "$line" | sed -E 's/.* nonglobal=([0-9]+) .*/\1/')
    can=$(echo "$line" | sed -E 's/.* canary=([0-9a-f]{64}).*/\1/')
    max=$(( (gl > ng ? gl : ng) + 4096 ))
    { echo "HOLD $line"; neg/T2/t2-reader "$can" "$max" "$gl" "$ng"; } > "$RUN/$tag-$ph.reader" 2>&1
  done
  wait $rp
  cp /tmp/sealed-reason.log "$RUN/$tag.reason" 2>/dev/null
}
arm test build-t2-publish
arm control build-t2-publish-nosb

# Raw results.
for tag in test control; do
  echo "## $tag: spawner: $(tail -1 "$RUN/$tag.r2")" >> $O
  grep '^test: t2 ' "$RUN/$tag.reason" 2>/dev/null | sed "s/^/## $tag: reason: /" >> $O
  grep -vE '^test: |selftest' "$RUN/$tag.reason" 2>/dev/null | grep -v 'reported sandboxed' | head -3 | sed "s#$PWD/##g; s/^/## $tag: reason (other): /" >> $O
  for ph in sandboxed loaded; do sed "s/^/## $tag $ph: /" "$RUN/$tag-$ph.reader" >> $O; done
done

# Verdict against the pre-written criteria (T2.4).
fails=0
v() { [ "$1" = FAIL ] && fails=$((fails + 1)); echo "$1 $2" >> $O; }
R=$RUN/test.reason; C=$RUN/control.reason
# Validity 1: the test child sent "sandboxed" (534c5342) before the hook.
grep -Eq '534c5342|SANDBOXED then LOADED' "$RUN/test.r2" && v PASS "[valid-sandboxed-report] $(tail -1 "$RUN/test.r2")" \
  || v FAIL "[valid-sandboxed-report] $(tail -1 "$RUN/test.r2")"
# Validity 2: the test child reached the hazard in each phase (a surface made,
# the canary written, the hold started).
for ph in sandboxed loaded; do
  if grep -Eq "^test: t2 $ph (global|nonglobal) create=ok .* canary_written=[1-9]" "$R" && grep -q "^test: t2 $ph hold=" "$R"; then
    v PASS "[valid-hazard-$ph] $(grep "^test: t2 $ph " "$R" | grep -v hold= | paste -sd ';' -)"
  else v FAIL "[valid-hazard-$ph] $(grep "^test: t2 $ph " "$R" | paste -sd ';' - )"; fi
done
# Validity 3: the control reader finds the canary in the global surface by
# lookup and by sweep.
ctl=0
for ph in sandboxed loaded; do
  f=$RUN/control-$ph.reader
  gl=$(sed -nE 's/^HOLD .* global=([0-9]+) .*/\1/p' "$f")
  if [ -n "$gl" ] && [ "$gl" != 0 ] && grep -q "^ARM lookup id=$gl FOUND" "$f" && grep -Eq "^ARM sweep .*canary_ids=([0-9]+,)*$gl," "$f"; then
    ctl=$((ctl + 1)); v PASS "[control-$ph] global id=$gl read by lookup and sweep: $(grep '^ARM' "$f" | paste -sd ';' -)"
  else v INFO "[control-$ph] $(grep -E '^(ARM|NOHOLD)' "$f" | paste -sd ';' -)"; fi
done
[ $ctl -ge 1 ] || v FAIL "[control] the reader did not find the canary in any control phase"
# The finding: any canary or property read from a surface the sandboxed child made.
open=0 opened=0
for ph in sandboxed loaded; do
  f=$RUN/test-$ph.reader
  hit=$(grep -E '^ARM lookup id=[0-9]+ FOUND|prop=hit|^ARM sweep .*with_canary=[1-9]|^ARM sweep .*with_prop=[1-9]' "$f")
  if [ -n "$hit" ]; then open=1; v INFO "[sandboxed-child-$ph] READ: $(echo "$hit" | paste -sd ';' -)"
  else v INFO "[sandboxed-child-$ph] not read: $(grep -E '^(ARM|NOHOLD)' "$f" | paste -sd ';' -)"; fi
  grep -q '^ARM lookup id=[0-9]* OPENED-NO-CANARY' "$f" && opened=1
done
if [ $fails -gt 0 ]; then echo "VERDICT INVALID ($fails validity checks failed)" >> $O
elif [ $open = 1 ]; then echo "VERDICT OPEN, CONFIRMED CHANNEL (the reader got the canary from a surface the sandboxed child made)" >> $O
elif [ $opened = 1 ]; then echo "VERDICT NOT DECIDED (a lookup opened a child surface without the canary; outside the pre-written criteria)" >> $O
else echo "VERDICT CLOSED (no lookup, sweep or property hit under the sandbox; the control fired)" >> $O; fi
mkdir -p logs/t2-$(date +%F) && cp -p "$RUN"/*.reason "$RUN"/*.reader "$RUN"/*.r2 logs/t2-$(date +%F)/ 2>/dev/null
rm -rf "$RUN" /tmp/sealed-reason.log
cat $O
