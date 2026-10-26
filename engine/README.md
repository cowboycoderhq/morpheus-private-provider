# SealedEngineV2 — attested engine for the sealed Splash child (P9/P10 prototype)

State: 2026-10-25, M5 MacBook Pro (Mac17,7), macOS 27.2 beta 27.2-beta, Xcode 27.1 (27A9275). The pins and the accept report are in the table below.
Branch `feat/sealed-v2-splash-engine` (local).

## What it is

One hardened, App Attest-attested app that replaces the stand-in launcher and
the Splash Python server:

1. It reads the model package once, with `O_NOFOLLOW`, and hashes it:
   `modelHash = SHA256("morpheus-sealed/v2/splash-model" ‖ manifest hash ‖ tokenizer hash ‖ child CD hash)`
   (`scripts/model-hash.py` computes the same value from the files, without the engine).
2. It starts the pinned Splash child through the sealed spawn module
   (`Sources/SealedSpawnC/sealed_bringup.c`): A-13 canary, CD hash and status
   word before resume, socketpair channel and audit token, R5 probes, config
   frame, the "sandboxed" and "loaded" reports with a re-check at each, the
   manifest hash compared. The child's CD hash, requirement and status word are
   compiled in (`Sources/SealedEngineV2/ChildPin.swift`, made by `scripts/pin-child.sh`),
   so the engine's own CD hash covers the pin.
3. Only then it makes its App Attest key. The attestation and every assertion
   carry the engine's SHA-256 CD hash (`apple_cd_hash_hash_01`).
4. The consumer API and the envelope are the v1 ones (`GET /attest`, `POST /session`,
   `POST /probe`, `POST /infer`); the session assertion covers
   challenge ‖ client key ‖ engine key ‖ modelHash.
5. `/infer` opens the envelope, renders the chat template and tokenizes in
   this process (swift-transformers 1.3.4; token IDs equal the Splash Python
   server's on 9/9 test prompts, `Spikes/TokParity`), sends the Splash native
   protocol (`SplashWire.swift`) to the child, decodes the tokens and seals
   the reply. A child identity re-check runs before every request; any
   channel or identity fault ends the engine (fail closed).

The prompt exists in plain text only in this process and in the child. The
HTTP hop carries envelope ciphertext. Replies leave as sealed, padded frames
(every frame is 1043 bytes of ciphertext; the frame count is rounded up to a
power of two), so the network sees only the power-of-two frame count, which
is a size class of the reply length. Error replies are fixed strings that carry
no prompt or reply content: "not ready", "backend fault", "assertion refused",
"invalid client key", the two base64 length errors, "not found", "malformed
frame", "unknown session", "busy", "sealing failed", "refused", "inference
failed" and "rejected" (`main.swift`).

Length limit: root on the provider's Mac can learn the prompt and reply
length from the engine-to-child channel and from timing.

Content-signal limit: root can also read the token count of each decoding
step (1 to 9 tokens). Measured 2026-10-25: at temperature 0 the pattern is
the same for every run of a prompt and differs between prompts, so root can
check a guessed prompt on the open models; at 0.6 it still separates kinds
of text (`sealed-m5/review/SPEC-TEMP-2026-10-25.md`). See `sealed-m5/review/CLAIM-v2-2026-10-24.md`.

## Scripts

| Script | Does |
|---|---|
| `scripts/pin-child.sh CHILD DECOY REQGEN` | Writes `ChildPin.swift` for a signed child |
| `scripts/build-reproducible.sh [out]` | Builds the engine executable at the fixed path `/private/tmp/sealed-engine-v2-build`, unsigned (`-no_adhoc_codesign`) |
| `scripts/bundle.sh PROFILE IDENTITY` | Signed app `build/SealedEngineV2.app` (Apple Development identity IDENTITY, hardened, App Attest CD-hash opt-in) |
| `MODE=verify scripts/bundle.sh PROFILE` or `MODE=verify SEALED_APPID=<TEAM>.<bundle id> scripts/bundle.sh -` | Unsigned build `build/verify/SealedEngineV2.app` for `sealed-verify rebuild` (no profile needed with `SEALED_APPID`) |
| `scripts/start-engine.sh` | Starts the app through LaunchServices with a clean environment |
| `scripts/model-hash.py PKG PIN` | The model hash a consumer pins |
| `scripts/child-repro-check.sh SPLASH_SRC` | Builds the child in two folders; same bytes and CD hash? |
| `scripts/evidence.sh PROFILE` | The whole P9/P10 run below, PASS/FAIL per line |

Consumer: `proxy-router/cmd/sealed-chat` (verifies like a consumer node, sends one sealed prompt).

## Evidence (<date> <time>, `evidence/evidence-<date>-<time>.txt`): 12 PASS, 0 FAIL

- Child reproducible: two folders, same bytes, ad-hoc CD hash `<h5>` = the compiled pin.
- Engine reproducible: an unsigned rebuild from a second checkout matches the signed app in all 11 checks of `sealed-verify rebuild` (408 code pages, Info.plist, resources, entitlements, requirement, profile). App Attest CD hash `<h6>` (record: `evidence/reproducibility-2026-10-21.md`).
- Model hash `<h4>…3527`: engine value = value computed from the files.
- Verified chat: Apple chain, app ID, engine CD hash, session binding; reply "Paris".
- Refused: a different CD hash (code identity), a different model hash (session binding), a different app ID.
- Unplanned negative control (`evidence/evidence-<date>-<time>.txt`): after a one-line source change, the old signed app no longer matched a rebuild of the new source ("no match"), and every check that needs the published CD hash failed.
- P10 canary: answered by the child; absent from the engine log and stderr, the child TMPDIR, `~/Library/Logs`, `/tmp`, the unified log; no Python server or stand-in launcher runs.

## Current accepted build 2026-10-24 (supersedes every pin below)

| Artifact | Value |
|---|---|
| Engine App Attest CD hash | `<engine CD hash withheld>` |
| Child pin | `8083a3388742668a68027de726b2a5eaef049ac6` |
| Model hash | `57b2151c5135eb2d7376beab591ad221f6345c8654d8e4220a386747d0bd1477` |
| Source | engine commit `beba4427` (local branch, not on the hub); child source `sealed-m5/splash` commit `aa32be84` on top of incoai/splash 1.0.2 (local repo); harness commit `a7f245d0` |
| Accept | `sealed-m5/sealed-accept/reports/Mac17,7-27.2-beta-20261025ThhmmssZ.json` (engine commit `beba4427`): level A 138/138, level B 155 PASS + 4 EXEMPT of 159. Second-Mac build: `sealed-m5/review/SECOND-MAC-REBUILD-2026-10-25-r5.txt` (0 failed). Earlier reports (`…20261025ThhmmssZ` and older) are revoked by the current gates |
| Claim | `sealed-m5/review/CLAIM-v2-2026-10-24.md` |
| Open items | `sealed-m5/review/OPEN-ITEMS-CLOSURE-2026-10-24.md` |

Not "published": the source is not public, and no second party assembled
these pins. The second-Mac assembly in `evidence/SECOND-MAC-REBUILD-r4-2026-10-22.md`
covers engine `<h6>` and child `<h7>` only.

## Published build 2026-10-21 (superseded 2026-10-24)

- Source `<h8>`: R8 sandbox (`<h9>`), child-liveness gate (`<h10>`), and the S3 child pin.
- Child pin `<h7>` (`sealed-m5/child/pin.txt`, operator-approved). The requirement bytes are equal to `sealed-m5/child/req-splash.bin`.
- `build/SealedEngineV2.app`, built with `scripts/bundle.sh` (fixed build path, hardened, Apple Development). App Attest CD hash `<h6>`.
- Model hash `<h11>` (`scripts/model-hash.py`, new child pin).
- Ran for this build on 2026-10-21: `scripts/evidence.sh` 13 PASS / 0 FAIL (`build/evidence-<date>-<time>.txt`) and `sealed-verify rebuild` MATCH (`evidence/reproducibility-2026-10-21.md`).

The values in *Evidence (2026-10-20)* above are for the build before R8 (`<h12>…12ec`, child `<h5>…6c70`).

## Measured facts found on the way

- The App Attest CD-hash extension needs the macOS 27 SDK and bundle metadata.
  Built with CommandLineTools (SDK 26.5, minimum macOS 14), the attestation had
  no extensions (no CD hash, no validation category). With the Xcode 27 SDK,
  minimum macOS 27.0, `CFBundleSupportedPlatforms`, `DTPlatformName`,
  `DTSDKName` and `PkgInfo`, it carries them. (The minimum-version change
  alone did not; the SDK and the plist keys were changed together, so which of
  them is required is not separated.)
- The `appattest-environment` entitlement is not in this Mac's profile; with
  it, AMFI kills the app at launch (exit 137).
- An app started through `open` gets `OSLogRateLimit` from launchd; the
  environment allowlist accepts it.
- Engine builds differ between folders (trap sites encode the source path
  length; `-file-prefix-map` did not change them); a fixed build path fixes it.
- A linker-signed published build and an unsigned rebuild differ in 237 of 407
  pages; both unsigned before `codesign`, they match.

## Limits (not closed)

- Signing: the operator's Apple Development certificate and the borrowed
  `<bundle-id>` App ID (the only profile here with the App
  Attest opt-in). Development-signed (validation category 3). A distribution
  profile for a dedicated App ID needs the Account Holder in Xcode.
- Reproduction of the current pins: two checkouts and two `HOME` values on the M5, and a second Mac and second user (<host-b>, `<second-user>`,
  `sealed-m5/review/SECOND-MAC-REBUILD-r4-2026-10-25.txt`). An independent party and a CI build from a public commit are still owed (R11).
- The source is not public yet; consumers cannot run `sealed-verify rebuild` until it is.
- R8 (engine sandbox) is in the 2026-10-21 build: `R8-SANDBOX-2026-10-21.md`. Root's view of the engine (task port,
  dtrace, lo0 capture) is in the root kit (`sealed-m5/tools/tee-rootpass.sh`,
  "P10 engine" arms). Runs: `sealed-m5/review/TEE-ENGINE-ROOT-2026-10-21*.md`.
- Prompt strings in the engine's memory are not zeroized.
- The child path, decoy and package come from the environment; they only
  affect availability (the kernel enforces the child pin, the session binds
  the model hash).

## Review

`REVIEW-GLM-2026-10-20.md` (GLM 5.3, adversarial): P9 and P10 MET WITH FIXES, no blocker.
Dispositions:
1. ERROR decode offsets: false. `Spikes/wire-roundtrip.swift` decodes frames
   serialized by the Splash Python module to the packed values, and the
   REQUEST bytes are equal to Python's.
2. START decode offsets: false (same test; `<QBiII` has no padding).
3. ERROR/CAPACITY frames not matched by request id: fixed (id or connection-level 0 only; others are a protocol fault).
4. Unsealed error replies: they are fixed status strings without content; README wording made exact.
5. Stale `rebuild-compare.txt`: removed; the evidence file carries the compare output of its own run.
6. Manifest coverage of every weight file: settled by the child's R6 suite
   (`sealed-m5/neg/final-2026-10-20.txt`: a file not in the manifest, a changed
   byte, a truncated or grown file, a symlink, a second read, all refused).
