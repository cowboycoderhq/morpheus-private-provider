#!/bin/bash
# Second-Mac, second-user rebuild of the pins named in ref/ (R4-4-01).
# Builds the child and the engine from the copied source (git archive of the
# commits named in src/*_COMMIT.txt) as this user, with this user's HOME, and
# compares with the M5 reference. Writes results-<stamp>.txt.
# Usage: bash <folder>/rebuild.sh (the folder holds src/, ref/ and MANIFEST.sha256)
# ref/ holds child-pin.txt, child-unsigned-sha256.txt, engine-cdhash.txt,
# engine-appid.txt, sealed-verify and the published SealedEngineV2.app.
set -u
R=$(cd "$(dirname "$0")" && pwd)
T=$HOME/sealed-rebuild-2026-10-21/toolchain/Xcode.app/Contents/Developer
export DEVELOPER_DIR=$T
# No metal shim: the real xcrun passes the SDK to metal, so each AIR file
# carries the "SDK Version" module flag, as on the M5. Without it, every
# kernel object differs (measured 2026-10-25).
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
O=$R/results-$(date +%F-%H%M%S).txt
fails=0
v() { [ "$1" = FAIL ] && fails=$((fails + 1)); echo "$1 [$2] $3"; }
{
echo "# second Mac $(sysctl -n hw.model) macOS $(sw_vers -productVersion) uid=$(id -u) $(date -u '+%F %TZ')"
echo "# toolchain $(xcodebuild -version 2>&1 | tr '\n' ' ') metal=$(xcrun -sdk macosx metal --version 2>&1 | head -1)"
echo "# splash commit $(cat $R/src/SPLASH_COMMIT.txt) engine commit $(cat $R/src/ENGINE_COMMIT.txt)"
echo "# expect child pin $(cat $R/ref/child-pin.txt) engine $(cat $R/ref/engine-cdhash.txt)"
( cd "$R" && shasum -a 256 -c MANIFEST.sha256 > /dev/null 2>&1 ) && v PASS manifest "all copied files match MANIFEST.sha256" || v FAIL manifest "copied files differ"

# Child: fresh folder, production flags, ad-hoc sign the way stage-child.sh does.
D=$R/child-build; rm -rf "$D"; cp -R "$R/src/splash" "$D"
( cd "$D" && make -j6 SEALED_DEFS=-DSPLASH_SEALED > build.log 2>&1 ) || { v FAIL child-build "$(tail -3 "$D/build.log" | tr '\n' ' ')"; }
if [ -f "$D/build/splash" ]; then
  cp "$D/build/splash" "$D/splash.signed"; codesign -f -s - --options runtime -i sealed.splash "$D/splash.signed" 2>/dev/null
  us=$(shasum -a 256 "$D/build/splash" | cut -c1-64); cd_=$(codesign -dvvv "$D/splash.signed" 2>&1 | awk -F= '/^CDHash=/{print $2}')
  echo "child unsigned_sha256=$us build_id=$(grep -o 'src-[0-9a-f]*' "$D/build/engine/BuildIdentity.hpp" | head -1)"
  [ "$us" = "$(cat $R/ref/child-unsigned-sha256.txt)" ] && v PASS child-bytes "unsigned child equals the M5 build ($us)" || v FAIL child-bytes "unsigned child $us, M5 $(cat $R/ref/child-unsigned-sha256.txt)"
  [ "$cd_" = "$(cat $R/ref/child-pin.txt)" ] && v PASS child-cdhash "CD hash $cd_ = the pin in the engine" || v FAIL child-cdhash "CD hash $cd_, pin $(cat $R/ref/child-pin.txt)"
fi

# Engine: unsigned verify rebuild, compared with the published app.
E=$R/engine-build; rm -rf "$E"; cp -R "$R/src/sealed-engine-v2" "$E"
( cd "$E" && MODE=verify SEALED_APPID="$(cat $R/ref/engine-appid.txt)" scripts/bundle.sh - > bundle.log 2>&1 ) || v FAIL engine-build "$(tail -3 "$E/bundle.log" | tr '\n' ' ')"
C=$("$R/ref/sealed-verify" rebuild --published "$R/ref/SealedEngineV2.app" --rebuild "$E/build/verify/SealedEngineV2.app" \
     --app-id "$(cat $R/ref/engine-appid.txt)" --cdhash "$(cat $R/ref/engine-cdhash.txt)" 2>&1)
echo "$C"
echo "$C" | grep -q "^MATCH" && v PASS engine-rebuild "the published app is this source's build on a second Mac, as a second user" || v FAIL engine-rebuild "no match"
echo "# result: $fails failed"
} 2>&1 | tee "$O"
echo "results: $O"
