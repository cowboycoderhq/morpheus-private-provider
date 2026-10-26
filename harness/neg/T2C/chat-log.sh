#!/bin/bash
# T2 client-need check (2026-10-23): one chat request through the engine
# (neg/T2F/chat-arm.sh: server.py, sealed-launch, the test child pinned by its
# own CD hash) with the kernel log stream recording every
# IOSurfaceRootUserClient open attempt. Raw files: neg/T2C/run/chat-<tag>/.
# usage: neg/T2C/chat-log.sh <build-folder> <tag>   (prints the chat line)
cd "$(dirname "$0")/../.."
B=$1; TAG=${2:-$1}
D=$PWD/neg/T2C/run/chat-$TAG
rm -rf "$D"; mkdir -p "$D"
/usr/bin/log stream --style compact --predicate 'eventMessage CONTAINS "IOSurfaceRootUserClient"' > "$D/kernel.log" 2>&1 &
LP=$!
sleep 2
neg/T2F/chat-arm.sh "$B" "t2c-$TAG" > "$D/chat.txt" 2>&1
sleep 2
kill $LP 2>/dev/null; wait $LP 2>/dev/null
cp -R "$PWD/neg/T2F/run/t2c-$TAG/." "$D/" && rm -rf "$PWD/neg/T2F/run/t2c-$TAG"
rm -f "$D/splash"   # the binary is splash/$B/splash; keep only the records
head -1 "$D/chat.txt"
