#!/bin/bash
# A-4 one-command finish. After you download the provisioning profile from Apple:
#   tools/tee-rootkit/a4/a4-run.sh /path/to/profile.provisionprofile <bundle-id>
# It builds the client as an app bundle, embeds the profile, signs it with the
# Apple Development identity in SEALED_SIGN_IDENTITY, checks the entitlement is in the signature, then
# runs the Endpoint Security arm. PASS means es_new_client ran and returned
# a result (any result) instead of AMFI killing the process at launch.
set -u
PROFILE=${1:-}
BUNDLE=${2:-}
[ -f "$PROFILE" ] && [ -n "$BUNDLE" ] || { echo "usage: SEALED_SIGN_IDENTITY=<identity> $0 <profile.provisionprofile> <bundle-id>"; exit 2; }
KIT=$(cd "$(dirname "$0")" && pwd)
CLIENT_SRC="$KIT/../esclient.c"
[ -f "$CLIENT_SRC" ] || CLIENT_SRC=$(ls "$KIT"/../*esclient*.c 2>/dev/null | head -1)
[ -f "$CLIENT_SRC" ] || { echo "STOP: esclient source not found"; exit 2; }
IDENT=${SEALED_SIGN_IDENTITY:?set SEALED_SIGN_IDENTITY to the Apple Development identity}
BUILD="$KIT/build"
APP="$BUILD/ESVerify.app"
rm -rf "$BUILD"; mkdir -p "$APP/Contents/MacOS"
cp "$CLIENT_SRC" "$BUILD/esclient.m"
clang -fobjc-arc -framework Foundation -framework EndpointSecurity \
  -o "$APP/Contents/MacOS/ESVerify" "$BUILD/esclient.m" || exit 1
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ESVerify</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE</string>
  <key>CFBundleName</key><string>ESVerify</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
codesign --force --options runtime --timestamp --sign "$IDENT" \
  --entitlements "$KIT/esclient.entitlements" \
  --generate-entitlement-der "$APP" || { echo "STOP: codesign failed"; exit 1; }
echo "-- signed entitlements:"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -A1 endpoint || echo "MISSING entitlement"
echo "-- running the arm (10 s limit):"
OUT=$(mktemp)
"$APP/Contents/MacOS/ESVerify" >"$OUT" 2>&1 &
PID=$!
sleep 10; kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
RC=$?
cat "$OUT"
if grep -q "es_new_client result=" "$OUT"; then
  echo "RESULT: PASS (es_new_client ran; extension client API answered)"
elif [ "$RC" -ge 128 ] || [ "$RC" = 137 ]; then
  echo "RESULT: FAIL (AMFI killed the process, exit $RC) — profile or entitlement mismatch"
else
  echo "RESULT: INCONCLUSIVE (exit $RC; see output above)"
fi
