#!/bin/bash
# Reproducible build of the engine executable (the P6 recipe from the v1
# engine: a fixed build path, the same Xcode). The source is copied to
# /private/tmp/sealed-engine-v2-build and built there; the result does not
# depend on where the checkout lives. Measured 2026-10-20: two checkouts in
# different folders give different bytes (Swift trap sites encode the length
# of the absolute source path; -file-prefix-map did not change them), and
# the same bytes once built at this fixed path.
#
# Usage: scripts/build-reproducible.sh [out-file]
#   Links with -no_adhoc_codesign (no signature at all). The published app is
#   this executable signed by codesign, and a third party compares its own
#   rebuild with it (`sealed-verify rebuild`). Measured 2026-10-20: a
#   linker-signed published build and an unsigned rebuild differ in 237 of 407
#   pages (the load commands shift the code); both unsigned, they match.
#   Prints the SHA-256 of the executable and the Xcode build.
set -eu
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SRC=$(cd "$(dirname "$0")/.." && pwd -P)
FIX=/private/tmp/sealed-engine-v2-build
OUT=${1:-$SRC/build/SealedEngineV2.unsigned}
EXTRA="-Xlinker -no_adhoc_codesign"
# R8_TEST_DEFINE: one compile-time test switch (SEALED_R8_TEST_*) for the R8
# measurement and mutant builds; never set for a published build.
[ -n "${R8_TEST_DEFINE:-}" ] && EXTRA="$EXTRA -Xcc -D$R8_TEST_DEFINE"
rm -rf "$FIX"; mkdir -p "$FIX"
rsync -a --exclude .build --exclude build --exclude Spikes "$SRC/" "$FIX/"
(cd "$FIX" && BENCH_OK=1 swift build -c release -Xlinker -S $EXTRA 2>&1 | grep -E "error|Build complete")
mkdir -p "$(dirname "$OUT")"
cp "$FIX/.build/release/SealedEngineV2" "$OUT"
echo "xcode $(xcodebuild -version 2>/dev/null | tr '\n' ' ')swift $(swift --version 2>/dev/null | head -1 | sed 's/.*Swift version \([^ ]*\).*/\1/')"
echo "source $(cd "$SRC" && git rev-parse HEAD 2>/dev/null)$( [ -n "$(cd "$SRC" && git status --porcelain -- . 2>/dev/null)" ] && echo ' (dirty or untracked files)')"
shasum -a 256 "$OUT"
