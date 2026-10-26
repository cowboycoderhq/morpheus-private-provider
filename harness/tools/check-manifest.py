#!/usr/bin/env python3
"""Checks a model package against sealed-manifest.bin: every listed file must
exist with the listed size and SHA-256. The child refuses to load a file that
does not match; this tool lets you check the download before you compute the
model hash.

Usage: check-manifest.py <package root> [sealed-manifest.bin]
Exit 0 when every entry matches.
"""
import hashlib, os, struct, sys

PREFIX = b"sealed-manifest-v2"
ROOTS = {1: "target", 2: "draft", 3: ""}


def main():
    root = sys.argv[1]
    man = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, "sealed-manifest.bin")
    b = open(man, "rb").read()
    if b[:len(PREFIX)] != PREFIX:
        sys.exit("not a sealed manifest (v2)")
    off = len(PREFIX)
    (n,) = struct.unpack_from(">I", b, off); off += 4
    bad = 0
    for _ in range(n):
        tag, plen = struct.unpack_from(">BH", b, off); off += 3
        path = b[off:off + plen].decode(); off += plen
        (size,) = struct.unpack_from(">Q", b, off); off += 8
        want = b[off:off + 32].hex(); off += 32
        rel = os.path.join(ROOTS[tag], path)
        f = os.path.join(root, rel)
        try:
            h = hashlib.sha256()
            got = 0
            with open(f, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk); got += len(chunk)
        except OSError as e:
            print(f"MISSING {rel}: {e.strerror}"); bad += 1; continue
        if got != size or h.hexdigest() != want:
            print(f"DIFFERENT {rel}: size {got} (want {size})"); bad += 1
    if off != len(b):
        sys.exit("trailing bytes after the last entry")
    print(f"{n} entries, {bad} differ")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
