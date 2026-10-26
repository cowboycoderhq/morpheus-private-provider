#!/bin/bash
# Copies the built sealed Splash child to child/, signs it (hardened runtime,
# ad-hoc), writes its launch requirement, and prints the pin.
set -eu
cd "$(dirname "$0")"
rm -f child/splash child/splash.metallib
# Optional argument: another build folder (test builds only). Without it, the
# production child is built from a clean copy of splash/ with Xcode, so no
# object from another toolchain or an older build can enter it (audit R5-4-03).
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
if [ -n "${1:-}" ]; then
  cp "splash/$1/splash" child/splash
else
  C=$(mktemp -d /tmp/stage-child.XXXXXX)
  rsync -a --exclude '/build' --exclude '/build-*' splash/ "$C/"
  (cd "$C" && make -j8 SEALED_DEFS=-DSPLASH_SEALED > build.log 2>&1) || { echo "clean build failed: $C/build.log"; exit 1; }
  (cd "$C" && make -s check-build-identity SEALED_DEFS=-DSPLASH_SEALED > /dev/null) || { echo "build identity check failed"; exit 1; }
  cp "$C/build/splash" child/splash
  rm -rf "$C"
fi
codesign -f -s - --options runtime -i sealed.splash child/splash 2>/dev/null
# R5 self-test probe (review S5): an unnamed file in the child's folder that
# the profile must refuse with EPERM. The child refuses to start without it.
printf 'r5 owndir probe\n' > child/r5-owndir-probe
PIN=$(codesign -dvvv child/splash 2>&1 | awk -F= '/^CDHash=/{print $2}')
tools/reqgen child/splash "$PIN" dummy child/req-splash.bin >/dev/null
echo "$PIN" > child/pin.txt
echo "pin=$PIN"
