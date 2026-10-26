#!/bin/bash
# Runs the staged child directly on a package copy; prints the first sealed-r6
# line or READY. Usage: run-neg.sh <tag> <package dir>
cd "$(dirname "$0")/../.."
T=$1; PKGD=$2
( sleep 40 ) | env -i HOME=$(mktemp -d) TMPDIR=$(mktemp -d) child/splash serve-native "$PKGD/target" "$PKGD/draft" 8192 auto > neg/A/$T.out 2> neg/A/$T.err &
P=$!; ( sleep 60; kill -9 $P 2>/dev/null ) & W=$!; wait $P; RC=$?; kill $W 2>/dev/null
R=$(grep -m1 -E "sealed-r6: [^T]|sealed: " neg/A/$T.err | cut -c1-200)
if head -c 5 neg/A/$T.out | grep -q "SPLH"; then READY=1; elif head -c 5 neg/A/$T.out | tail -c 4 | grep -q SPLH; then READY=1; else READY=0; fi
echo "[$T] exit=$RC ready=$READY | $R"
