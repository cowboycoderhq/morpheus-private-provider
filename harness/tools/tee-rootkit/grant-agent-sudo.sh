#!/bin/bash
# Lets an agent (for example a GLM 5.3 subagent) run the TEE root pass
# without a password, and nothing else as root.
#
# What it does (operator runs it once with sudo):
#   1. Copies tools/tee-rootpass.sh and the built kit into
#      /usr/local/libexec/tee-rootkit, owned by root:wheel, not writable by
#      the user, so the agent cannot change what runs as root.
#   2. Adds /etc/sudoers.d/tee-rootkit with ONE line: the user may run
#      exactly "/usr/local/libexec/tee-rootkit/tee-rootpass.sh --yes" as
#      root without a password. visudo checks the file first.
# Remove it again:  sudo tools/tee-rootkit/grant-agent-sudo.sh --remove
#
# Usage: sudo tools/tee-rootkit/grant-agent-sudo.sh --yes
set -eu
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 64; }
U=${SUDO_USER:?run through sudo}
D=/usr/local/libexec/tee-rootkit
S=/etc/sudoers.d/tee-rootkit
case "${1:-}" in
  --remove) rm -f "$S"; rm -rf "$D"; echo "removed $S and $D"; exit 0 ;;
  --yes) ;;
  *) echo "read the header, then run: sudo $0 --yes   (or --remove)"; exit 64 ;;
esac
SRC=$(cd "$(dirname "$0")" && pwd -P)
(cd "$SRC" && shasum -a 256 -c SHA256SUMS) || { echo "kit hashes differ; run tools/tee-rootkit/build.sh as $U first"; exit 70; }
rm -rf "$D"
install -d -o root -g wheel -m 755 "$D" "$D/fake" "$D/fake/MTLCompilerService.xpc" \
  "$D/fake/MTLCompilerService.xpc/Contents" "$D/fake/MTLCompilerService.xpc/Contents/MacOS"
for f in taskports ctlproc esclient waitclient; do install -o root -g wheel -m 755 "$SRC/$f" "$D/$f"; done
install -o root -g wheel -m 755 "$SRC/fake/MTLCompilerService.xpc/Contents/MacOS/MTLCompilerService" "$D/fake/MTLCompilerService.xpc/Contents/MacOS/"
install -o root -g wheel -m 644 "$SRC/fake/MTLCompilerService.xpc/Contents/Info.plist" "$D/fake/MTLCompilerService.xpc/Contents/"
[ -d "$SRC/fake/MTLCompilerService.xpc/Contents/_CodeSignature" ] && cp -R "$SRC/fake/MTLCompilerService.xpc/Contents/_CodeSignature" "$D/fake/MTLCompilerService.xpc/Contents/" && chown -R root:wheel "$D/fake"
install -d -o root -g wheel -m 755 "$D/fake/TEEFakeCtl.xpc/Contents/MacOS"
install -o root -g wheel -m 755 "$SRC/fake/TEEFakeCtl.xpc/Contents/MacOS/TEEFakeCtl" "$D/fake/TEEFakeCtl.xpc/Contents/MacOS/"
install -o root -g wheel -m 644 "$SRC/fake/TEEFakeCtl.xpc/Contents/Info.plist" "$D/fake/TEEFakeCtl.xpc/Contents/"
[ -d "$SRC/fake/TEEFakeCtl.xpc/Contents/_CodeSignature" ] && cp -R "$SRC/fake/TEEFakeCtl.xpc/Contents/_CodeSignature" "$D/fake/TEEFakeCtl.xpc/Contents/" && chown -R root:wheel "$D/fake"
install -o root -g wheel -m 644 "$SRC/dtrace-read.d" "$SRC/SHA256SUMS" "$SRC/engine-cdhash" "$SRC/engine-appid" "$SRC/engine-modelhash" "$D/"
install -o root -g wheel -m 755 "$SRC/sealed-chat" "$D/sealed-chat"
install -o root -g wheel -m 755 "$SRC/../tee-rootpass.sh" "$D/tee-rootpass.sh"
(cd "$D" && shasum -a 256 -c SHA256SUMS) > /dev/null || { echo "installed copy does not match"; rm -rf "$D"; exit 70; }
T=$(mktemp)
echo "$U ALL=(root) NOPASSWD: $D/tee-rootpass.sh --yes" > "$T"
visudo -cf "$T" > /dev/null || { echo "sudoers line failed visudo"; rm -f "$T"; exit 70; }
install -o root -g wheel -m 440 "$T" "$S"; rm -f "$T"
echo "installed $D (root-owned), script sha256 $(shasum -a 256 "$D/tee-rootpass.sh" | cut -c1-16)"
echo "sudoers: $(cat "$S")"
echo "the agent runs: sudo -n $D/tee-rootpass.sh --yes"
echo "remove later:   sudo $0 --remove"
