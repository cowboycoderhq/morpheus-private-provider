# Model package

The engine serves one model package. The package is the Hugging Face snapshot
of [`audreyt/Qwen3.8-27B-Splash-abliterated`](https://huggingface.co/audreyt/Qwen3.8-27B-Splash-abliterated)
at revision `78a6b379758eb6bf0740ef74581cd3432b144efc` (folders `target/`, `draft/`, `tokenizer/`,
`vision/` and `manifest.json`), plus `sealed-manifest.bin` from this folder at
the package root.

- `sealed-manifest.bin` SHA-256: `7b9e76572dfcf20c9d300f186deaa038d1cdb19dd92f001e78db309e043094c6`
- It lists each file that the child may open, with its size and SHA-256. The
  child refuses a file that is not listed or does not match.
- `harness/tools/check-manifest.py <package>` checks every file against it.
- The model hash covers this manifest, the five tokenizer files and the child
  CD hash. See `docs/REBUILD.md`, step 3.

The weights are open. The claim covers model integrity, not model secrecy.
