#!/bin/bash
# Builds SealedEngineV2.app: the release engine binary, Info.plist, the App
# Attest entitlement (CD-hash opt-in), the provisioning profile, hardened
# runtime, signed with the Apple Development identity.
#
# Usage: scripts/bundle.sh <provisioning profile> <signing identity>
#        MODE=verify scripts/bundle.sh <provisioning profile>
#        MODE=verify SEALED_APPID=<TEAM>.<bundle id> scripts/bundle.sh -
#   verify: the unsigned rebuild a third party compares with the published
#   app (`sealed-verify rebuild`): no profile, no signature.
# The executable is named SealedEngine, the name the compare tool expects.
# The profile's app ID decides the bundle id. A verify build needs only the
# app ID, so a third party without the profile passes SEALED_APPID and "-".
set -eu
cd "$(dirname "$0")/.."
PROFILE=$1
IDENT=${2:-}
# ATTEST_ENV=development adds the App Attest environment entitlement. The
# profile must allow it: with the provisioned profile on this Mac, AMFI kills
# the signed app at launch (exit 137, measured 2026-10-20).
ATTEST_ENV=${ATTEST_ENV:-}
if [ "$PROFILE" = - ]; then
  [ "${MODE:-sign}" = verify ] || { echo "a signed build needs the provisioning profile"; exit 1; }
  APPID=${SEALED_APPID:?set SEALED_APPID=<TEAM>.<bundle id> for a verify build without a profile}
else
  T=$(mktemp); security cms -D -i "$PROFILE" > "$T"
  APPID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$T")
  /usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.devicecheck.app-attest-opt-in" "$T" | grep -q CDhash \
    || { echo "profile has no App Attest CD-hash opt-in"; exit 1; }
  rm -f "$T"
fi
TEAM=${APPID%%.*}; BUNDLE_ID=${APPID#*.}
[ "${MODE:-sign}" = verify ] || [ -n "$IDENT" ] || { echo "a signed build needs the signing identity (argument 2)"; exit 1; }
# Xcode's toolchain and macOS 27 SDK (CommandLineTools builds against an older SDK).
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
MODE=${MODE:-sign}
# APP_DIR: another output folder (R8 test copies, while an engine runs from build/).
APP=${APP_DIR:-build}/SealedEngineV2.app
[ "$MODE" = verify ] && APP=${APP_DIR:-build/verify}/SealedEngineV2.app
scripts/build-reproducible.sh "build/SealedEngine.$MODE"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "build/SealedEngine.$MODE" "$APP/Contents/MacOS/SealedEngine"
[ "$MODE" = verify ] || cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SealedEngine</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>SealedEngineV2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>LSUIElement</key><true/>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>DTPlatformName</key><string>macosx</string>
<key>DTSDKName</key><string>macosx$(xcrun --sdk macosx --show-sdk-version)</string>
</dict></plist>
EOF
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > build/engine.entitlements <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.application-identifier</key><string>$APPID</string>
<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
<key>com.apple.developer.devicecheck.app-attest-opt-in</key><array><string>CDhash</string></array>
$( [ -n "$ATTEST_ENV" ] && echo "<key>com.apple.developer.devicecheck.appattest-environment</key><string>$ATTEST_ENV</string>" )
</dict></plist>
EOF
if [ "$MODE" = verify ]; then echo "verify bundle: $APP (unsigned)"; exit 0; fi
codesign -f -s "$IDENT" --options runtime --entitlements build/engine.entitlements --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E "^Identifier|^CDHash=|flags=|^TeamIdentifier"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -E "app-attest|application-identifier" -A1 | head -6
