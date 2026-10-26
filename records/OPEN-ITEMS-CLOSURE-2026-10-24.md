# Open items closure — 2026-10-24 (accepted build, updated after the round-3 fixes)

This file supersedes `OPEN-ITEMS-CLOSURE-2026-10-22.md`. It is written against the accepted build and the three audit rounds (`review/AUDIT-v2-*.md`, `review/AUDIT-v2-R2-*.md`, `review/AUDIT-v2-R3-*.md`).

## The build this file describes

| Artifact | Value |
|---|---|
| Child CD hash | `8083a3388742668a68027de726b2a5eaef049ac6` |
| Engine CD hash | `<engine CD hash withheld>` |
| Model hash | `57b2151c5135eb2d7376beab591ad221f6345c8654d8e4220a386747d0bd1477` (covers the package and the child pin; the weights did not change) |
| Engine commit | `7a83aa51` (local branch `feat/sealed-v2-splash-engine`, not on the hub). Child source `splash/` commit `aa32be84` on top of incoai/splash 1.0.2; harness `sealed-m5` commit `22bcc434` (local repos) |
| Accept report | `sealed-accept/reports/Mac17,7-27.2-beta-20261026ThhmmssZ.json` (harness copy in its `harness/` folder) |
| Accept verdict | Level A 141/141 PASS. Level B 158 PASS + 4 EXEMPT (162 required). `matrix.py accepted --device Mac17,7 --commit 7a83aa51 --level B` answers yes |
| Earlier reports | `…20261025ThhmmssZ` (engine `<h17>`, child `8083a338`, `v0.1.0`, revoked for the boot-posture gate and `MinOSVersion`); `…20261025ThhmmssZ` (engine `<h19>`, child `<h25>`, revoked for release hygiene: home-folder default in the probe source); `…20261025ThhmmssZ` (engine `<h20>`, child `<h24>`, revoked for the round-4 fixes); `…20261025ThhmmssZ` (engine `<h21>`, child `<h23>`, revoked for R2-4-02); `…20261024ThhmmssZ` (commit `<h26>`, same pins, older harness); `…20261024ThhmmssZ` (engine `<h27>`): REVOKED by the current gates |
| Mac | Mac17,7, macOS 27.2-beta, Full Security, SIP on |

Status words: **closed** means a test with a fired control supports the row on the accepted build. **closed (earlier build)** means the test ran on an earlier build and the release code in that area is the same; the row names the build. **limit** means the claim states it as a limit. **open** means a fix or a test is still to do.

## Measured on the accepted build

| Item | Status | Evidence |
|---|---|---|
| Child negative suite | closed | 95/95 in the accept report (`neg-run-all.txt`). All test builds were rebuilt from the current source before the run; the harness recomputes the build ID of all 75 builds (74 test builds and the production build) and refuses a run on a mismatch (R2-N1, R3-G1 fixed) |
| Engine evidence suite | closed | 26/26 in the accept report (`engine-evidence.txt`), all required: `child-reproducible` with two `HOME` values, `boot-posture`, `boot-posture-unit` (13 cases), `refuse-old-macos` (`MinOSVersion`), the P10 canary legs, and section 6 (padding, grapheme, 503 with its control, frame v2, budget range) |
| P10 file search incl. `/tmp` | closed | `evidence.sh` searches `/private/tmp` with a control canary that must be found ("control found 1"). Earlier runs searched `/tmp` vacuously (audit A4-03) |
| Root: task ports and dtrace attach on engine and child | closed | Accept run root pass `logs/tee-rootpass-<date>-<time>/` (its small files are copied into `rootpass/` of `sealed-accept/reports/Mac17,7-27.2-beta-20261026ThhmmssZ/`): `P10-engine-identity` (runs the pinned CD hash), `P10-engine-*` and `P10-engine-child-*` refused, each with the shared ctlproc control in its rule (R4-3 F-11, R3-03 fixed) |
| Root: `gcore` on engine and child | closed | Same run: `P6-gcore-engine` and `P6-gcore-engine-child` PASS (`root-pass.txt:76-77`). Root `gcore -x stack` refused on engine pid 86080 and child pid 86151 (`rc=77`); decoy pid 92962 (found under its own `sudo` job) dumped an 81,920-byte stack core in the same run (`rootpass/gcore-ctl.txt`) (R2-08, R2-09, R2-5-12, R4-3-07 fixed) |
| Root: P10-lo0 ciphertext only | closed | Canary in the sealed reply, 0 times in a 14,401-byte capture of :29452 (`root-pass.txt:74`) |
| Entitlement audit | closed | `artifacts/no-forbidden-entitlement` PASS: engine holds only application-identifier, team-identifier, App Attest opt-in; child holds none |
| HTTP 503 body and log line | closed | Accept run arms `refusal-503-body` (19,759-token prompt over a 512 MiB budget gets 503 with body `{"error":"refused"}`), `refusal-log-line` (`request refused` 1 time, no number) and `serve-after-refusal` (a short chat after it answers "Paris"). Full engine log copy in the `evidence-*.txt` file of `sealed-accept/reports/Mac17,7-27.2-beta-20261025ThhmmssZ/`; control `refusal-503-control`: the same prompt on the default budget is served (R4-E-03 fixed) (R2-E-01, R3-E-01 fixed) |
| Frame v2 budget in the engine | closed | Accept run arms `frame-v2-budget` (log `kv budget: 536870912 bytes`), `budget-range-1` and `budget-range-1099511627777` (engine refuses to start) (R2-E-06, R3-E-01 fixed) |
| Reply frame padding on the network | closed | Accept run arms `padded-reply-1`, `-2`, `-4` (1, 2 and 4 frames for replies of about 6, 2001 and 3001 bytes, every frame 1043 bytes) and `big-grapheme` (4 frames of 1043 bytes, no 500) (R2-E-03, R2-E-05, R3-E-01 fixed). Round 4 (R4-E-02 fixed): `big-grapheme` reads the reply bytes (`sealed-chat --reply-file`) and requires the longest grapheme cluster to exceed 1024 bytes; the accept run measured one cluster of 3,000 bytes in 4 frames of 1043 bytes |
| Client refuses unpadded frames | closed | Client accepts only flags 0x02/0x03 with a 1027-byte plaintext and a power-of-two frame count; Go tests for each refusal (R2-E-04 fixed). Earlier engine pins must be removed from consumer lists |

## Measured on an earlier build

| Item | Status | Evidence |
|---|---|---|
| P6 GPU and kernel paths | closed (child `<h22>`) | `review/P6-GPU-MEMORY-2026-10-23.md`: GPU capture and debug switches closed, kernel memory paths absent at Full Security. Arms A3 and A4 are INFO (no valid control). The `gcore` part now runs in every root pass on the accepted build (row above) |
| K-2 freed KV memory | closed (test build from earlier source) | `review/K2-FREED-KV-2026-10-23.md`: 16.1 GB of fresh memory scanned, 0 child bytes; heap control found 65,520 of 65,520. Scope (audit R2-10): this shows fresh pages are zero; it does not show the reader got the child's freed pages |
| S-1 IOGPU sharing | closed for the public share APIs (test build) | `review/S1-IOGPU-2026-10-23.md`: shared texture, shared event and IOSurface creation return NULL under the profile; controls fired. Private driver selectors and the XPC handoff not tested (audit R2-11) |
| T2 IOSurface channel | closed in production (child `<h28>` and later) | The production child has no `IOSurfaceRootUserClient` rule; the kernel refuses the open; the `iosurface-open` self-test arm and its mutant prove it. Supersedes the 2026-10-22 "OPEN, CONFIRMED CHANNEL" row, which described the earlier profile |
| R7-T3 late-phase read-backs | closed (2026-10-22 build) | `review/R7T3-2026-10-22.md` |
| S3 share-mode, descriptor, open-log checks | closed, mutation-proven | `neg/final-2026-10-22.txt` and later; code unchanged since |
| N1–N8, S1c, S3–S7, R4-T4, A-21, T6 | closed (2026-10-20 to 2026-10-22 builds) | See `OPEN-ITEMS-CLOSURE-2026-10-22.md`; code in these areas unchanged. N3 is a limit, below |

## Measured on a different Mac, on a helper process

| Item | Status | Evidence |
|---|---|---|
| A-3 swap (P5a) | limit | <host-b>, macOS 27.0-build, canary in a helper process: 3 swap files, 0 hits. Not tested with the sealed engine or child on this Mac (audit R2-5-08). macOS encrypts swap on Apple Silicon |
| A-5 hibernation (P5d) | limit | <host-b>, macOS 27.0-build, canary in a helper process: real hibernate, 0 hits. The grader then could turn a failed read into 0 (audit C5-05, since fixed); not rerun with the fixed grader. Not tested with the sealed processes on this Mac. The image is encrypted with a Secure Enclave key |

## Limits stated in the claim

| Item | Statement |
|---|---|
| Prompt and reply length | Root can learn the prompt length and the reply length. The engine and the child exchange frames on a local `socketpair` whose byte counts follow the token counts (24+64+4×n for the request, 24+16+4×n for each reply frame), and root can read those byte counts with `fs_usage` with SIP on. The reply time also grows with the reply length. Network padding hides the reply length from the network only. Measured 2026-10-24 (`review/LENGTH-ROOT-2026-10-24.md`): root read prompt token counts 21 and 36 and the reply token counts exactly from the channel write sizes. (Audit R2-5-03, R2-5-04, R2-E-02) |
| Speculative-step pattern (R3-5-04, R4-5-02, R4-5-03) | Stated limit, decision 2026-10-24: documented, not fixed. Each reply frame holds one decoding step: retained draft rows plus, at the end, one stop or last budgeted token, so 1 to 9 tokens. Root reads one count per step and the number of steps with `fs_usage`. The pattern can carry information about the reply content; at temperature 0 (what `sealed-chat` sends) it repeats for the same prompt, so an attacker can check a guessed prompt against it. Measured on the current build (`review/SPEC-TEMP-2026-10-25.md`): at temperature 0 each of 4 open-ended prompts gave the same sequence in 3 of 3 runs and the 4 sequences differed; at temperature 0.6 the mean tokens per frame still separated kinds of text (2.35 to 5.52, margin 0.84). The earlier copy-task test (`review/SPEC-STEP-2026-10-24.md`) could not show a difference. A fix needs fixed token counts per frame at fixed times; padding alone does not hide the step count |
| Request length on the network | The sealed request is not padded: ciphertext = plaintext + 16 bytes (audit R2-E-09) |
| Status codes | 500, 503 and 422 show which provider limit a request hit (audit R2-E-07). A 503 can also come from a refusal during generation, so it is one bit about the prompt plus the reply so far (audit R4-5-09) |
| N3 trailing bytes | R2 checks `FIONREAD` once after the frame read. Bytes written later in the same spawn can arrive after the check. The claim is "bytes present at the check are refused" |
| No memory encryption | Apple Silicon gives none to third-party code. A kernel or GPU-driver defect breaks the claim |
| Full Security, SIP, swap encryption, sleep setting | Closed on the pinned engine (`sealed_posture.c`, `boot-posture`, `boot-posture-unit`, mutant `BAD_CSR`) and by the consumer macOS floor (`MinOSVersion = 27.0`, `refuse-old-macos`). Apple's certificate has no boot-mode or SIP field; in our M1 tests (macOS 27.0), App Attest refused a new key in 4 of 4 weakened boots (`Unexpected ACM requirement: 23`) and keys died across every restart (2 of 2), but that behavior is undocumented by Apple and the 12-cell A-11 recoveryOS grid has not been run on the M5 |
| A-2-dtrace-read | EXEMPT: SIP blocks the `syscall` provider; the control fails the same way |
| R4-T5 root control | EXEMPT: launchd refuses a foreign pid-domain bootstrap for any name. The control did not fire, so these arms are not evidence for P8 |
| A-4 Endpoint Security | EXEMPT: the kit client has no entitlement. Root can use the Apple-signed `/usr/bin/eslogger`, which shows events, not memory. No `eslogger` arm measures this (audit R2-02) |
| P8 Metal compiler service substitution | Not tested. The only test is R4-T5, and its control did not fire (audit R3-5-06, R4-5-10) |
| P5e panic dumps | Not measured |
| P3 other output channels | Not claimed. The claim names only the engine channel |

## Fixed after the round-2 audit (2026-10-24)

| Item | Fix | Proof |
|---|---|---|
| R2-E-01 refusal number in the engine log | Log line `request refused`, no number | Code: `main.swift`. Stored proof since round 3: accept arm `refusal-log-line` |
| R2-E-03 oversize chunk | Cut on Unicode scalars | Code checked by audit R3-2 (a copy of `chunks()` with 13 edge cases and 3,000 random strings, 0 failures). Stored runtime proof: accept arm `big-grapheme` (no 500); see the limit in the padding row. The engine repo has no Swift test target |
| R2-E-04 client accepts unpadded frames | Padded frames only, size and count checked | Go tests: unpadded refused, wrong size refused, 3 frames refused |
| R2-4-05 / R2-01 EXEMPT cause check | The gate reads the arm's own line (`arm_evidence`) with a full pattern; an arm with no line is refused | Tampered copies: "SIP" in "gossip" refused; A-4 FAIL line refused; outside-list EXEMPT refused |
| R2-4-04 required list | Full list (A 121, B 141 at the time; A 122, B 142 after the round-3 checks) in `sealed-accept/required.json`, read by both tools | Copy without the neg suite refused; duplicate name refused |
| R2-4-07 stored rows | `accepted` runs the current gates again; failures are REVOKED | Report `…162804Z` answers REVOKED |
| R2-4-06 harness provenance | Each report folder keeps `harness/accept.sh`, `matrix.py`, `required.json`; `tool_version` 2 | `…20261025ThhmmssZ/harness/` |
| R2-N1 stale test builds | Round 3: the harness recomputes the build ID of the staged child and of all 75 builds (74 test builds and the production build) and refuses a run on a mismatch (replaces the mtime check on one build) | Accept run: `source/child-is-current-production` PASS, `neg-build-check.txt` 75 current. Limit: the build ID hashes `runtime/` sources (incl. `*.hpp`, `*.metal`), `build_identity.py` and build constants. It hashes SealedGuard since the R2-4-02 fix. It does not hash the Makefile |
| R2-5-10 verifier text | "matches the pinned hash" | `consumer-chat.txt` of the accept run |

## Fixed after the round-3 audit (2026-10-24)

| Item | Fix | Proof |
|---|---|---|
| R3-4-04, R3-4-05, R3-06 EXEMPT gate | `matrix.py` opens the cited `<file>:<line>` in the report folder and requires the exact line and a full-line cause pattern. A-2 requires `child=0` and "does not match any probes". The kit grades A-2 FAIL first when `child>0` | Accept run: 4 EXEMPT rows pass the gate. Forged copies refused (session output only, no stored test) |
| R3-4-06 `required.json` | File mode 0444; its hash is in each report (`required_sha256`) and in `approved-required.txt` | Accept run report field `required_sha256` `<h29>…` equals the approved hash |
| R3-4-07, R3-4-08 harness and artifacts | `matrix.py` requires `tool_version` 2, an approved `tool_sha256`, harness copies with the same hashes, and an engine hash outside `REVOKED_ARTIFACTS` | Accept run `tool_sha256` `<h30>…` equals `approved-harness.txt`; `matrix.py accepted` answers yes; report `…162804Z` answers REVOKED |
| R3-01, R3-02 `gcore` control | The kit stops the decoy and its `sudo` parent by pid, checks the decoy pid after cleanup, and writes pid, rc, core size and hash to `gcore-ctl.txt`; PASS needs that file | Root pass `logs/tee-rootpass-<date>-<time>/gcore-ctl.txt` (accept run `…031333Z`): decoy pid 93884, rc 0, 81,920-byte core, no "still alive" line |
| R3-G1, R3-P1 stale builds and child binding | Required check `source/child-is-current-production` recomputes the staged child's build ID; `neg/build-all.sh --check` recomputes all test builds | Accept run: child build ID `src-<h31>…` verified; `neg-build-check.txt` lists 75 builds as current (74 test builds and the production build) |
| Root pass isolation (found in the first round-3 accept run) | `stop_server` killed the bash wrapper first, so the server tree moved to launchd and the harness counted it as foreign (report `…20261025ThhmmssZ`, level B INCOMPLETE). The kit now sends SIGTERM to the :8199 listener only and kills the wrapper last. The decoy check used `pgrep` by name and matched the A-1 control | Accept run: `root-foreign.txt` empty; level B ACCEPTED |

## Fixed after the round-4 audit (2026-10-25)

| Item | Fix | Proof (accept run `…20261025ThhmmssZ`, engine `<h19>`, unless named; the same arms passed again in `…20261025ThhmmssZ`) |
|---|---|---|
| R4-E-01 engine arms not required | The 11 section-6 arms are in `ENGINE_EXPECTED` and `required.json` (A 138, B 159) | Report `levels.A.required` lists them; all PASS |
| R4-E-02, R4-5-07 grapheme proof | `big-grapheme` measures the reply bytes | 3,000-byte cluster in 4 frames |
| R4-E-03 503 cause | `refusal-503-control`: the long prompt on the default budget is served | PASS before `refusal-503-body` |
| R4-E-04, R4-5-05, R4-4-12 thin evidence | Budget-range logs and the two `HOME` values are stored; `child-reproducible` requires two different `HOME` values | `engine-evidence.txt` |
| R4-E-08, R4-4-11 toolchain, retries | `evidence.sh` sets `DEVELOPER_DIR` and records Xcode, Swift and Metal versions; `engine_attempts` is in the report | Evidence header; report field |
| R4-E-09 Go v2 model hash | `sealed.ModelHashV2` with a test vector; `sealed-verify --hash-model-v2` | Go tests pass; the tool gives `<h32>…` for the package and child `<h25>` (session output) |
| R4-3-01 A-21 control | `mount-ctl.txt` records the control rc and its mount line; PASS needs both | `rootpass/mount-ctl.txt` |
| R4-3-02 R4-T4 control | One request to the second server; positive control: an unsandboxed Metal client compiles under the same capture, and the compiler service's cache writes must show (a test showed that `MTLCompilerService`, not the client, writes the cache) | PASS: 467 child events, request answered (`rootpass/answer4.json`, server log `Done`), 17 control rows (`rootpass/r4t4-control.txt`). Limit: rows are kept by the name `splash`, so the engine's own child can add rows; that can only turn a PASS into a FAIL |
| R4-3-03 to -07 kit stop and pids | `stop_server` re-records the tree, signals only recorded pids (never a foreign :8199 listener), fails when a recorded pid stays alive; `cleanup` checks it, writes its line before the copy and exits 71 on leftovers; pids with no start time are not recorded; A-1 control by user and name; decoy found under its own `sudo` job, flags from the running process | Cleanup line: leftover 0 kit pids, 0 control pids, stop rc 0; `root-foreign.txt` empty |
| F-11, R3-03 P10 engine arms | The engine pid's CD hash must equal the kit pin (`P10-engine-identity`); the P10 engine arms need the shared control | PASS |
| R4-4-02 evidence trust | The report records the sha256 of every file in its folder; `matrix.py` refuses an edited, missing or extra file, a cite outside the report's own folder, and a wrong `evidence_dir`; root-pass files are copied into `rootpass/` | 10 forged copies refused (session output, 2026-10-25) |
| R4-4-03, R4-4-06 harness provenance | `sealed-m5` is a git repo; `source/harness-tree-clean` refuses changes to executed files; `matrix.py` copies must be in `approved-matrix.txt` | PASS; edited `matrix.py` copy refused |
| R4-4-07 revocation | Child revocation list; `kit_engine_cdhash` and `kit_engine_modelhash` must equal the measured pins (`artifacts/kit-pins-equal`) | Revoked child and different kit pin refused |
| R4-4-08 A-2 pattern | Cites hold the whole line; the A-2 pattern is anchored at the exact line end | Real line accepted; line with appended FAIL text refused |
| R4-4-09, R3-4-10 row content | `matrix.py` refuses PASS with control FAIL, PASS or EXEMPT with empty evidence, required names not in `required.json`, and totals that do not follow from the rows | Each refused on a forged copy |
| R4-4-10 not-isolated rows | A row that is INCONCLUSIVE only because the run was not isolated is never made EXEMPT | Code (`accept.sh`) |
| R4-4-04 isolation | One shared suite lock (`tools/suite-lock.sh`) for `accept.sh`, `neg/run-all.sh`, `neg/build-all.sh` and `evidence.sh`; the watcher pattern covers relative-path commands; the PASS text names the 3-second sampling limit | `run/*-isolated` PASS |
| R4-H2, R4-E-07 guard copies | Required `source/guard-copies-equal`; the test launcher builds from the engine's `SealedSpawnC` sources | PASS |
| R4-B1 build-ID coverage | The build ID hashes `Makefile`, `dev/native.mk`, `dev/tools/build_config.py` and the guard compile flags | New child pin `<h25>`; 75 builds current |
| R4-S1 source binding | Required `source/child-commit` and `source/child-tree-clean`; the splash commit sits on top of upstream tag 1.0.2; `review/SPLASH-DIFF-1.0.2-2026-10-25.diff` stores the diff | PASS |
| R4-U1 CHUNKED-KV wording | Correction note in `CHUNKED-KV-2026-10-23.md` | Record |
| R4-5-02, R4-5-03 speculative-step text | Range 1 to 9 tokens; temperature test run | `review/SPEC-TEMP-2026-10-25.md` |
| R4-5-10 P8 | Listed as not tested; P5e and P3 rows added | Claim and limits table |
| R4-4-01 second assembly | <host-b> rebuild as user `<second-user>` | `review/SECOND-MAC-REBUILD-r4-2026-10-25.txt` |

## Open: tests

None. The speculative-step pattern (R3-5-04) is a stated limit (see "Limits stated in the claim").

## Fixed after the round-5 audit (accept run `…20261025ThhmmssZ`)

| Item | Fix | Proof |
|---|---|---|
| Home-folder default in the test probe source | `#error` if a test build does not set the sweep paths | Child `8083a338` source; 17 test variants pass the paths (audit R5-4) |
| Toolchain not in the child build ID | Build ID records SDK version and build, clang and metal versions; `accept.sh` and `stage-child.sh` set Xcode; `stage-child.sh` builds from a clean copy | `source/child-is-current-production` PASS; second-Mac build equal |
| App ID and signing identity in scripts | Read from the signed bundle (`scripts/app-id.sh`) or the environment | `grep` of the repos |
| Harness tree check | Covers `child/pin.txt`, `child/req-splash.bin`, `approved-matrix.txt`; leaves out the daily `neg/final-*.txt` records | `source/harness-tree-clean` PASS |
| Second-Mac build of the current pins | Staged from the commits; no profile, no host name, no HOME in the record | `review/SECOND-MAC-REBUILD-2026-10-25-r5.txt`: 0 failed |
| Personal data in run output | Entitlement audit counts identities only; root pass drops boot-policy nonces | `entitlement-audit.txt`, `root-pass.txt` of the run |
| `tools/reqgen` had no source | `tools/reqgen.swift` | A fresh build writes the same 82 bytes |
| Model files had no check tool | `tools/check-manifest.py` | 75 entries, 0 differ; a changed manifest gives 1 differ |
| Engine boot-posture gate and consumer macOS floor (`v0.1.1`, report `…20261026ThhmmssZ`) | `sealed_posture.c` checks `csr_get_active_config == 0`, empty `kern.bootargs`, encrypted swap, `kern.hibernatemode` in `{0,3}`, 0 non-Apple kexts and `IODeviceTree:/chosen` mode `1,1,1` at start, and re-checks SIP, swap and `hibernatemode` before each request inside R8; consumer default `MinOSVersion = "27.0"` | `boot-posture` PASS, `boot-posture-unit` (13 cases) PASS, `refuse-old-macos` PASS, mutant `BAD_CSR` PASS; second-Mac build `review/SECOND-MAC-REBUILD-2026-10-26-r6.txt` (0 failed) |

## Open gaps

| Gap | Status | Record |
|---|---|---|
| Temperature-0 guess check (speculative-step sequence) | Open, documented 2026-10-25 (operator decision). Not fixed. Three possible fixes: one frame at the end of generation, a minimum temperature, or one token for each step. None built or tested | `review/SPEC-TEMP-2026-10-25.md`, section "Gap" |
| Shared prefix cache (cross-consumer timing) | Open, documented 2026-10-25 (audit R5-4-01). Not fixed. Possible fixes: a per-session cache key, clear after each request, or no prefix cache in the sealed build | `review/PREFIX-CACHE-GAP-2026-10-25.md` |

## Open: independence

| Item | Status |
|---|---|
| R2-4-01 second assembly | Closed for a second Mac and a second user, 2026-10-25: on <host-b> (Mac17,7, macOS 27.0-build), user `<second-user>` built child `<h25>` and engine `<h19>` from `git archive` copies of commits `<h33>` and `<h34>` with the same Xcode 27.1 and Metal toolchain: child bytes equal (`<h35>…`), CD hash equal to the pin, engine MATCH (`review/SECOND-MAC-REBUILD-r4-2026-10-25.txt`, script `tools/second-mac-rebuild.sh`). The first attempt failed because a local metal shim dropped the SDK version from every kernel object; the record keeps it. Open: an independent party (both Macs are the operator's) |
| R2-4-02 `$HOME` in the child build ID | Fixed 2026-10-24. SealedGuard (`sealed_guard.c`, `sealed_guard.h`, byte-identical copies) is in `splash/runtime/sealed/guard/` with a relative include path, so the build ID hashes it and no `/Users` path enters the flags or the binary. `child-repro-check.sh` builds the second copy with `HOME=/tmp/child-repro-home`; accept run `child-reproducible` PASS with the same bytes and CD hash `<h24>`. Limit: same Mac, same user account. Two byte-identical copies of SealedGuard exist (engine `Sources/SealedSpawnC/`, child `splash/runtime/sealed/guard/`); no check yet refuses a build when they differ |
| R2-4-03 source location | Engine commits up to `<h34>` are only on this Mac; the hub is at `<h16>`. The client fix in `proxy-router` is also only on this Mac. The child source (`splash/`, commit `<h33>`, on top of incoai/splash 1.0.2) and the harness (`sealed-m5`, commit `<h36>`) are local git repos with no remote |
| Dedicated App ID | The engine attests as the borrowed `<bundle-id>` |
| Public source and evidence | Not published |
| External builder | None |
