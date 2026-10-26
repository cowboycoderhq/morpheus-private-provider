#!/bin/bash
# Builds the TEE root kit as the operator user (nothing compiles at root
# time) and writes SHA256SUMS, which the root script checks first.
# Usage: tools/tee-rootkit/build.sh
set -eu
cd "$(dirname "$0")"
clang -O2 -o taskports taskports.c && codesign -f -s - taskports 2>/dev/null
clang -O2 -o ctlproc ctlproc.c && codesign -f -s - ctlproc 2>/dev/null          # unhardened control
clang -O2 -lEndpointSecurity -o esclient esclient.c
codesign -f -s - --entitlements es.entitlements esclient 2>/dev/null
clang -O2 -fobjc-arc -framework Metal -framework Foundation -o waitclient waitclient.m && codesign -f -s - waitclient 2>/dev/null
rm -rf fake/MTLCompilerService.xpc
mkdir -p fake/MTLCompilerService.xpc/Contents/MacOS
clang -O2 -o fake/MTLCompilerService.xpc/Contents/MacOS/MTLCompilerService fakecompiler.c
cat > fake/MTLCompilerService.xpc/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.apple.MTLCompilerService</string>
<key>CFBundleExecutable</key><string>MTLCompilerService</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleName</key><string>MTLCompilerService</string>
<key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
EOF
codesign -f -s - fake/MTLCompilerService.xpc 2>/dev/null
rm -rf fake/TEEFakeCtl.xpc; mkdir -p fake/TEEFakeCtl.xpc/Contents/MacOS
cp fake/MTLCompilerService.xpc/Contents/MacOS/MTLCompilerService fake/TEEFakeCtl.xpc/Contents/MacOS/TEEFakeCtl
sed -e 's/com.apple.MTLCompilerService/com.tee.fakectl/' -e 's/<string>MTLCompilerService</<string>TEEFakeCtl</g' \
  fake/MTLCompilerService.xpc/Contents/Info.plist > fake/TEEFakeCtl.xpc/Contents/Info.plist
codesign -f -s - fake/TEEFakeCtl.xpc 2>/dev/null
# P10 arms: the consumer client and the engine identity it checks.
(cd ~/projects/morpheus-pnode/proxy-router && BENCH_OK=1 go build -o "$OLDPWD/sealed-chat" ./cmd/sealed-chat)
EAPP=~/projects/morpheus-pnode/sealed-engine-v2/build/SealedEngineV2.app
codesign -d --verbose=4 "$EAPP" 2>&1 | awk -F'sha256=' '/CandidateCDHashFull sha256=/{print $2}' > engine-cdhash
~/projects/morpheus-pnode/sealed-engine-v2/scripts/app-id.sh "$EAPP" > engine-appid
grep -q . engine-appid || { echo "cannot read the engine app ID"; exit 1; }
python3 ~/projects/morpheus-pnode/sealed-engine-v2/scripts/model-hash.py ~/projects/sealed-backends-spike/sealed-m5/pkg/qwen38-27b "$(cat ../../child/pin.txt)" | awk '/^model/{print $2}' > engine-modelhash
cat > dtrace-read.d <<'EOF'
/* Counts read() calls of $1 and tries to copy the first bytes of each buffer. */
syscall::read:entry, syscall::read_nocancel:entry /pid == $1/ { self->buf = arg1; }
syscall::read:return, syscall::read_nocancel:return /pid == $1 && self->buf && arg0 > 0/
{ printf("COPY %d %s\n", arg0, copyinstr(self->buf, 24)); self->buf = 0; }
EOF
# SHA256SUMS covers every file grant-agent-sudo.sh installs, the root script
# included (kept here as a copy so the list checks in both layouts). The list
# is written fresh each run, so a rebuild with no changes gives the same file.
cp ../tee-rootpass.sh tee-rootpass.sh
FILES="tee-rootpass.sh taskports ctlproc esclient waitclient fake/MTLCompilerService.xpc/Contents/MacOS/MTLCompilerService fake/MTLCompilerService.xpc/Contents/Info.plist fake/TEEFakeCtl.xpc/Contents/MacOS/TEEFakeCtl fake/TEEFakeCtl.xpc/Contents/Info.plist dtrace-read.d sealed-chat engine-cdhash engine-appid engine-modelhash"
for d in fake/MTLCompilerService.xpc fake/TEEFakeCtl.xpc; do
  [ -f "$d/Contents/_CodeSignature/CodeResources" ] && FILES="$FILES $d/Contents/_CodeSignature/CodeResources"
done
shasum -a 256 $FILES > SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS
cat SHA256SUMS
