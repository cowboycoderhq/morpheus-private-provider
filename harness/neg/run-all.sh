#!/bin/bash
# Runs the whole negative suite for the sealed Splash child on this Mac and
# writes one line per case to neg/final-<date>.txt, each marked PASS or FAIL
# against its expected result. Run neg/build-all.sh first.
# Usage: neg/run-all.sh   (exit 1 if any case fails)
cd "$(dirname "$0")/.."
. tools/suite-lock.sh && suite_lock neg/run-all.sh
PKG=$PWD/pkg/qwen38-27b
O=neg/final-$(date +%F).txt
RUN=$PWD/neg/run           # scratch folder for the test children
export BENCH_OK=1
: > $O
echo "# build: $(date '+%F %T') host=$(sysctl -n hw.model) $(sw_vers -buildVersion)" >> $O
fails=0
reason() { grep -vE 'selftest|accepted residual|reported sandboxed|^test: ' /tmp/sealed-reason.log 2>/dev/null | head -1 | sed "s#$PWD/##g" | cut -c1-400; }
# record <tag> <expected ERE> <line>
record() {
  local tag=$1 want=$2 line=$3 r v
  r=$(reason)
  if echo "$line | $r" | grep -Eq "$want"; then v=PASS; else v=FAIL; fails=$((fails + 1)); fi
  echo "$v [$tag] ${line#*] } | reason: $r" >> $O
}
sign() { codesign -f -s - --options runtime -i sealed.splash "$1" 2>/dev/null; }
r2() {  # r2 <tag> <exe> <pkg> <case> <expected ERE>
  rm -f /tmp/sealed-reason.log
  record "$1" "$5" "$(neg/B/r2neg "$2" "$3" "$4" 2>&1 | tail -1)"
}
REFUSED='exit=113 '
LOADED='exit=-9 SANDBOXED then LOADED'

rm -rf "$RUN"; mkdir -p "$RUN"
printf 'r5 owndir probe\n' > "$RUN/r5-owndir-probe"
cp splash/build-reason/splash test-child/splash && sign test-child/splash
printf 'r5 owndir probe\n' > test-child/r5-owndir-probe

# 1. R2 self-check, config frame, cache directory and probe cases.
r2 control "$PWD/test-child/splash" "$PKG" control "$LOADED"
# T2 (2026-10-23, review/DENSE-KV-2026-10-23.md): in the control load, the
# self-test's IOSurfaceRootUserClient open was refused (kIOReturnNotPermitted).
record R5-iosurface-open-refused "^\[x\] sealed-r5 selftest iosurface-open rc=0xe00002e2 " \
  "[x] $(grep -m1 '^sealed-r5 selftest iosurface-open' /tmp/sealed-reason.log 2>/dev/null)"
# Each R2 case must be refused for its own reason (code and text).
r2c() { r2 "$1" "$PWD/test-child/splash" "$PKG" "$1" "${REFUSED}no first byte.*$2"; }
r2c extra-fd "refused code=1: unexpected open descriptor 7"
r2c high-fd "refused code=1: unexpected open descriptor 300"
r2c stdout-not-socket "refused code=1: fd 0 and fd 1 must be one unix stream socket"
r2c extra-env "refused code=2: MTL_DEBUG_LAYER=1"
r2c env-differs "refused code=2: environment must be exactly HOME and TMPDIR"
r2c dir-mode "refused code=3: TMPDIR must be a 0700 directory"
r2c dir-extra-file "refused code=3: TMPDIR must hold only metal-cache"
r2c cwd "refused code=4: /"
r2c blocked-signal "refused code=5: signal 30 is blocked"
r2c ignored-signal "refused code=5: signal 31 is ignored"
r2c rlimit-nofile "refused code=6: RLIMIT_NOFILE is 512/1024"
r2c argv-form "refused code=7: MAX_MEMORY must be auto"
r2c argv-nonc "refused code=7: roots must be canonical absolute paths"
r2 frame-truncated "$PWD/test-child/splash" "$PKG" frame-truncated "${REFUSED}.*config frame truncated"
r2 frame-magic "$PWD/test-child/splash" "$PKG" frame-magic "${REFUSED}.*bad magic"
r2 frame-roots "$PWD/test-child/splash" "$PKG" frame-roots "${REFUSED}.*roots differ"
r2 frame-manifest "$PWD/test-child/splash" "$PKG" frame-manifest "${REFUSED}.*manifest does not parse"
r2 frame-trailing "$PWD/test-child/splash" "$PKG" frame-trailing "${REFUSED}.*code=8"
# Chunked KV (2026-10-23, review/CHUNKED-KV-2026-10-23.md): a version 2 frame
# carries the KV budget. A valid budget loads; a budget below the minimum and
# an unknown version are refused.
r2 frame-kv-budget "$PWD/test-child/splash" "$PKG" frame-kv-budget "$LOADED"
r2 frame-kv-budget-low "$PWD/test-child/splash" "$PKG" frame-kv-budget-low "${REFUSED}.*kv budget out of range"
r2 frame-version "$PWD/test-child/splash" "$PKG" frame-version "${REFUSED}.*bad magic or version"
r2 cache-mode "$PWD/test-child/splash" "$PKG" cache-mode "${REFUSED}no first byte.*metal-cache must be a 0700"
r2 cache-symlink "$PWD/test-child/splash" "$PKG" cache-symlink "${REFUSED}no first byte.*TMPDIR must hold only metal-cache"
r2 no-probes "$PWD/test-child/splash" "$PKG" no-probes "${REFUSED}first byte S, then 0 bytes.*not denied: read-tmpdir-probe"

# 2. R5 own-folder probe absent: the self-test gets ENOENT, which is not EPERM.
rm -f test-child/r5-owndir-probe
r2 owndir-probe-absent "$PWD/test-child/splash" "$PKG" control "${REFUSED}first byte S, then 0 bytes.*not denied: read-owndir-file"
printf 'r5 owndir probe\n' > test-child/r5-owndir-probe

# 2b. The child started through a symlinked path (R2 refuses before the first byte).
ln -s "$PWD/test-child" /tmp/sealed-symlink-$$
r2 exe-through-symlink /tmp/sealed-symlink-$$/splash "$PKG" control "${REFUSED}no first byte.*executable path must be canonical"
rm -f /tmp/sealed-symlink-$$

# 3. R6 package cases (hard-linked copies of the package with one change).
BASE=$PKG
mk() { rm -rf neg/A/pkg-$1; mkdir -p neg/A/pkg-$1; (cd $BASE && find . -type f) | while read f; do mkdir -p "neg/A/pkg-$1/$(dirname $f)"; ln "$BASE/$f" "neg/A/pkg-$1/$f"; done; }
mk byteflip; f=neg/A/pkg-byteflip/target/layer-7.bin; rm $f; cp $BASE/target/layer-7.bin $f
python3 -c "import sys;p=sys.argv[1];f=open(p,'r+b');f.seek(123456);b=f.read(1);f.seek(123456);f.write(bytes([b[0]^1]))" $f
r2 R6-byteflip "$PWD/test-child/splash" "$PWD/neg/A/pkg-byteflip" control "${REFUSED}.*SHA-256 mismatch"
mk symlink; f=neg/A/pkg-symlink/target/head.bin; rm $f; ln -s $BASE/target/head.bin $f
r2 R6-symlink "$PWD/test-child/splash" "$PWD/neg/A/pkg-symlink" control "${REFUSED}.*open failed"
mk trunc; f=neg/A/pkg-trunc/draft/model.bin; rm $f; head -c 1000000 $BASE/draft/model.bin > $f
r2 R6-trunc "$PWD/test-child/splash" "$PWD/neg/A/pkg-trunc" control "${REFUSED}.*end of file"
mk grown; f=neg/A/pkg-grown/target/embedding.bin; rm $f; cp $BASE/target/embedding.bin $f; printf 'X' >> $f
r2 R6-grown "$PWD/test-child/splash" "$PWD/neg/A/pkg-grown" control "${REFUSED}.*larger than the manifest"
mk manifest; m=neg/A/pkg-manifest/sealed-manifest.bin; rm $m
python3 -c "import sys;b=bytearray(open(sys.argv[1],'rb').read());b[-1]^=1;open(sys.argv[2],'wb').write(b)" $BASE/sealed-manifest.bin $m
r2 R6-manifest "$PWD/test-child/splash" "$PWD/neg/A/pkg-manifest" control "${REFUSED}.*SHA-256 mismatch: neg/A/pkg-manifest/vision/model.bin"
mk missing; rm neg/A/pkg-missing/vision/model.bin
r2 R6-missing "$PWD/test-child/splash" "$PWD/neg/A/pkg-missing" control "${REFUSED}.*open failed: neg/A/pkg-missing/vision/model.bin"
mk notlisted; m=neg/A/pkg-notlisted/sealed-manifest.bin; rm $m
python3 - $BASE/sealed-manifest.bin $m <<'PY'
import sys,struct
b=open(sys.argv[1],'rb').read(); n=struct.unpack('>I',b[18:22])[0]; off=22; out=[]
for i in range(n):
    l=struct.unpack('>H',b[off+1:off+3])[0]; e=b[off:off+3+l+40]; p=b[off+3:off+3+l]
    if p!=b'vision/model.bin': out.append(e)
    off+=3+l+40
open(sys.argv[2],'wb').write(b[:18]+struct.pack('>I',len(out))+b''.join(out))
PY
r2 R6-notlisted "$PWD/test-child/splash" "$PWD/neg/A/pkg-notlisted" control "${REFUSED}.*not in the manifest"
mk casefold; m=neg/A/pkg-casefold/sealed-manifest.bin; rm $m
python3 - $BASE/sealed-manifest.bin $m <<'PY'
import sys,struct
b=open(sys.argv[1],'rb').read(); n=struct.unpack('>I',b[18:22])[0]; off=22; ents=[]
for i in range(n):
    l=struct.unpack('>H',b[off+1:off+3])[0]; ents.append(b[off:off+3+l+40]); off+=3+l+40
def key(e):
    l=struct.unpack('>H',e[1:3])[0]; return (e[0], e[3:3+l])
src=[e for e in ents if key(e)==(1,b'embedding.bin')][0]
p=b'EMBEDDING.bin'; ents.append(src[:1]+struct.pack('>H',len(p))+p+src[3+13:])
ents.sort(key=key)
open(sys.argv[2],'wb').write(b[:18]+struct.pack('>I',len(ents))+b''.join(ents))
PY
r2 R6-casefold "$PWD/test-child/splash" "$PWD/neg/A/pkg-casefold" control "${REFUSED}.*name one file \\(case fold\\)"
rm -rf neg/A/pkg-*

# 4. Test builds: latch, second read, planted mappings, profile mutants,
#    no sandbox, early report.
tb() {  # tb <tag> <build folder> <expected ERE>
  cp splash/$2/splash "$RUN/splash-$2" && sign "$RUN/splash-$2"
  r2 "$1" "$RUN/splash-$2" "$PKG" control "$3"
}
tb R6-open-after-latch build-t1 "${REFUSED}.*latch"
tb R6-second-read build-t3 "${REFUSED}.*second read"
tb R6-plant-hosts build-t2 "${REFUSED}.*self-audit failed: /private/etc/hosts "
tb R6-plant-caches build-pl-caches "${REFUSED}.*self-audit failed: /System/Library/Caches/com.apple.IntlDataCache.le "
tb R6-plant-snmp build-pl-snmp "${REFUSED}.*self-audit failed: /usr/share/snmp/SensorDat.xml "
tb R6-plant-coretypes build-pl-coretypes "${REFUSED}.*self-audit failed: /System/Library/CoreServices/CoreTypes.bundle/Contents/Library/"
tb R5-mutant-ALLOW_WRITE build-m-ALLOW_WRITE "${REFUSED}first byte S, then 0 bytes.*sealed-r5: self-test access was not denied: write-"
tb R5-mutant-ALLOW_NET build-m-ALLOW_NET "${REFUSED}first byte S, then 0 bytes.*sealed-r5: self-test access was not denied: (connect|bind)-"
tb R5-mutant-ALLOW_LOOKUP build-m-ALLOW_LOOKUP "${REFUSED}first byte S, then 0 bytes.*sealed-r5: self-test mach-lookup did not return the recorded denial"
tb R5-mutant-ALLOW_IOSURFACE build-m-ALLOW_IOSURFACE "${REFUSED}first byte S, then 0 bytes.*sealed-r5: self-test access was not denied: iosurface-open"
tb N7-report-early build-early "${REFUSED}first byte S, then 0 bytes.*out of order"
# Without the sandbox, Apple frameworks map analyticsd's allowlist and the
# self-audit refuses before "loaded" (recorded 2026-10-12, neg/C/results.txt).
tb R5-no-sandbox-child build-nosb "${REFUSED}first byte S, then 0 bytes.*self-audit failed: /private/var/db/analyticsd"
tb N7-skip-sandboxed-report build-skipsb "LOADED WITHOUT a sandboxed report"
tb N4-profile-truncated build-cap "${REFUSED}first byte S, then 0 bytes.*profile text truncated"

# 4b. S3 (2026-10-21): share mode, descriptors, open log. Each case has a
#     hook line that shows the hazard arrived (the "proof" pattern, matched at
#     the start of the record line) and the exact refusal. Each has a control
#     that does the same operation in an allowed form and loads.
hook() { grep '^test: ' /tmp/sealed-reason.log 2>/dev/null | sed "s#$PWD/##g" | paste -sd ';' - | cut -c1-400; }
s3() {  # s3 <tag> <build folder> <proof ERE> <expected ERE>
  cp splash/$2/splash "$RUN/splash-$2" && sign "$RUN/splash-$2"
  rm -f /tmp/sealed-reason.log
  local L; L=$(neg/B/r2neg "$RUN/splash-$2" "$PKG" control 2>&1 | tail -1)
  record "$1" "^\[x\] $3.* \|\| $4" "[x] $(hook) || ${L#*] }"
}
T='sealed-r6: self-audit failed'
P='first byte S, then 4 bytes: 534c5342 '   # refused after "sandboxed", during or after the load
# Share mode. A writable memory entry made before the protect keeps write
# access. The hook writes through it after the protect (the read-only view
# changes, so the hazard is real) and restores the byte (so the hash still
# matches and only the share-mode check can refuse).
s3 S3-share-rw-alias build-s3-rwalias \
   "test: rw memory entry on head.bin kr=0 size=0x[0-9a-f]+;test: wrote through the alias after the protect kr=0 read-only view changed=1 restored=1" \
   "${REFUSED}${P}.*sealed-r6: weights region not private before the hash: pkg/qwen38-27b/target/head.bin sm=5 ref=3 prot=1/1 inh=2 shadow=0$"
s3 S3-share-rw-alias-dropped build-s3-rwalias-drop "test: rw memory entry on head.bin kr=0" "${LOADED}"
# A read-only memory entry (the port another task maps) on a weights region
# after the load. Control: the same entry on ordinary anonymous memory.
s3 S3-share-entry build-s3-share "test: memory entry on target/head.bin kr=0 sm 5->5 ref 2->3" \
   "${REFUSED}${P}.*$T: weights region shared: pkg/qwen38-27b/target/head.bin sm=5 ref=3 prot=1/1 inh=2 shadow=0, want sm=5 ref=2"
s3 S3-share-entry-ctl build-s3-share-ctl "test: memory entry on anonymous control memory kr=0 sm 2->5 ref 1->2" "${LOADED}"
# Descriptors kept from before the sandbox. The hard link is the Hugging Face
# blob of target/head.bin (another path, the same file). F_GETPATH names a
# hard-linked file by the last name it was opened through (measured), so the
# match is by device and inode, and the reason names the manifest entry.
s3 S3-fd-hardlink build-s3-fd-blob "test: kept descriptor of /[^ ]+/blobs/65008e2f[0-9a-f]+ fd=[0-9]+ errno=0" \
   "${REFUSED}${P}.*$T: descriptor refers to a funnel-opened file: fd [0-9]+ [^ ]+ [(]manifest pkg/qwen38-27b/target/head.bin[)]"
s3 S3-fd-root build-s3-fd-root "test: kept descriptor of pkg/qwen38-27b/target fd=[0-9]+ errno=0" \
   "${REFUSED}${P}.*$T: descriptor refers to a model root: fd [0-9]+ pkg/qwen38-27b/target$"
s3 S3-fd-under-root build-s3-fd-under "test: kept descriptor of pkg/qwen38-27b/tokenizer/vocab.json fd=[0-9]+ errno=0" \
   "${REFUSED}${P}.*$T: descriptor refers to a path under a model root: fd [0-9]+ pkg/qwen38-27b/tokenizer/vocab.json$"
s3 S3-fd-outside build-s3-fd-hosts "test: kept descriptor of /private/etc/hosts fd=[0-9]+ errno=0" \
   "${REFUSED}${P}.*$T: descriptor refers to a file outside the sealed volume: fd [0-9]+ /private/etc/hosts$"
s3 S3-fd-system-ctl build-s3-fd-sys "test: kept descriptor of /System/Library/CoreServices/SystemVersion.plist fd=[0-9]+ errno=0" "${LOADED}"
# A loader open that bypasses the funnel after the load (the sandbox allows
# the literal). Control: the same open, closed before the latch.
s3 S3-bypass-open build-s3-bypass "test: bypass open of pkg/qwen38-27b/target/embedding.bin fd=[0-9]+ errno=0" \
   "${REFUSED}${P}.*$T: descriptor refers to a funnel-opened file: fd [0-9]+ pkg/qwen38-27b/target/embedding.bin [(]manifest pkg/qwen38-27b/target/embedding.bin[)]"
s3 S3-bypass-open-closed build-s3-bypass-close "test: bypass open of pkg/qwen38-27b/target/embedding.bin fd=[0-9]+ errno=0" "${LOADED}"
# Open log. The funnel opens head.bin through a case variant of its on-disk
# name (APFS folds case, and the sandbox literal admits it). F_GETPATH gives
# the on-disk name, which is not the manifest path. The proof is that the load
# got past the hash check of that file (all other R6 cases refuse earlier).
# Control: the same package with the on-disk name equal to the manifest path.
mk() { rm -rf neg/A/pkg-$1; mkdir -p neg/A/pkg-$1; (cd $PKG && find . -type f) | while read f; do mkdir -p "neg/A/pkg-$1/$(dirname $f)"; ln "$PKG/$f" "neg/A/pkg-$1/$f"; done; }
mk caseopen; mv neg/A/pkg-caseopen/target/head.bin neg/A/pkg-caseopen/target/Head.bin
r2 S3-openlog-case "$PWD/test-child/splash" "$PWD/neg/A/pkg-caseopen" control \
   "${REFUSED}${P}.*$T: open log names a path not in the manifest: neg/A/pkg-caseopen/target/Head.bin [(]opened as neg/A/pkg-caseopen/target/head.bin[)]"
mv neg/A/pkg-caseopen/target/Head.bin neg/A/pkg-caseopen/target/head.bin
r2 S3-openlog-case-ctl "$PWD/test-child/splash" "$PWD/neg/A/pkg-caseopen" control "${LOADED}"

# 4c. S3 mutation runs (2026-10-22). Each refused S3 case runs again on a
#     child with its check compiled out (SEALED_TEST_NO_SHAREMODE, _NO_FDCHECK,
#     _NO_OPENLOG). PASS only if the mutant names the check it lacks, the hook
#     shows the hazard arrived, and the child loads with the hazard in place.
#     A refusal here means another check also catches the hazard (a finding).
#     The plain mutants load the unchanged package (the mutation alone does
#     not stop the child).
mut() {  # mut <tag> <build folder> <package> <proof ERE> [extra proof text]
  cp splash/$2/splash "$RUN/splash-$2" && sign "$RUN/splash-$2"
  rm -f /tmp/sealed-reason.log
  local L; L=$(neg/B/r2neg "$RUN/splash-$2" "$3" control 2>&1 | tail -1)
  record "$1" "^\[x\] $4 \|\| ${LOADED}" "[x] $(hook)$5 || ${L#*] }"
}
MS='test: mutant SEALED_TEST_NO_SHAREMODE'
MF='test: mutant SEALED_TEST_NO_FDCHECK'
MO='test: mutant SEALED_TEST_NO_OPENLOG'
mut M-plain-noshar build-noshar "$PKG" "$MS"
mut M-plain-nofd build-nofd "$PKG" "$MF"
mut M-plain-noopen build-noopen "$PKG" "$MO"
mut M-S3-share-rw-alias build-noshar-rwalias "$PKG" \
    "$MS;test: rw memory entry on head.bin kr=0 size=0x[0-9a-f]+;test: wrote through the alias after the protect kr=0 read-only view changed=1 restored=1"
mut M-S3-share-entry build-noshar-share "$PKG" "$MS;test: memory entry on target/head.bin kr=0 sm 5->5 ref 2->3"
mut M-S3-fd-hardlink build-nofd-blob "$PKG" "$MF;test: kept descriptor of /[^ ]+/blobs/65008e2f[0-9a-f]+ fd=[0-9]+ errno=0"
mut M-S3-fd-root build-nofd-root "$PKG" "$MF;test: kept descriptor of pkg/qwen38-27b/target fd=[0-9]+ errno=0"
mut M-S3-fd-under-root build-nofd-under "$PKG" "$MF;test: kept descriptor of pkg/qwen38-27b/tokenizer/vocab.json fd=[0-9]+ errno=0"
mut M-S3-fd-outside build-nofd-hosts "$PKG" "$MF;test: kept descriptor of /private/etc/hosts fd=[0-9]+ errno=0"
mut M-S3-bypass-open build-nofd-bypass "$PKG" "$MF;test: bypass open of pkg/qwen38-27b/target/embedding.bin fd=[0-9]+ errno=0"
# Open log: the same case package as S3-openlog-case. The on-disk listing is
# the proof that the only head.bin on disk is the case variant, so a load
# means the funnel read the weights through a name not in the manifest.
mv neg/A/pkg-caseopen/target/head.bin neg/A/pkg-caseopen/target/Head.bin
ON=$(cd neg/A/pkg-caseopen/target && ls | grep -i '^head\.bin$' | paste -sd ',' -)
mut M-S3-openlog-case build-noopen "$PWD/neg/A/pkg-caseopen" "$MO;on-disk target: Head.bin" ";on-disk target: $ON"
rm -rf neg/A/pkg-caseopen

# 5. N7 at the engine side: the launcher refuses a sandboxed child that sends
#    "loaded" without "sandboxed" first (the skip-report build, pinned for this
#    run). The launcher log must show that it got the SLLD bytes, so the
#    refusal is the order check and not a dead child.
E=$RUN/splash-build-skipsb; PIN=$(codesign -dvvv "$E" 2>&1 | awk -F= '/^CDHash=/{print $2}')
tools/reqgen "$E" "$PIN" dummy "$RUN/req-skipsb.bin" >/dev/null
rm -f /tmp/sealed-reason.log
L=$(SEALED_CHILD="$E" SEALED_PIN="$PIN" SEALED_REQ="$RUN/req-skipsb.bin" SEALED_STRICT=0 SEALED_LOG="$RUN/launch-skipsb.log" \
    launcher/sealed-launch serve-native "$PKG/target" "$PKG/draft" 8192 auto < /dev/null 2>&1 | tail -1)
G=$(grep -m1 "sandboxed report:" "$RUN/launch-skipsb.log")
record "N7-launcher-refuses-loaded-first" "no sandboxed report from the child.*got 534c4c44" "[x] $L | $G"
# 6. Launcher spawn checks on the staged production child (run ./stage-child.sh
#    first): wrong pin, wrong requirement (canary on and off), tampered and
#    re-signed binary (with the good pin and with its own pin), broken signature.
GOOD=$(cat child/pin.txt)
DPIN=$(codesign -dvvv tools/decoy 2>&1 | awk -F= '/^CDHash=/{print $2}')
tools/reqgen tools/decoy "$DPIN" dummy "$RUN/req-decoy.bin" >/dev/null
cp child/splash "$RUN/splash-tampered"
python3 -c "import sys;p=sys.argv[1];b=bytearray(open(p,'rb').read());i=b.find(b'expected the serve-native command');assert i>0;b[i]=ord('E');open(p,'wb').write(b)" "$RUN/splash-tampered"
cp "$RUN/splash-tampered" "$RUN/splash-broken"   # changed byte, not re-signed
sign "$RUN/splash-tampered"
TPIN=$(codesign -dvvv "$RUN/splash-tampered" 2>&1 | awk -F= '/^CDHash=/{print $2}')
lrun() {  # lrun <tag> <child> <pin> <req> <strict> <expected ERE>
  SEALED_CHILD=$2 SEALED_PIN=$3 SEALED_REQ=$4 SEALED_STRICT=$5 SEALED_DECOY=$PWD/tools/decoy SEALED_DECOY_PIN=$DPIN \
    SEALED_LOG="$RUN/$1.log" perl -e 'alarm 120; exec @ARGV' launcher/sealed-launch serve-native "$PKG/target" "$PKG/draft" 8192 auto \
    < /dev/null > /dev/null 2> "$RUN/$1.err"
  local rc=$?
  rm -f /tmp/sealed-reason.log
  record "L-$1" "$6" "[x] exit=$rc $(grep -m1 'spawn rc' "$RUN/$1.log") | $(grep -m1 'manifest hash matches' "$RUN/$1.log") | $(head -1 "$RUN/$1.err")"
}
lrun control "$PWD/child/splash" "$GOOD" "$PWD/child/req-splash.bin" 1 "spawn rc=0 .*manifest hash matches"
lrun wrong-pin "$PWD/child/splash" "$DPIN" "$PWD/child/req-splash.bin" 1 "exit=70 spawn rc=15 .*sealed spawn refused, code 15"
# With the canary on, a requirement that admits the decoy fails the canary first.
lrun wrong-req "$PWD/child/splash" "$GOOD" "$RUN/req-decoy.bin" 1 "exit=70 .*A-13 canary failed"
lrun wrong-req-nocanary "$PWD/child/splash" "$GOOD" "$RUN/req-decoy.bin" 0 "exit=70 spawn rc=16 .*suspended=0x23011311 .*sealed spawn refused, code 16"
lrun tampered "$RUN/splash-tampered" "$GOOD" "$PWD/child/req-splash.bin" 1 "exit=70 spawn rc=15 .*sealed spawn refused, code 15"
lrun tampered-own-pin "$RUN/splash-tampered" "$TPIN" "$PWD/child/req-splash.bin" 1 "exit=70 spawn rc=16 .*suspended=0x23011311 .*sealed spawn refused, code 16"
lrun broken-sig "$RUN/splash-broken" "$GOOD" "$PWD/child/req-splash.bin" 1 "exit=70 spawn rc=20 .*sealed spawn refused, code 20"

# 7. R7-T3 (2026-10-22, review/R7T3-2026-10-22.md): read-back of the start
#    state (exception ports, signal dispositions, sandbox, rlimits,
#    credentials) after the Metal device and the model load, before "loaded".
#    The release-equivalent read-back build and the static-initializer control
#    load. Each seeded change after the load is refused by the read-back with
#    its class named. The interposer build loads and counts its own seeded
#    calls. The crash arm runs after the load (A-20 harness of run-tee.sh).
#    The full run (requests, busy-poll, end self-test) is neg/run-r7t3.sh.
UTMP=$(getconf DARWIN_USER_TEMP_DIR); UTMP=${UTMP%/}
printf 'R7-CANARY\n' > "$UTMP/r7-canary.txt"   # the read-back's canary; build-r7-seed-ext's extension names it
SGRP=$(id -Gn | tr ' ' '\n' | grep -vx "$(id -gn)" | head -1)   # a second group of this user, for the set-ID seed
r7c() {  # r7c <tag> <build folder> <proof ERE> <expected ERE> [setid|interpose]
  local E="$RUN/r7-$2/splash"
  mkdir -p "$RUN/r7-$2" && printf 'r5 owndir probe\n' > "$RUN/r7-$2/r5-owndir-probe" && cp splash/$2/splash "$E"
  if [ "$5" = interpose ]; then
    cp neg/R7/libr7interpose.dylib "$RUN/r7-$2/"
    codesign -f -s - --options runtime --entitlements neg/R7/dlv.entitlements -i sealed.splash "$E" 2>/dev/null
  else sign "$E"; fi
  [ "$5" = setid ] && chgrp "$SGRP" "$E" && chmod g+s "$E"
  rm -f /tmp/sealed-reason.log
  local L H; L=$(neg/B/r2neg "$E" "$PKG" control 2>&1 | tail -1)
  H=$(grep -E '^(test: r7|r7: (CHANGED|check after-load)|r7i: hit)' /tmp/sealed-reason.log 2>/dev/null | sed "s#$PWD/##g" | paste -sd ';' - | cut -c1-4000)
  record "$1" "^\[x\] .*$3.* \|\| $4" "[x] $H || ${L#*] }"
}
r7c R7-readback-load build-r7 "r7: check after-load PASS" "${LOADED}"
r7c R7-static-init build-r7-static "test: r7 static initializer set task port kr=0 port=0x[0-9a-f]+; present after the guard=0;r7: check after-load PASS" "${LOADED}"
r7c R7-seed-signal build-r7-seed-signal "test: r7 seed signal-handler at load now.*r7: CHANGED point=[^ ]+ class=signal-disposition SIGSEGV[(]11[)]" "${REFUSED}${P}"
r7c R7-seed-taskport build-r7-seed-taskport "test: r7 seed task-port at load now.*r7: CHANGED point=[^ ]+ class=exception-ports task: sealed_guard_readback=3" "${REFUSED}${P}"
r7c R7-seed-threadport build-r7-seed-threadport "test: r7 seed thread-port set kr=0;r7: CHANGED point=[^ ]+ class=exception-ports thread-ports: thread" "${REFUSED}${P}"
r7c R7-seed-ext build-r7-seed-ext "test: r7 extension issued=yes.*test: r7 seed extension-consume handle=[0-9]+;r7: CHANGED point=[^ ]+ class=sandbox sandbox_check arm 2 [(]file-read-data[)] = 0, start 1" "${REFUSED}${P}"
r7c R7-seed-setid build-r7-seed-setid "setuid[(]0[)] rc=-1 errno=1;test: r7 seed set-id setgid[(][0-9]+[)] rc=0 errno=0;r7: CHANGED point=[^ ]+ class=credentials" "${REFUSED}${P}" setid
# Interposer build: its three seeded calls (control iii) are counted with the
# child as the caller, and no port or fatal-signal call is counted through
# the load (checked by the runner below the record line).
r7c R7-interposer-load build-r7-interpose "r7i: hit seq=.*name=seed-begin .*name=sigaction kind=2 arg=11 ret=0 .*caller=neg/run/r7-build-r7-interpose/splash.*name=thread_set_exception_ports kind=1 .*name=sandbox_extension_consume kind=3 .*name=seed-end.*r7: check after-load PASS" "${LOADED}" interpose
H=$(grep '^r7i: hit' /tmp/sealed-reason.log 2>/dev/null | sed -n '/name=seed-end/,$p' | grep -cE 'kind=1 |kind=2 arg=(3|4|5|6|7|8|10|11|12|24|25) ')
record "R7-interposer-load-no-port-or-fatal-signal-call" "^\[x\] 0 " "[x] $H port or fatal-signal calls counted after the seeded calls, through the load"
# Crash arm after the load (A-20): canary in registers, then brk, after the
# Metal device, the load, the latch and the self-audit, before "loaded".
crash7() {  # crash7 <tag> <build folder> -> "<reports> <with canary> <r2neg line>"
  cp splash/$2/splash "$RUN/splash-$2" && sign "$RUN/splash-$2"
  touch "$RUN/t0.$1"
  rm -f /tmp/sealed-reason.log
  local L; L=$(neg/B/r2neg "$RUN/splash-$2" "$PKG" control 2>&1 | tail -1)
  sleep 20   # ReportCrash writes the report after the process dies
  local hits=0 reports=0 f
  for f in $(find ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports -newer "$RUN/t0.$1" -type f 2>/dev/null); do
    case "$f" in *splash*) reports=$((reports + 1)); grep -q -i -e "5445454341524159" -e "6072335827740016985" "$f" && hits=$((hits + 1));; esac
  done
  echo "reports=$reports with-canary=$hits | ${L#*] }"
}
L=$(crash7 crash-postload-nor1 build-r7-crash-postload-nor1)
record "R7-crash-postload-control-no-guard" "^\[x\] reports=[1-9][0-9]* with-canary=[1-9][0-9]* \| exit=-5 first byte S, then 4 bytes: 534c5342" "[x] $L"
L=$(crash7 crash-postload build-r7-crash-postload)
record "R7-crash-postload-with-guard" "^\[x\] reports=0 with-canary=0 \| exit=113 first byte S, then 4 bytes: 534c5342" "[x] $L"
rm -f "$UTMP/r7-canary.txt"

# Chunked KV production hygiene (2026-10-23): no test strings, no MTL4 queue,
# no shared event, no sparse mapping update and no IOSurface import in the
# production child. The control is the chunk-notes test build, whose test
# strings the same count must find.
hyg() {  # hyg <binary> -> counts
  echo "SEALED_TEST=$(strings -a "$1" | grep -c SEALED_TEST) test=$(strings -a "$1" | grep -c 'test: ') ckv=$(strings -a "$1" | grep -c 'test: ckv') newMTL4CommandQueue=$(strings -a "$1" | grep -c newMTL4CommandQueue) newSharedEvent=$(strings -a "$1" | grep -c newSharedEvent) updateBufferMappings=$(strings -a "$1" | grep -c updateBufferMappings) IOSurfaceRootUserClient=$(strings -a "$1" | grep -c IOSurfaceRootUserClient) iosurface_imports=$(nm -u "$1" | grep -ci iosurface)"
}
rm -f /tmp/sealed-reason.log
record CKV-production-hygiene "^\[x\] SEALED_TEST=0 test=0 ckv=0 newMTL4CommandQueue=0 newSharedEvent=0 updateBufferMappings=0 IOSurfaceRootUserClient=0 iosurface_imports=0 \|" "[x] $(hyg splash/build/splash)"
record CKV-hygiene-control-notes-build "^\[x\] SEALED_TEST=[0-9]+ test=[1-9][0-9]* ckv=[1-9]" "[x] $(hyg splash/build-ckv-notes/splash)"

rm -rf "$RUN" /tmp/sealed-reason.log
echo "# result: $fails failed" >> $O
cat $O
[ $fails = 0 ]
