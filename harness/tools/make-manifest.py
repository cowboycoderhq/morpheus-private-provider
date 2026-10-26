#!/usr/bin/env python3
"""Builds sealed-manifest.bin (R6 file form) for a Splash package.

Input: the record-mode open log (record/opens.log) of a real load of the
UNHARDENED test build, and the package root. Every file the load opened below
the canonical package root becomes an entry; nothing is taken from source.

Tags: 1 = <root>/target, 2 = <root>/draft, 3 = the package root itself (for
Splash: manifest.json, tokenizer/config.json, vision/...).

Usage: make-manifest.py OPENS_LOG PACKAGE_ROOT OUT_FILE
Prints the manifest hash (hash form, backend kind 2 = splash).
"""
import hashlib, os, re, stat, struct, sys

PREFIX = b"sealed-manifest-v2"
KIND_SPLASH = 2
# The child's R6 path rule: components of [A-Za-z0-9._-], no "." or "..".
COMPONENT = re.compile(r"[A-Za-z0-9._-]+")


def check_rel(root, rel):
    """Review N6: refuse what the child refuses, before the manifest is made.
    No symlink in any component, the child's charset, a regular file."""
    parts = rel.split("/")
    if any(p in ("", ".", "..") or not COMPONENT.fullmatch(p) for p in parts):
        sys.exit(f"path outside the R6 charset: {rel}")
    cur = root
    for p in parts:
        cur = os.path.join(cur, p)
        if stat.S_ISLNK(os.lstat(cur).st_mode):
            sys.exit(f"symlink in the package: {cur}")
    if not stat.S_ISREG(os.lstat(cur).st_mode):
        sys.exit(f"not a regular file: {cur}")


def main():
    log, root, out = sys.argv[1], sys.argv[2], sys.argv[3]
    if os.path.realpath(root) != os.path.abspath(root):
        sys.exit("the package root path has a symlink in it; pass the canonical path")
    root = os.path.abspath(root)
    files = set()
    for line in open(log, encoding="utf-8", errors="replace"):
        op, _, path = line.rstrip("\n").partition(" ")
        if op not in ("open", "openat"):
            continue
        if path.startswith(root + "/"):
            rel = path[len(root) + 1:]
            if os.path.isfile(os.path.join(root, rel)):
                files.add(rel)
    if not files:
        sys.exit("no files under the root in the log")
    folded = {}
    for rel in files:
        check_rel(root, rel)
        key = rel.lower()
        if key in folded:
            sys.exit(f"two paths differ only by case: {folded[key]} and {rel}")
        folded[key] = rel
    entries = []
    for rel in files:
        if rel.startswith("target/"):
            tag, path = 1, rel[len("target/"):]
        elif rel.startswith("draft/"):
            tag, path = 2, rel[len("draft/"):]
        else:
            tag, path = 3, rel
        full = os.path.join(root, rel)
        data_hash = hashlib.sha256()
        size = 0
        with os.fdopen(os.open(full, os.O_RDONLY | os.O_NOFOLLOW), "rb") as f:
            while True:
                b = f.read(1 << 24)
                if not b:
                    break
                size += len(b)
                data_hash.update(b)
        if size == 0:
            sys.exit(f"empty file (the child refuses size 0): {rel}")
        entries.append((tag, path.encode(), size, data_hash.digest()))
    entries.sort(key=lambda e: (e[0], e[1]))
    body = struct.pack(">I", len(entries))
    for tag, p, size, h in entries:
        body += struct.pack(">BH", tag, len(p)) + p + struct.pack(">Q", size) + h
    file_form = PREFIX + body
    with open(out, "wb") as f:
        f.write(file_form)
    hash_form = PREFIX + struct.pack(">I", KIND_SPLASH) + body
    print(f"entries={len(entries)} bytes={sum(e[2] for e in entries)} "
          f"manifest_hash={hashlib.sha256(hash_form).hexdigest()}")


if __name__ == "__main__":
    main()
