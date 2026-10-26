#!/bin/bash
# Reproducibility check for the sealed Splash child (its CD hash is the pin
# compiled into the engine). Builds the production child from two copies of
# the source in different folders, signs each ad-hoc the way stage-child.sh
# does, and compares bytes and CD hashes. The second copy builds with a
# different HOME, so a home-folder path in the build shows as a difference
# (audit R2-4-02).
# Usage: scripts/child-repro-check.sh <splash source folder>
set -u
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SRC=$(cd "$1" && pwd -P)
xcrun -sdk macosx metal --version > /dev/null 2>&1   # mounts the Metal toolchain
OTHER_HOME=/tmp/child-repro-home
rm -rf "$OTHER_HOME"; mkdir -p "$OTHER_HOME"
for d in /tmp/child-repro-a /tmp/child-repro-bb; do
  rm -rf "$d"; mkdir -p "$d"
  h=$HOME; [ "$d" = /tmp/child-repro-bb ] && h=$OTHER_HOME
  rsync -a --exclude '/build' --exclude '/build-*' "$SRC/" "$d/"
  (cd "$d" && HOME=$h BENCH_OK=1 make -j6 SEALED_DEFS=-DSPLASH_SEALED > build.log 2>&1) || { echo "build failed in $d"; tail -5 "$d/build.log"; exit 1; }
  cp "$d/build/splash" "$d/splash.signed"
  codesign -f -s - --options runtime -i sealed.splash "$d/splash.signed" 2>/dev/null
done
A=/tmp/child-repro-a; B=/tmp/child-repro-bb
shasum -a 256 $A/build/splash $B/build/splash
pa=$(codesign -dvvv $A/splash.signed 2>&1 | awk -F= '/^CDHash=/{print $2}'); pb=$(codesign -dvvv $B/splash.signed 2>&1 | awk -F= '/^CDHash=/{print $2}')
echo "HOME a=$HOME b=$OTHER_HOME"
echo "CD hash a=$pa b=$pb"
if cmp -s $A/build/splash $B/build/splash; then echo "SAME: the child executable does not depend on the build folder"
else echo "DIFFERENT: $(cmp -l $A/build/splash $B/build/splash 2>&1 | wc -l | tr -d ' ') bytes differ"; fi
