#!/usr/bin/env python3
"""Computes the v2 model hash a consumer pins, from the package files and the
child's CD hash, without the engine. Must equal the engine's printed value:
  manifest_hash  = SHA256(prefix18 ‖ u32be(2) ‖ manifest[18:])
  tokenizer_hash = SHA256 over the five tokenizer files, each as
                   name ‖ 0x00 ‖ u64be(len) ‖ bytes, in this order
  model_hash     = SHA256("morpheus-sealed/v2/splash-model" ‖ manifest_hash ‖
                   tokenizer_hash ‖ child CD hash)
Usage: model-hash.py <package root> <child CD hash hex>
"""
import hashlib, struct, sys

FILES = ["tokenizer.json", "tokenizer_config.json", "chat_template.jinja", "config.json", "vocab.json"]
root, child = sys.argv[1], bytes.fromhex(sys.argv[2])
m = open(f"{root}/sealed-manifest.bin", "rb").read()
assert m[:18] == b"sealed-manifest-v2"
mh = hashlib.sha256(m[:18] + struct.pack(">I", 2) + m[18:]).digest()
t = hashlib.sha256()
for name in FILES:
    b = open(f"{root}/tokenizer/{name}", "rb").read()
    t.update(name.encode() + b"\0" + struct.pack(">Q", len(b)) + b)
th = t.digest()
model = hashlib.sha256(b"morpheus-sealed/v2/splash-model" + mh + th + child).hexdigest()
print(f"manifest {mh.hex()}\ntokenizer {th.hex()}\nmodel {model}")
