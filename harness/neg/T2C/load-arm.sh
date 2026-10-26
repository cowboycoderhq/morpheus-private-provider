#!/bin/bash
# T2 client-need check (2026-10-23): one load of a test child under the test
# spawner, with the kernel log stream recording every IOSurfaceRootUserClient
# open attempt (the sandbox deny line and the IOUC MACF line).
# usage: neg/T2C/load-arm.sh <build-folder> <tag>   (prints the spawner line;
# raw files in neg/T2C/run/<tag>/)
cd "$(dirname "$0")/../.."
B=$1; TAG=${2:-$1}
D=$PWD/neg/T2C/run/$TAG
rm -rf "$D"; mkdir -p "$D"
E=$D/splash
cp "splash/$B/splash" "$E" || { echo "FAIL load[$TAG]: no build splash/$B/splash"; exit 1; }
printf 'r5 owndir probe\n' > "$D/r5-owndir-probe"
codesign -f -s - --options runtime -i sealed.splash "$E" 2>/dev/null
/usr/bin/log stream --style compact --predicate 'eventMessage CONTAINS "IOSurfaceRootUserClient"' > "$D/kernel.log" 2>&1 &
LP=$!
sleep 2
rm -f /tmp/sealed-reason.log
L=$(R2NEG_POLL_MS=${R2NEG_POLL_MS:-120000} neg/B/r2neg "$E" "$PWD/pkg/qwen38-27b" control 2>&1 | tail -1)
sleep 2
kill $LP 2>/dev/null; wait $LP 2>/dev/null
cp /tmp/sealed-reason.log "$D/child.reason" 2>/dev/null
echo "$L" > "$D/r2neg.txt"
echo "load[$TAG] $L"
