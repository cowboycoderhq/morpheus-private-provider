# AUDIT v2 round 4, auditor 2: engine and attestation chain (2026-10-24)

Area: `SealedEngineV2` and the attestation chain on the round-4 build. Engine CD hash `<h20>`, commit `<h83>` (README `<h84>`), branch `feat/sealed-v2-splash-engine`. Child `<h24>`. Model hash `<h85>`. Accept report `sealed-accept/reports/Mac17,7-27.2-beta-20261025ThhmmssZ.json`.

The audit was read-only. I did not build, start, stop or signal the engine (pid 87624, child pid 87817). I wrote only this file and scratch files under `/tmp/r4a2`. I ran these commands:

1. `git diff <h26> <h83>` and `git diff <h84>` in `~/projects/morpheus-pnode`.
2. `python3 scripts/model-hash.py` on the package with the new pin and with the old pin.
3. `codesign -dvvv` and `codesign -v --strict` on `child/splash`, `build/SealedEngineV2.app` and pid 87624.
4. A Python comparison of `child/req-splash.bin` with the requirement bytes in `ChildPin.swift`.
5. `python3 -B matrix.py accepted` for levels A and B, and for the revoked commits.
6. `go test ./internal/sealed/` and `go test -run Sealed ./internal/proxyapi/` with `GOCACHE=/tmp/r4a2/gocache GOPROXY=off`. Both pass.
7. `go test -overlay` with the round-3 extra tests (`/tmp/r3a2/ov/extra_test.go`). All four pass. The source tree did not change.

## Pre-registered falsifiers

1. A section-6 arm prints PASS, but its bad input did not reach the engine, its control did not fire, or its stored evidence is empty.
2. A pin in the chain (ChildPin.swift, `child/pin.txt`, codesign of `child/splash`, `req-splash.bin`, kit `engine-cdhash`, kit `engine-modelhash`, matrix row) differs from the others.
3. `scripts/model-hash.py` does not give `<h85>…`, or no consumer checks the model hash.
4. The client accepts an unpadded frame, a frame other than 1027 bytes, or a count that is not a power of two.
5. The engine build or run reads a file outside the repo that no pin covers.

Falsifiers 2, 3, 4 and 5 did not hit. Falsifier 1 hit in part (R4-E-02, and the weaker items R4-E-03 and R4-E-04).

## What changed in the engine repo since round 3

`git diff --stat <h26> <h83>` lists five files only:

- `proxy-router/internal/sealed/sealed.go`: comments only (the package comment now names the padded format, and a comment on the zero count).
- `sealed-engine-v2/Sources/SealedEngineV2/ChildPin.swift`: the new pin `<h24>…` (cdhash bytes, hex, requirement bytes). The status word and the decoy pin did not change.
- `sealed-engine-v2/scripts/evidence.sh`: section 6 (62 new lines).
- `sealed-engine-v2/scripts/child-repro-check.sh`: the second copy builds with `HOME=/tmp/child-repro-home`.
- `sealed-engine-v2/README.md`.

No other Swift or C source changed. `git diff --stat <h84>` is empty. The only untracked file is `sealed-engine-v2/evidence/SECOND-MAC-REBUILD-r4-2026-10-21.md`.

## 1. Round-3 findings

| id | status | evidence |
|---|---|---|
| R3-E-01 (six engine results only in session output) | MOSTLY FIXED | `evidence.sh:84-136` adds 10 arms. Each arm writes its output into `build/evidence-*.txt`, and the accept run copied that file into the report folder (`evidence-<date>-<time>.txt`, 18,094 bytes). The 503 output, the full engine log of the budget run and the `REPLY`/`FRAMES` lines are stored. Residues: the big-grapheme arm does not show a grapheme of more than 1024 bytes (R4-E-02). The arms are not in the required list (R4-E-01). The 503 has no same-prompt control (R4-E-03). The budget-range arms store no refusal text (R4-E-04). The 1024/1025-byte boundary replies were not added (R4-E-05). There is still no Swift test target (R3-E-06). |
| R3-E-02 (grapheme run detail) | FIXED in the record. The reply size is still not stored. | `OPEN-ITEMS-CLOSURE-2026-10-24.md:33` now says: "a 1201-byte character alone gives 2 frames; the `big-grapheme` reply holds more text". The arm does not record the reply byte count (R4-E-02). |
| R3-E-03 (client cannot tell revoked `<h27>` from the accepted build) | MITIGATED by the new pin. No code change. | The client still has no retired list (`grep -rn 'retired\|revoked\|<h27>\|<h21>' --include=*.go proxy-router`: 0 hits). But the model hash covers the compiled child pin (`ModelPackage.swift:36`). `<h27>` and `<h21>` both compile child `<h23>`, so they bind model hash `<h86>…` (measured with `model-hash.py`). The accepted build binds `<h85>…`. A consumer that pins only `<h85>…` refuses both old builds at `sealed.go:133` (`containsHash(allowedWeights, cd[96:128])`), even if it keeps an old CD hash. The residue: the claim does not tell consumers to drop `<h86>…` and the old CD hashes. The closure row `:34` still says "Earlier engine pins must be removed from consumer lists" with no hash. |
| R3-E-04 (five stale lines) | (a), (b), (c) FIXED. (d) MOSTLY FIXED. (e) OPEN. | (a) `sealed.go:25-28` now names flags 0x02/0x03 and 1027 bytes. (b) The `<h74>` line is gone; closure `:105` lists the current commits. (c) `accept.sh:361` now says "attested and matches the pinned hash". (d) `CLAIM-v2-2026-10-24.md:38` now says: "A 503 shows that the child refused the request (the KV budget, capacity, or a retryable child error)". The engine also sends 503 with other bodies ("not ready", "backend fault", "assertion refused", `main.swift:81`, `:205`, `:223`, `:240`, `:262`, `:269`, `:286`). The body tells these apart, so this residue is wording only. (e) `README.md:37-38` still lists only "rejected", "busy", "refused", "inference failed". See R4-E-06. |
| R3-E-05 (hygiene) | OPEN | (a) `sealed.go:298-300`: `if len(frames) == 0 { return nil, ErrTruncated }` still cannot run. (b) `main.swift:306` still has the distinct body `"sealing failed"`. (c) `main.swift:373-375` still increments `sendSeq` per frame before a later frame can throw. Effect on content: none (the client drops the channel on the 500). |
| R3-E-06 (test gaps) | OPEN | `padding_test.go` and `sealed_test.go` did not change since `<h26>` (`git log -- internal/sealed`). The long-frame, mixed-flag and dead-session tests exist only as my overlay file. `sealed-engine-v2/Tests` does not exist, and `Package.swift` has no `testTarget`. |

## 2. Section-6 arms (vacuous-pass rule)

The rule: (a) the bad input reached the check, (b) the control fired, (c) the stored evidence is not empty and supports the verdict. Stored files: `engine-evidence.txt` (2,467 bytes, PASS lines only) and `evidence-<date>-<time>.txt` (18,094 bytes, full output). The evidence run started at <time> local time, inside the accept run (<time>Z to <time>Z), after commit `<h83>` (<time>). `run/engine-isolated` is PASS.

| arm | (a) input reached | (b) control | (c) stored evidence | verdict |
|---|---|---|---|---|
| `padded-reply-1` | Yes. The reply is "Paris" (about 6 bytes). | The check needs exactly 1 frame and 1043 bytes per frame. | `FRAMES ciphertext bytes: 1043` and the `REPLY` line. | VALID |
| `padded-reply-2` | Yes. The reply is about 2,000 bytes, so 2 chunks. | The check needs exactly 2 frames, all 1043 bytes. | `FRAMES ciphertext bytes: 1043,1043`, the first 160 bytes of the reply, and "reply about 2001 bytes" (`wc -c` counts the newline). | VALID |
| `padded-reply-4` | Yes. The reply is about 3,000 bytes, so 3 chunks plus 1 filler frame. This also exercises the filler path. | The check needs exactly 4 frames, all 1043 bytes. | `FRAMES ciphertext bytes: 1043,1043,1043,1043` and "reply about 3001 bytes". | VALID |
| `big-grapheme` | NOT SHOWN. The prompt holds "a" + 600 × U+0301. The stored reply is cut at 120 characters (`evidence.sh:105`, `cut -c1-120`). It holds U+00E1 and 86 × U+0301 (174 bytes), all one grapheme so far. 4 frames show that the reply is 2,049 to 4,096 bytes. Nothing shows that one grapheme in the reply is more than 1024 bytes. | The check needs only a `REPLY` line and frames of 1043 bytes (`evidence.sh:107`). It does not measure the longest grapheme. | Partial: the first 120 characters only. | WEAK (R4-E-02) |
| `frame-v2-budget` | Yes. The log line `kv budget: 536870912 bytes` is written at `main.swift:61`, before the frame is sent. The code sends frame v2 for any non-zero budget (`sealed_bringup.c:76-84`, `:208`). The stored log then shows "child loaded; manifest hash matches the engine's" and "child ready", so the child accepted the v2 frame. | The 503 below at 19,759 tokens (under the 32,768 context and under the child's 16 GiB default) is the indirect control that the child applied the budget. | The full engine log of the budget run is stored. | VALID (the log line alone proves only that the engine parsed the variable. The stored "child loaded" line and the 503 complete it.) |
| `refusal-503-body` | Yes. The stored line is `FAIL infer: status 503: map[error:refused]`. | The regex needs the exact body at the end of the line (`evidence.sh:121`). No arm sends the same long prompt to the default engine, so the run does not show that the KV budget caused the 503 and not capacity or another retryable child error (`SplashBackend.swift:83-88`). | Stored. | VALID for the body. The cause is not isolated (R4-E-03). |
| `refusal-log-line` | Yes. A refusal occurred. | `rl` needs a line that ends in `request refused`. `rn` needs 0 refusal lines with a digit (`evidence.sh:123`). The old `<h27>` line (`request refused: <text>`) would fail `rl`. | The full engine log of the run is stored. It holds exactly one `request refused` line and no other line between the listen line and the two `serving:` lines. | VALID |
| `serve-after-refusal` | Yes. | The check needs "Paris". The stored log shows one listen line, so the same engine process served after the refusal. | Stored `REPLY (1 sealed frames, 0.3 s): "Paris"`. | VALID |
| `budget-range-1` | Yes (a start with `SEALED_KV_BUDGET_BYTES=1`). | The check needs the text "refusing to start: SEALED_KV_BUDGET_BYTES" and no engine process (`evidence.sh:133`). Only `main.swift:58` writes that text. `start-engine.sh:12-14` stops the old engine and empties both logs first. The 536,870,912 run is the in-range control. | Only the PASS line. The refusal text and exit code 4 are not stored, because `keeplog` is not called in 6d. | VALID, but the stored evidence is thin (R4-E-04) |
| `budget-range-1099511627777` | Yes. | Same as above. | Same as above. | VALID, but the stored evidence is thin (R4-E-04) |

## 3. Pin chain after the HOME fix

| Link | Value | Command |
|---|---|---|
| `ChildPin.swift` `cdhashHex` and `cdhash` bytes | `<h24>` | `git show <h83>`. Generated by `pin-child.sh` at 2026-10-25T03:07:55Z. |
| `ChildPin.swift` `requirement` bytes | 82 bytes, holding the cdhash above | The Python comparison gives `req==file True`, `cd in req True` |
| `child/req-splash.bin` | 82 bytes, equal to the `requirement` array | `xxd`: `…6804 146b 309a d537 b9e2 87a7 fc58 051b c136 4cb2 d93e a630…` |
| `child/pin.txt` | `<h24>` | `cat` |
| `codesign` of `child/splash` | `CDHash=<h24>`, `flags=0x10002(adhoc,runtime)`, `Identifier=sealed.splash`, `--strict` verifies | `codesign -dvvv`, `codesign -v --strict` |
| Engine app and running pid 87624 | `CDHash=<h20>…` (SHA-256 truncated by codesign), `TeamIdentifier=<TEAM>`. The app verifies with `--strict` | `codesign -dvvv` |
| Running engine log | `model=<h85>… child=<h24>… sandbox=R8` | `build/engine.log` |
| Kit `engine-cdhash` (source and `/usr/local/libexec/tee-rootkit`) | `<h20>…fa29e` in both | `cat`. Both `SHA256SUMS` files are identical, and each lists the file hash `<h87>…`, which equals `shasum` |
| Kit `engine-modelhash` (both) | `<h85>…fedfe57` in both | `cat`. `SHA256SUMS` hash `99586920…` equals `shasum` |
| Matrix row | commit `<h83>…`, engine `<h20>…`, child and pin `<h24>…`, model `<h85>…` | `matrix.json`. `matrix.py accepted --level A`: "yes … 122/122". `--level B`: "yes … 142/142 … (4 documented EXEMPT)". `--commit <h88>`: "REVOKED … engine CD hash <h21> is revoked". `--commit <h26>`: "REVOKED … tool_sha256 <h89> is not an approved harness". |

The model hash: `model-hash.py pkg/qwen38-27b <h24>…` gives `manifest a1a25ecb…`, `tokenizer 2f57d972…`, `model <h85>`. The same package with the old pin `<h23>…` gives `<h86>…` (the round-3 value). So the change comes only from the child pin, and the package did not change. The formula in `model-hash.py:4-8` equals `ModelPackage.swift:23-36` (prefix18 ‖ u32be 2 ‖ rest. Then name ‖ 0x00 ‖ u64be len ‖ bytes for the five files in the same order. Then the domain string ‖ manifest ‖ tokenizer ‖ `ChildPin.cdhash`). The stored engine log of the budget run prints the same three values.

The consumer binds it. `sealed.Establish` first verifies the App Attest assertion over SHA-256 of the 128-byte clientData (`sealed.go:127-131`). Then it needs `cd[96:128]` in `allowedWeights` (`sealed.go:133`). The router passes the configured pins or the listing value (`sealed_sender.go:235-255`, `:374-376`). `sealed-chat` passes `--weights` (`cmd/sealed-chat/main.go:130`). The accept run computes `MH` independently with `model-hash.py` (`accept.sh:275`), not from the engine log. The `refuse-wrong-model` arm (zero hash refused with "session binding") is the control.

## 4. Client (`proxy-router/internal/sealed`)

- The code did not change since round 3 (comments only). The padded-only rule is at `sealed.go:244-249` (power-of-two count, `failed` set), and the flag and size checks are in the frame loop (0x02/0x03 only, `len(pt) == 1027`).
- The repo tests pass: `go test ./internal/sealed/` gives `ok`, and `go test -run Sealed ./internal/proxyapi/` gives `ok`.
- The round-3 overlay tests still pass on this code: `TestR3LongFrameRefused`, `TestR3MixedRefused`, `TestR3Counts`, `TestR3SessionDeadAfterRefusal`. The repo does not keep them (R3-E-06 open).
- The round-3 mutant results still apply, because the checked lines did not change.

## 5. New items and outside-repo dependencies

- The engine source has no path outside the repo. `grep` for `/Users/`, `$HOME`, `~/` and `sealed-backends-spike` in `Package.swift`, `Sources/`, `bundle.sh`, `build-reproducible.sh` and `pin-child.sh` finds only a comment (`sealed_r8.h:3`) and relative `../Info.plist` probes (`sealed_r8.c:485-488`). `strings -a` on the signed executable has no `/Users/` path. The only path string is `/private/tmp`.
- The engine keeps its own guard copy (`Sources/SealedSpawnC/sealed_guard.c`, `include/sealed_guard.h`). It is byte-equal to `splash/runtime/sealed/guard/` (`diff`: no output). No gate keeps the two equal (R4-E-07).
- At run time, `start-engine.sh:8`, `:17-18` point the engine at `$HOME/projects/sealed-backends-spike/sealed-m5/{pkg/qwen38-27b,child,tools/decoy}`. These are outside the engine repo by design. The model hash covers the package, the compiled pin covers the child, and `ChildPin.decoyCDHash` covers the decoy. So this is not a finding.
- The build fetches swift-transformers 1.3.4 and its dependencies from GitHub or from the SwiftPM cache under the home folder. `Package.resolved` pins each revision. The `rsync` in `build-reproducible.sh` leaves out `.build`, so each build resolves again. This is pinned and so not a finding. A second party needs network access or the same cache.
- `evidence.sh:26` calls `xcodebuild` without `DEVELOPER_DIR`, so the header records no toolchain (R4-E-08).
- The Go tools compute only the v1 weights hash (`sealed-verify --hash-model` calls `WeightsManifestHash`, `cmd/sealed-verify/main.go:65-75`). Only `scripts/model-hash.py` in the local engine repo computes the v2 model hash (R4-E-09).

## Findings

| id | severity | area | finding | evidence | recommended action |
|---|---|---|---|---|---|
| R4-E-01 | MEDIUM | accept gate | **The 10 section-6 arms are not required.** They are not in `required.json` and not in `ENGINE_EXPECTED`. A FAIL in one of them turns `engine/suite` to FAIL (`nfail == 0`), but a missing arm does not. If section 6 stops early, or a later `evidence.sh` drops an arm, the report still passes A 122/122. The closure rows `:31-33` call these items "closed" on the strength of the accept run. | `required.json` (A 122): no `engine/padded-reply-*`, `big-grapheme`, `frame-v2-budget`, `refusal-*`, `serve-after-refusal`, `budget-range-*`. `accept.sh:438-440` (`ENGINE_EXPECTED` lists 12 arms). `accept.sh:538-544` (the missing-arm SKIP and the suite PASS rule use only `ENGINE_EXPECTED`). Report `totals`: `"required": 122` while `results` has 152 rows. | Add the 10 names to `ENGINE_EXPECTED` and to both levels of `required.json`. Approve the new required hash in `approved-required.txt`. Rerun the accept. |
| R4-E-02 | MEDIUM | engine evidence | **The `big-grapheme` arm does not show that a grapheme of more than 1024 bytes reached `chunks()`.** The PASS needs only a `REPLY` line and frames of 1043 bytes. The stored reply is cut at 120 characters: U+00E1 + 86 × U+0301 = 174 bytes. Four frames show a reply of 2,049 to 4,096 bytes, but not its graphemes. The model may have broken the mark run. So rule (a) is not met by the stored evidence. `CLAIM-v2-2026-10-24.md:24` says that the accept run "stores … a 1201-byte character". The code fix itself held in my round-3 copy test (3,000 fuzz strings, 0 failures). | `evidence.sh:104-108`. `evidence-<date>-<time>.txt`: `REPLY (4 sealed frames, 9.0 s): "á́́…` (207 bytes, 120 characters). `CLAIM-v2-2026-10-24.md:24`. | In the arm, compute the reply byte count and the longest extended grapheme cluster (for example with Python `regex` `\X`, or by counting the longest run of U+0301 after the base). Require more than 1024 bytes. Store both numbers. Until then, change CLAIM:24 to "a reply that started with a long combining-mark run". |
| R4-E-03 | LOW | engine evidence | **The 503 arm has no same-prompt control.** The engine sends 503 `{"error":"refused"}` for any retryable child error, "KV budget exceeded", or capacity exhausted. No arm sends the 19,759-token prompt to the default engine (16 GiB). So the run does not show that the 512 MiB budget caused this 503. The stored "child loaded" after the v2 frame and the token arithmetic in the comment make the budget the likely cause. | `SplashBackend.swift:83-88`. `evidence.sh:114-122`. | Send `LONG` to the default engine in 6a and expect a 200 (or at least no 503). Then the 503 on the budget engine isolates the budget. |
| R4-E-04 | LOW | engine evidence | **The budget-range arms store only their PASS lines.** The refusal text and exit code 4 are not in the evidence file, because `keeplog` is not called in 6d. The next `start-engine.sh` empties the logs. | `evidence.sh:131-136`. `evidence-<date>-<time>.txt`: only `PASS [budget-range-1] …` and `PASS [budget-range-1099511627777] …`. | Call `keeplog budget-range-$bad` after each start. Record the exit status of the engine process if `open -W` or a pid wait makes it available. |
| R4-E-05 | LOW | engine evidence | The boundary replies of exactly 1024 and 1025 bytes (R3-E-01 recommendation 2) were not added. The padded arms use replies of about 6, 2,000 and 3,000 bytes. The boundary held in my round-3 copy test, so this is evidence depth only. | `evidence.sh:92-101`. | Optional: add one prompt that gives a reply just over 1024 bytes and expect 2 frames. |
| R4-E-06 | LOW | stale text | Four record lines are out of date. (a) `README.md:76` gives "Source \| commit `<h26>`" for the `<h20>` build. The build is from `<h83>` (`ChildPin.swift` changed). (b) The closure row `:31` cites "`evidence-<date>-<time>.txt` of the report folder". That file is only in the revoked folder `…20261025ThhmmssZ/`. The accepted folder holds `evidence-<date>-<time>.txt`. (c) `README.md:37-38` still lists 4 of the 10 fixed error bodies (R3-E-04 e). (d) `CLAIM-v2-2026-10-24.md:38` reads every 503 as a child refusal, but the engine also sends 503 "not ready", "backend fault" and "assertion refused". | `README.md:76`, `:37-38`. `OPEN-ITEMS-CLOSURE-2026-10-24.md:31`. `ls reports/*/`: `<time>` only in `…021729Z/`. `main.swift:81`, `:205`, `:223`, `:240`, `:262`, `:269`, `:286`, `:306`, `:321`. | Correct the four lines. |
| R4-E-07 | LOW | build provenance | No gate keeps the engine guard copy and the child guard copy equal. They are byte-equal today. If one copy changes, the engine R1 guard and the child R1 guard differ silently. | `Sources/SealedSpawnC/sealed_guard.c` and `include/sealed_guard.h` against `splash/runtime/sealed/guard/sealed_guard.{c,h}` (`diff`: no output). `grep sealed_guard` in `accept.sh`, `evidence.sh` and `tee-rootpass.sh`: 0 hits. | Add a `cmp` of both files as an `evidence.sh` or `accept.sh` arm. |
| R4-E-08 | LOW | records | The evidence header records no toolchain. `evidence.sh:26` runs `xcodebuild -version` without `DEVELOPER_DIR`, so the active developer folder is CommandLineTools and the call fails. The build scripts set `DEVELOPER_DIR` themselves, so the build is not affected. | `engine-evidence.txt:1`: "xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance". `evidence-<date>-<time>.txt:1` ends after `27.2-beta`. | Export `DEVELOPER_DIR` at the top of `evidence.sh`, as `build-reproducible.sh:18` does. |
| R4-E-09 | LOW | consumer tooling | The Go tools cannot compute the v2 model hash. `sealed-verify --hash-model` prints the v1 weights hash. Only `scripts/model-hash.py` in the local, unpublished engine repo gives `<h85>…`. A consumer that uses the Go tool gets another value and fails closed (no privacy loss). Separately, `weights_test.go:41` is `func ADDR_07b961(t *testing.T)`, which is not a `Test` function, so its four v1 rejection cases never run. This test dates from 2026-09-27 (`<h90>`). | `cmd/sealed-verify/main.go:65-75`, `internal/sealed/weights.go:25-35`. `weights_test.go:41`. | Add a Go `ModelHashV2(pkgRoot, childPin)` with a vector test that equals `model-hash.py`, and expose it in `sealed-verify`. Rename the v1 test to `TestWeightsManifestHashRejects…`. |
| R3-E-03 | LOW (mitigated) | pins | See section 1. The new child pin gives the accepted build its own model hash, so a consumer that pins only `<h85>…` refuses `<h27>` and `<h21>`. The claim does not tell consumers to drop `<h86>…` and the old CD hashes. | `ModelPackage.swift:36`. `model-hash.py` with `<h23>` gives `<h86>…`. `OPEN-ITEMS-CLOSURE-2026-10-24.md:34`. | Name the retired model hash `<h86>…` and the retired CD hashes in the claim or the README. |
| R3-E-05 | LOW (open) | hygiene | No change since round 3. | `sealed.go:298-300`. `main.swift:306`, `:373-375`. | As in round 3. |
| R3-E-06 | LOW (open) | tests | No change since round 3. | `padding_test.go`, `sealed_test.go` (no commit after `<h26>`). No `Tests/` folder and no `testTarget`. | As in round 3. |

## Verdict for the engine area

The attestation chain on the round-4 build is consistent from end to end (falsification-beats-confirmation):

1. `ChildPin.swift`, `child/pin.txt`, the codesign of `child/splash` and `req-splash.bin` all give `<h24>…`.
2. The app, the running pid, the kit (source and installed) and the matrix row all give engine `<h20>…`.
3. `model-hash.py` gives `<h85>…`, equal to the engine log and the kit. The value moved from `<h86>…` only because the child pin changed.
4. The consumer binds the model hash after it verifies the assertion. The accept run computes the hash independently of the engine.

The client code did not change, and it still accepts only padded 1027-byte frames in a power-of-two count. The engine source changed only in `ChildPin.swift`. It has no home-folder path in its source or its binary.

The round-3 evidence gap (R3-E-01) is mostly closed. Eight of the ten section-6 arms meet the vacuous-pass rule, with the full budget-run log stored. The weak points are in the evidence, not the code (judge-the-method-not-the-claim):

1. The `big-grapheme` arm does not show the oversized grapheme that it is named for, and CLAIM:24 overstates what it stores (R4-E-02).
2. None of the new arms is in the required list, so a missing arm would not stop acceptance (R4-E-01) (fail-loudly-not-silently).

The rest are LOW: a missing same-prompt control for the 503, thin budget-range storage, four stale lines, no gate on the guard copies, no toolchain in the evidence header, no Go tool for the v2 hash, and the round-3 hygiene and test items. I found no CRITICAL or HIGH item in this area.
