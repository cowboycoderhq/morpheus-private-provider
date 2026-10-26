#!/bin/bash
# Prints the App Attest app ID (<TEAM>.<bundle id>) of a signed engine bundle.
# The scripts read it here so that no app ID is written in the source.
set -eu
APP=${1:-build/SealedEngineV2.app}
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | python3 -c 'import plistlib,sys; print(plistlib.loads(sys.stdin.buffer.read())["com.apple.application-identifier"])'
