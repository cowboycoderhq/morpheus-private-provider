# Rebuild the pins

This guide rebuilds the child, the model hash and the engine executable from
this release, and compares them with the pins in `README.md`. Run every
command from the root of this repo. You do not need an Apple developer
account.

## Requirements

- A Mac with Apple silicon.
- Xcode: Xcode 27.1 build 27A9275. The child build ID records the toolchain (SDK
  27.0 26A425, Apple metal version 32023.921 (metalfe-32023.921.6)), because the same source and flags give different bytes
  with another SDK. The CommandLineTools SDK alone gives other bytes.
- For step 3: the `hf` command (Hugging Face CLI) and about 18 GB of free disk.

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## 1. Child

CAUTION: The commands write `/tmp/splash.signed`.

```
(cd child && make -j8 SEALED_DEFS=-DSPLASH_SEALED)
(cd child && make check-build-identity SEALED_DEFS=-DSPLASH_SEALED)   # "verified": true
shasum -a 256 child/build/splash
cp child/build/splash /tmp/splash.signed
codesign -f -s - --options runtime -i sealed.splash /tmp/splash.signed
codesign -dvvv /tmp/splash.signed 2>&1 | grep '^CDHash='
strings -a child/build/splash | grep -o 'src-[0-9a-f]*' | head -1
```

Expected:

- `child/build/splash` SHA-256: `51499416ad246a5970a77e44af26f8ac78b43bbd7314c37d7fe0100a629180fa`
- `CDHash=8083a3388742668a68027de726b2a5eaef049ac6`
- build ID `src-997348af029254a3c4c679c14adb7bae8c9eea8982aef57fde422ff4ea88231b`

The build folder and `HOME` do not change the bytes. A second Mac and a second
user account of the project got these values
(`records/SECOND-MAC-REBUILD-2026-10-25-r5.txt`).

## 2. Model hash

1. Download the model at the pinned revision:

   ```
   hf download audreyt/Qwen3.8-27B-Splash-abliterated --revision 78a6b379758eb6bf0740ef74581cd3432b144efc --local-dir /tmp/pkg
   ```

   The download also writes `LICENSE`, `README.md` and a `.cache/` folder.
   They do not change the hash.
2. Copy `model/sealed-manifest.bin` to `/tmp/pkg/sealed-manifest.bin`.
3. Check every weight file against the manifest:

   ```
   python3 harness/tools/check-manifest.py /tmp/pkg
   ```

   Expected: `75 entries, 0 differ`.
4. Compute the model hash:

   ```
   python3 engine/scripts/model-hash.py /tmp/pkg 8083a3388742668a68027de726b2a5eaef049ac6
   ```

   Expected: `model 57b2151c5135eb2d7376beab591ad221f6345c8654d8e4220a386747d0bd1477`.

## 3. Engine executable

```
(cd engine && scripts/build-reproducible.sh build/SealedEngine.verify)
shasum -a 256 engine/build/SealedEngine.verify
```

Expected: `e7227eb663506ea89015b5ae4e6dc3af3066f3f15bc7d3227f0022ddeb59702d`. The script uses SwiftPM, which fetches the
dependencies that `engine/Package.resolved` pins.

CAUTION: `build-reproducible.sh` deletes and reuses the folder
`/private/tmp/sealed-engine-v2-build`.

The engine CD hash also covers the App ID and the signature. This release
withholds both (see `README.md`), so you cannot compare your build with the
engine CD hash yet. With the App ID, `MODE=verify SEALED_APPID=<TEAM>.<bundle id>
engine/scripts/bundle.sh -` makes the unsigned bundle that
`sealed-verify rebuild` (in `router/sealed-consumer.patch`) compares with a
signed app.
