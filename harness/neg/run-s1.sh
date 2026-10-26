#!/bin/bash
# S-1 driver (review/S1-IOGPU-2026-10-23.md): can code in the child share GPU
# memory with another process through the client the profile allows
# (IOGPUDeviceUserClient, the base class of AGXDeviceUserClient)?
# The test build makes a shared texture and a shared event, archives both
# handles into the reason file and holds 60 s per phase. While it holds,
# neg/S1/s1-reader (same user, no sandbox, different process) tries the handle,
# the texture's IOSurface ID, an ID sweep, and the IOKit registry. The control
# is the same build without the sandbox. Writes neg/s1-<date>.txt.
# Usage: neg/run-s1.sh   (build the two builds and the reader first; no sudo)
cd "$(dirname "$0")/.."
PKG=$PWD/pkg/qwen38-27b
O=neg/s1-$(date +%F).txt
REASON=/tmp/sealed-reason-s1.log   # the S1 builds own this path (see build-all.sh)
RUN=$PWD/neg/S1/run
export BENCH_OK=1
: > $O
# The suite and this driver both load the model and share the GPU. Wait for a
# running suite instead of competing with it (and never edit its record).
if pgrep -f "neg/run-all.sh" >/dev/null; then
  echo "waiting for a running neg/run-all.sh"
  for i in $(seq 1 180); do pgrep -f "neg/run-all.sh" >/dev/null || break; sleep 10; done
  pgrep -f "neg/run-all.sh" >/dev/null && { echo "a suite run is still active; not starting"; exit 9; }
fi
echo "# build: $(date '+%F %T') host=$(sysctl -n hw.model) $(sw_vers -buildVersion) uid=$(id -u)" >> $O
sign() { codesign -f -s - --options runtime -i sealed.splash "$1" 2>/dev/null; }
rm -rf "$RUN"; mkdir -p "$RUN"
printf 'r5 owndir probe\n' > "$RUN/r5-owndir-probe"   # the R5 self-test reads it next to the child

# arm <tag> <build folder>: runs the child through the test spawner and the
# reader once per phase, while the child holds its objects.
arm() {
  local tag=$1 b=$2 ph line can t t0
  t0=$(date '+%Y-%m-%d %H:%M:%S')
  cp splash/$b/splash "$RUN/splash-$b" && sign "$RUN/splash-$b"
  rm -f "$REASON"
  R2NEG_POLL_MS=600000 neg/B/r2neg "$RUN/splash-$b" "$PKG" control > "$RUN/$tag.r2" 2>&1 &
  local rp=$!
  for ph in sandboxed loaded; do
    line=""; t=0
    while [ $t -lt 900 ]; do
      line=$(grep -m1 "^test: s1 $ph hold=" "$REASON" 2>/dev/null)
      [ -n "$line" ] && break
      kill -0 $rp 2>/dev/null || break
      sleep 1; t=$((t + 1))
    done
    if [ -z "$line" ]; then echo "NOHOLD phase=$ph" > "$RUN/$tag-$ph.reader"; continue; fi
    can=$(echo "$line" | sed -E 's/.* canary=([0-9a-f]{64}).*/\1/')
    { echo "HOLD $line"; neg/S1/s1-reader "$ph" "$can" "$REASON"; } > "$RUN/$tag-$ph.reader" 2>&1
  done
  wait $rp
  cp "$REASON" "$RUN/$tag.reason" 2>/dev/null
  # Kernel evidence for the two transport directions (the reason file records
  # the return codes; the kernel records why).
  log show --start "$t0" --style compact --predicate 'eventMessage CONTAINS "com.sealed.s1.host" OR eventMessage CONTAINS "com.apple.system.logger"' \
    > "$RUN/$tag.denies" 2>/dev/null
}
arm test build-s1-share
arm control build-s1-share-nosb

# Raw results.
for tag in test control; do
  echo "## $tag: spawner: $(tail -1 "$RUN/$tag.r2")" >> $O
  grep -E '^test: s1 .* (metal|tex create|tex content|ev create|xpc|surf|hold=|released)' "$RUN/$tag.reason" 2>/dev/null \
    | sed "s/^/## $tag: reason: /" >> $O
  grep '^test: s1 .* handle=' "$RUN/$tag.reason" 2>/dev/null \
    | sed -E 's/(handle=)[0-9a-f]+/\1<hex>/' | sed "s/^/## $tag: reason: /" >> $O
  grep -vE '^test: |selftest' "$RUN/$tag.reason" 2>/dev/null | grep -v 'reported sandboxed' | head -3 \
    | sed "s#$PWD/##g; s/^/## $tag: reason (other): /" >> $O
  for ph in sandboxed loaded; do sed "s/^/## $tag $ph: /" "$RUN/$tag-$ph.reader" >> $O; done
done

# Criteria checks. v <PASS|FAIL|INFO> <text>
fails=0
v() { [ "$1" = FAIL ] && fails=$((fails + 1)); echo "$1 $2" >> $O; }

# V1: the test child sent "sandboxed" and then loaded; the hook ran in both phases.
grep -q 'SANDBOXED then LOADED' "$RUN/test.r2" \
  && v PASS "[valid-report] $(tail -1 "$RUN/test.r2")" \
  || v FAIL "[valid-report] $(tail -1 "$RUN/test.r2")"
for ph in sandboxed loaded; do
  if grep -q "^test: s1 $ph hold=" "$RUN/test.reason"; then
    v PASS "[valid-hazard-$ph] $(grep -E "^test: s1 $ph (metal|tex create|ev create|xpc|surf|hold=)" "$RUN/test.reason" | paste -sd ';' - | cut -c1-500)"
  else
    v FAIL "[valid-hazard-$ph] no hold line in the reason file"
  fi
done

# V2: the control must fire on each leg the verdicts use.
T=$RUN/test.reason; C=$RUN/control.reason
ctl_tex=$(grep -c '^test: s1 .* tex create=ok' "$C")
ctl_ev=$(grep -c '^test: s1 .* ev create=ok' "$C")
ctl_xpc=$(grep -c '^test: s1 .* xpc register=ok .* lookup=ok' "$C")
ctl_lookup=$(grep -c '^ARM ios global .*FOUND' "$RUN/control-loaded.reader")
ctl_sweep=$(grep -c '^ARM sweep .*with_canary=[1-9]' "$RUN/control-loaded.reader")
v $([ "$ctl_tex" -gt 0 ] && echo PASS || echo FAIL) "[control-tex-create] $ctl_tex of 2 phases made the shared texture without the sandbox"
v $([ "$ctl_ev" -gt 0 ] && echo PASS || echo FAIL) "[control-ev-create] $ctl_ev of 2 phases made the shared event without the sandbox"
v $([ "$ctl_xpc" -gt 0 ] && echo PASS || echo FAIL) "[control-xpc] $ctl_xpc of 2 phases registered and looked up a Mach service without the sandbox"
v $([ "$ctl_lookup" -gt 0 ] || [ "$ctl_sweep" -gt 0 ] && echo PASS || echo FAIL) "[control-surface] the control reader found its global surface by lookup/sweep: $(grep -E '^ARM (ios global|sweep)' "$RUN/control-loaded.reader" | paste -sd ';' -)"

# P1: shared texture handle.
p1=VOID; p1e="control did not make a shared texture"
if [ "$ctl_tex" -gt 0 ]; then
  t=$(grep -c '^test: s1 .* tex create=ok' "$T")
  x=$(grep -c '^test: s1 .* xpc register=REFUSED .* lookup=REFUSED' "$T")
  h=$(grep -h '^ARM tex ' "$RUN"/test-*.reader | grep -c 'canary_hits=[1-9]')
  if [ "$h" -gt 0 ]; then p1=OPEN; p1e="the reader read the canary"
  elif [ "$t" -eq 0 ]; then p1=CLOSED; p1e="the sandboxed child made no shared texture: $(grep -m1 'tex create=' "$T")"
  elif [ "$x" -gt 0 ] && [ "$ctl_xpc" -gt 0 ]; then p1=CLOSED
    p1e="the handle encodes only for NSXPCCoder ($(grep -m1 'encode=' "$T" | sed -E 's/.*encode=([A-Za-z-]+).*/\1/')) and the child's two XPC directions are refused in both phases (control: both succeed)"
  else p1=CLOSED; p1e="the reader read no canary by handle, and no transport is open"
  fi
fi
v INFO "[P1-tex] verdict=$p1 $p1e"

# P2: shared event handle.
p2=VOID; p2e="control did not make a shared event"
if [ "$ctl_ev" -gt 0 ]; then
  t=$(grep -c '^test: s1 .* ev create=ok' "$T")
  x=$(grep -c '^test: s1 .* xpc register=REFUSED .* lookup=REFUSED' "$T")
  h=$(grep -h '^ARM ev ' "$RUN"/test-*.reader | grep -c 'value_match=1')
  if [ "$h" -gt 0 ]; then p2=OPEN; p2e="the reader read the event value"
  elif [ "$t" -eq 0 ]; then p2=CLOSED; p2e="the sandboxed child made no shared event: $(grep -m1 'ev create=' "$T")"
  elif [ "$x" -gt 0 ] && [ "$ctl_xpc" -gt 0 ]; then p2=CLOSED
    p2e="the handle is XPC-only and the child's two XPC directions are refused in both phases (control: both succeed)"
  else p2=CLOSED; p2e="the reader read no event, and no transport is open"
  fi
fi
v INFO "[P2-event] verdict=$p2 $p2e"

# P5: IOSurface global ID and sweep (the reader's positive-control path).
p5=VOID; p5e="control made no global surface"
if [ "$ctl_lookup" -gt 0 ] || [ "$ctl_sweep" -gt 0 ]; then
  t=$(grep -c '^test: s1 .* surf global create=ok' "$T")
  h=$(grep -h -E '^ARM (ios global|sweep)' "$RUN"/test-*.reader | grep -cE 'FOUND|with_canary=[1-9]')
  if [ "$h" -gt 0 ]; then p5=OPEN; p5e="the reader found the sandboxed child's surface"
  elif [ "$t" -eq 0 ]; then p5=CLOSED; p5e="the global create returned NULL in both phases: $(grep -m1 'surf global' "$T")"
  else p5=CLOSED; p5e="the surface was made but the reader could not open it"
  fi
fi
v INFO "[P5-iosurface] verdict=$p5 $p5e"

# P4: registry (discovery only, no handoff).
p4=CLOSED
grep -q 'with_canary=[1-9]' "$RUN"/test-*.reader && p4=OPEN
v INFO "[P4-registry] verdict=$p4 $(grep -h '^ARM registry' "$RUN/test-loaded.reader" | paste -sd ';' - | cut -c1-400)"

# P1b and P3 have no path: P1b has no IOSurface even without a sandbox
# (control), and P3 has no API. Both are source rows in the report.
v INFO "[P1b-ios] $(grep -h '^ARM tex NO-HANDLE' "$RUN/control-loaded.reader" | head -1)"

# Verdict summary, in the per-path order of the report.
{
  echo "# verdict P1-tex: $p1"
  echo "# verdict P2-event: $p2"
  echo "# verdict P5-iosurface: $p5"
  echo "# verdict P4-registry: $p4"
  echo "# result: $fails failed"
} >> $O
echo "P1=$p1 P2=$p2 P5=$p5 P4=$p4"
exit $([ $fails -eq 0 ] && echo 0 || echo 1)
