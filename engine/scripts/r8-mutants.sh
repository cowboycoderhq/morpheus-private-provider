#!/bin/bash
# R8 profile mutants: each test build adds one broad allowance to the profile
# (SEALED_R8_TEST_ALLOW_*). The self-test must refuse to serve, naming an arm.
# Usage: scripts/r8-mutants.sh <provisioning profile> <signing identity> [port]
cd "$(dirname "$0")/.."
PROFILE=$1; IDENT=${2:?signing identity required}; PORT=${3:-29455}
fails=0
for m in ALLOW_WRITE ALLOW_NET ALLOW_LOOKUP ALLOW_EXEC; do
  D=build/r8-m-$m
  R8_TEST_DEFINE=SEALED_R8_TEST_$m APP_DIR=$D scripts/bundle.sh "$PROFILE" "$IDENT" > "$D.build.log" 2>&1 || { echo "FAIL [$m] build"; fails=$((fails+1)); continue; }
  scripts/r8-start.sh "$D" "$PORT" > /dev/null 2>&1
  r=$(grep -m1 "sandbox refused" "$D/engine.log")
  if [ -n "$r" ] && ! grep -q listening "$D/engine.log"; then echo "PASS [$m] $r"; else echo "FAIL [$m] served: $(tail -1 "$D/engine.log")"; fails=$((fails+1)); fi
  sleep 2
  pgrep -f "$(cd "$D" && pwd -P)/SealedEngineV2.app" > /dev/null && { echo "FAIL [$m] engine still runs"; fails=$((fails+1)); }
done
echo "# mutants: $fails failed"
exit $fails
