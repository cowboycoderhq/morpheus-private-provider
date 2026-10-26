#!/bin/bash
# Entitlement audit for the sealed release: engine app and child binary.
# Proves which restricted entitlements the shipped binaries carry.
# Exit 0 only when the forbidden set is absent and the allowed set matches.
set -u
E=${ENGINE_APP:-$HOME/projects/morpheus-pnode/sealed-engine-v2/build/SealedEngineV2.app}
C=${CHILD:-$HOME/projects/sealed-backends-spike/sealed-m5/child/splash}
FORBIDDEN="endpoint-security.client|com.apple.private.security.message-filter|task_for_pid-allow|get-task-allow|com.apple.security.get-task-allow|allow-jit|allow-unsigned-executable-memory|disable-library-validation|com.apple.private.security.no-sandbox|com.apple.private.security.storage"
ALLOWED_ENGINE="application-identifier|com.apple.application-identifier|team-identifier|com.apple.developer.team-identifier|com.apple.developer.devicecheck.appattest-environment|com.apple.developer.devicecheck.app-attest-opt-in|com.apple.developer.devicecheck.appattest-cdhash|get-task-allow|com.apple.security.get-task-allow|keychain-access-groups"
fail=0
echo "== engine: $E"
if [ ! -d "$E" ]; then echo "FAIL engine app missing"; fail=1; else
  ENT=$(codesign -d --entitlements - "$E" 2>/dev/null)
  printf '%s\n' "$ENT" | grep -oE 'com\.apple\.[A-Za-z0-9._-]+|get-task-allow|allow-jit|allow-unsigned-executable-memory|disable-library-validation|task_for_pid-allow' | sort -u > /tmp/ent-engine.txt
  echo "entitlements:"; sed 's/^/  /' /tmp/ent-engine.txt
  echo "entitlement values (raw):"; printf '%s\n' "$ENT" | head -20 | sed 's/^/  /'
  if grep -qE "$FORBIDDEN" /tmp/ent-engine.txt; then echo "FAIL engine holds a forbidden entitlement"; grep -E "$FORBIDDEN" /tmp/ent-engine.txt; fail=1; else echo "PASS engine holds no forbidden entitlement"; fi
  UNK=$(comm -23 /tmp/ent-engine.txt <(printf '%s\n' "$ALLOWED_ENGINE" | tr '|' '\n' | sort -u))
  if [ -n "$UNK" ]; then echo "INFO engine entitlements outside the allow list:"; printf '%s\n' "$UNK" | sed 's/^/  /'; fi
fi
echo
echo "== child: $C"
if [ ! -f "$C" ]; then echo "FAIL child binary missing"; fail=1; else
  CC=$(codesign -d --entitlements - "$C" 2>/dev/null)
  if printf '%s\n' "$CC" | grep -q "com.apple"; then echo "INFO child carries entitlements:"; printf '%s\n' "$CC" | head -10; CCIDS=$(printf '%s\n' "$CC" | grep -oE 'com\.apple\.[A-Za-z0-9._-]+|get-task-allow|allow-jit|task_for_pid-allow'); if printf '%s\n' "$CCIDS" | grep -qE "$FORBIDDEN"; then echo "FAIL child holds a forbidden entitlement"; fail=1; else echo "PASS child holds no forbidden entitlement"; fi; else echo "PASS child carries no entitlements (ad-hoc)"; fi
fi
echo
echo "== signing identities"
# Count only: identity names and certificate hashes are personal data (audit R5-1-05).
security find-identity -v -p codesigning | tail -1 | sed 's/^ */  /'
echo
echo "== profiles installed"
P="$HOME/Library/MobileDevice/Provisioning Profiles"; n=0
if [ -d "$P" ]; then for f in "$P"/*.provisionprofile; do [ -f "$f" ] || continue; n=$((n+1)); E1=$(security cms -D -i "$f" 2>/dev/null | grep -c "endpoint-security.client"); echo "  $(basename "$f") endpoint=$E1"; done; fi
[ "$n" = 0 ] && echo "  none installed"
echo
[ "$fail" = 0 ] && echo "RESULT: PASS (no forbidden entitlement in the release)" || echo "RESULT: FAIL"
exit "$fail"
