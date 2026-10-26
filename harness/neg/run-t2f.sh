#!/bin/bash
# T2 follow-up (2026-10-22): does an SBPL method filter on
# IOSurfaceRootUserClient refuse a global IOSurface create while the Metal
# paths (MTL4 command queue, MTLSharedEvent) still work?
# See review/T2-FILTER-2026-10-22.md.
#
# Arms:
#   filter       production profile with (apply-message-filter ...) on
#                IOSurfaceRootUserClient; the T2F probe reports each result
#   noiosurface  the IOSurfaceRootUserClient allow removed (class-level deny)
#                with the T2F probe
#   syntax       which filter forms sandbox_init accepts at all (filt-probe)
#   chat         one chat request per build (neg/T2F/chat-arm.sh) and the
#                control (./smoke.sh, production child)
# The reader (neg/T2/t2-reader) runs while the noiosurface child holds.
# Writes neg/t2f-<date>.txt. No sudo. Run neg/build-all.sh first.
cd "$(dirname "$0")/.."
PKG=$PWD/pkg/qwen38-27b
O=neg/t2f-$(date +%F).txt
RUN=$PWD/neg/run-t2f
export BENCH_OK=1
: > $O
echo "# build: $(date '+%F %T') host=$(sysctl -n hw.model) $(sw_vers -buildVersion) uid=$(id -u)" >> $O
sign() { codesign -f -s - --options runtime -i sealed.splash "$1" 2>/dev/null; }
rm -rf "$RUN"; mkdir -p "$RUN"
printf 'r5 owndir probe\n' > "$RUN/r5-owndir-probe"

# arm <tag> <build folder> <wait seconds for a hold line>
arm() {
  local tag=$1 b=$2 lim=$3 ph line gl ng can max t
  cp splash/$b/splash "$RUN/splash-$b" && sign "$RUN/splash-$b"
  rm -f /tmp/sealed-reason.log
  R2NEG_POLL_MS=600000 neg/B/r2neg "$RUN/splash-$b" "$PKG" control > "$RUN/$tag.r2" 2>&1 &
  local rp=$!
  line=""; t=0
  while [ $t -lt "$lim" ]; do
    line=$(grep -m1 "^test: t2f sandboxed hold=" /tmp/sealed-reason.log 2>/dev/null)
    [ -n "$line" ] && break
    kill -0 $rp 2>/dev/null || break
    sleep 1; t=$((t + 1))
  done
  if [ -n "$line" ]; then
    gl=$(echo "$line" | sed -E 's/.* global=([0-9]+) .*/\1/')
    ng=$(echo "$line" | sed -E 's/.* nonglobal=([0-9]+) .*/\1/')
    can=$(echo "$line" | sed -E 's/.* canary=([0-9a-f]{64}).*/\1/')
    max=$(( (gl > ng ? gl : ng) + 4096 ))
    { echo "HOLD $line"; neg/T2/t2-reader "$can" "$max" "$gl" "$ng"; } > "$RUN/$tag.reader" 2>&1
  else
    echo "NOHOLD (no surface hold in this arm)" > "$RUN/$tag.reader"
  fi
  wait $rp
  cp /tmp/sealed-reason.log "$RUN/$tag.reason" 2>/dev/null
}

arm filter build-t2f-filter 60
arm noiosurface build-t2f-noiosurface 120

# Raw results.
for tag in filter noiosurface; do
  echo "## $tag: spawner: $(tail -1 "$RUN/$tag.r2")" >> $O
  grep '^test: t2f ' "$RUN/$tag.reason" 2>/dev/null | sed "s/^/## $tag: reason: /" >> $O
  grep -E 'sealed-r5: sandbox_init|sealed-r6|sealed-r5: Metal|error' "$RUN/$tag.reason" 2>/dev/null \
    | head -4 | sed "s/^/## $tag: reason: /" >> $O
  sed "s/^/## $tag: reader: /" "$RUN/$tag.reader" >> $O
done

# Syntax screening: which filter forms does sandbox_init accept at all?
# filt-probe applies the R5 profile shape (r5-extra/probe.mm) and appends the
# text below, so a parse or policy refusal shows before any child is built.
IOS='(allow iokit-open-user-client (iokit-user-client-class "IOSurfaceRootUserClient")'
S=$RUN/syntax.txt
syn() { printf '## syntax %s: %s\n' "$1" "$2" >> $S
        ./neg/T2F/filt-probe "$2" 2>&1 | grep -vE '^$|^Backtrace|^<input' | sed "s/^/## syntax $1: /" >> $S; }
syn class-allow "$IOS)"
syn filter-prior "$IOS(apply-message-filter (deny iokit-external-method (iokit-method-number 0))(allow iokit-external-method)))"
syn filter-apple "$IOS(apply-message-filter (deny iokit-external-method)(allow iokit-external-method (iokit-method-number 0 1 2 3 9 10 11 12 13 20))))"
syn filter-min "$IOS(apply-message-filter (allow iokit-external-method)))"
syn filter-parse "$IOS(apply-message-filter (bogus-op)))"
syn filter-arg "$IOS(apply-message-filter (allow iokit-external-method (iokit-method-argument 1))))"
# Selectors measured for the Metal probe (13 32 36 38 44) allowed, create (0) denied.
syn filter-metal "$IOS(apply-message-filter (deny iokit-external-method)(allow iokit-external-method (iokit-method-number 13 32 36 38 44))))"
syn filter-on-open '(allow iokit-open (iokit-user-client-class "IOSurfaceRootUserClient")(apply-message-filter (allow iokit-external-method)))'
IOO='(allow iokit-open (iokit-user-client-class "IOSurfaceRootUserClient"))'
syn toplevel-method "$IOO(deny iokit-external-method (iokit-method-number 0))"
syn toplevel-async "$IOO(deny iokit-async-external-method)"
syn toplevel-trap "$IOO(deny iokit-external-trap)"
syn open-methnum '(allow iokit-open (iokit-user-client-class "IOSurfaceRootUserClient")(iokit-method-number 1))'
syn setprops-deny "$IOO(deny iokit-set-properties (iokit-user-client-class \"IOSurfaceRootUserClient\"))"
# The filter needs com.apple.private.security.message-filter; an ad hoc
# signature with that entitlement is killed at exec (AMFI -424).
./neg/T2F/filt-probe-mf - > /dev/null 2>&1
printf '## syntax entitled-probe: filt-probe-mf (ad hoc, com.apple.private.security.message-filter) exec rc=%s\n' $? >> $S

# Chat legs: one request per build through the engine, plus the control.
C=$RUN/chat.txt
neg/T2F/chat-arm.sh build-t2f-filter filter >> $C 2>&1
neg/T2F/chat-arm.sh build-t2f-noiosurface-chat noiosurface >> $C 2>&1
neg/T2F/chat-arm.sh build control >> $C 2>&1
./smoke.sh t2fctl2 >> $C 2>&1
for l in "$(cat $S)" "$(cat $C)"; do printf '%s\n' "$l" | sed 's/^/## /' | grep -v '^## $' >> $O; done

# Validity checks (INVALID if one fails) and measurements (MEAS, the verdict
# inputs). A test profile that stops Metal is a result, not an invalid run.
fails=0; v() { [ "$1" = FAIL ] && fails=$((fails + 1)); echo "$1 $2" >> $O; }
m() { echo "MEAS $1" >> $O; }
FR=$RUN/filter.reason; NR=$RUN/noiosurface.reason

# V1 the production child serves a chat through the same chat leg.
ctl=$(grep -m1 '^PASS chat\[control\]' $C)
if [ -n "$ctl" ]; then v PASS "[valid-control-chat] $ctl"; else v FAIL "[valid-control-chat] $(grep -m1 'chat\[control\]' $C)"; fi
# V2 the probe detects working Metal and a global make under the unfiltered allow.
cl=$(grep -m1 '^## syntax class-allow: probe ' $S)
case "$cl" in
  *global=ok*device=1\ mtl4queue=1\ sharedEvent=1*) v PASS "[valid-probe-positive] $cl" ;;
  *) v FAIL "[valid-probe-positive] $cl" ;;
esac
# V3 the class-deny child was sandboxed (SLSB) and reached the T2F probe.
ml=$(grep -m1 "^test: t2f sandboxed metal " "$NR" 2>/dev/null)
if grep -q '534c5342' "$RUN/noiosurface.r2" && [ -n "$ml" ]; then
  v PASS "[valid-noiosurface-reached] $(tail -1 "$RUN/noiosurface.r2"); $ml"
else v FAIL "[valid-noiosurface-reached] $(tail -1 "$RUN/noiosurface.r2"); ${ml:-no metal line}"; fi
# V4 the reader ran while the class-deny child held.
if grep -q '^READER ' "$RUN/noiosurface.reader"; then v PASS "[valid-reader-ran] $(grep -m1 '^READER ' "$RUN/noiosurface.reader")"
else v FAIL "[valid-reader-ran] $(head -1 "$RUN/noiosurface.reader")"; fi

# M1 filter arm: the apply-message-filter profile and its effect.
fl=$(grep -m1 'sandbox_init failed' "$FR" 2>/dev/null)
if [ -n "$fl" ]; then fstate=refused; m "[filter-profile] sandbox_init refused the profile: $fl"
else fstate=applied; m "[filter-profile] applied: $(grep -m1 'test: t2f' "$FR" 2>/dev/null)"; fi
fgc=$(grep -m1 "^test: t2f sandboxed surface global" "$FR" 2>/dev/null)
m "[filter-global-make] ${fgc:-not reached (no child code ran under the profile)}"
m "[filter-reader] $(grep -E '^(ARM|NOHOLD)' "$RUN/filter.reader" | paste -sd ';' -)"
# M2 class-deny arm.
gc=$(grep -m1 "^test: t2f sandboxed surface global" "$NR" 2>/dev/null)
m "[noiosurface-global-make] $gc"
m "[noiosurface-metal] $ml"
m "[noiosurface-bootstrap] $(grep -m1 'bootstrap error' "$NR" 2>/dev/null)"
rd=$(grep -E '^ARM ' "$RUN/noiosurface.reader" 2>/dev/null | paste -sd ';' -)
if echo "$rd" | grep -qE 'canary_hits=[1-9]|with_canary=[1-9]|prop=hit|with_prop=[1-9]'; then rcan=hit; else rcan=none; fi
m "[noiosurface-reader] canary=$rcan $rd"
# M3 chat under each test profile.
for tag in filter noiosurface; do m "[$tag-chat] $(grep -m1 "chat\[$tag\]" $C)"; done
m "[smoke-info] $(grep -m1 'smoke\[' $C) (left counts any sealed-m5/child/splash, also a foreign server's child)"
# M4 forms that sandbox_init accepts, with their global-make result.
grep -E '^## syntax [a-z0-9-]+: probe global=' $S | sed -E 's/^## syntax ([a-z0-9-]+): probe (global=[a-z]+).*(mtl4queue=[01] sharedEvent=[01]).*/MEAS [accepted-form] \1 \2 \3/' >> $O

# Verdict by the criteria written before the run.
closed=0; np=0
grep -q '^PASS chat\[noiosurface\]' $C && case "$gc" in *create=NULL*) [ $rcan = none ] && closed=1 ;; esac
grep -q '^PASS chat\[filter\]' $C && [ "$fstate" = applied ] && case "$fgc" in *create=NULL*) closed=1 ;; esac
case "$gc" in *create=NULL*) np=1 ;; esac
[ "$fstate" = refused ] && np=1
if [ $fails -gt 0 ]; then echo "VERDICT INVALID ($fails validity checks failed)" >> $O
elif [ $closed = 1 ]; then echo "VERDICT CLOSED (a profile refuses the global make, the reader finds no canary, and the child serves a chat)" >> $O
elif [ $np = 1 ]; then echo "VERDICT NOT PRACTICAL (the method-filter profile is refused by sandbox_init, so the child cannot start; the class deny refuses the global make but MTL4 queue and shared event are nil and no chat is served; accepted forms that keep Metal also keep the global make)" >> $O
else echo "VERDICT OPEN (no tested rule refused the global make)" >> $O; fi
mkdir -p logs/t2f-$(date +%F) && cp -p "$RUN"/*.reason "$RUN"/*.reader "$RUN"/*.r2 "$S" "$C" logs/t2f-$(date +%F)/ 2>/dev/null
rm -rf "$RUN" /tmp/sealed-reason.log
cat $O
