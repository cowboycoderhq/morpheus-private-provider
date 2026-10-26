# AUDIT v2 round 2, auditor 1: child on the accepted build (2026-10-24)

Scope: the child with CD hash `<h23>` (`child/pin.txt`). This covers the round-1 child findings, the S-1 and T2 test hooks, R2 (with N3), R5 (with `iosurface-open`), R4, R6, and the suite record of the accepted run.
Method: read-only. I read the source and used `strings -a`, `nm -m`, `nm -u`, `otool -L`, `codesign -d`, `diff`, a Python Mach-O byte compare, and a Python recomputation of the build identity with `dev/tools/build_identity.py` (`python3 -B`, so no files were written). I did no build and no run. I did not start or stop the engine.

## Pre-registered falsifiers

1. A round-1 finding that a record calls fixed is not fixed in the current source or binary.
2. `child/splash` holds a `SEALED_TEST` string, a hook symbol, hook text, or a hook that a runtime input can reach.
3. A hook in `main.mm`, `Bootstrap.mm` or `sealed_tee_probe.*` compiles into a build that has no `SEALED_TEST_*` define.
4. R2 accepts a trailing-byte frame that is present at the check, or a v2 budget outside [256 MiB, 1 TiB].
5. The production profile has an `IOSurfaceRootUserClient`, write, network or second mach-lookup rule. Or the `iosurface-open` arm can pass without a sandbox denial.
6. The accepted suite record was not made on `<h23>`, or on code that is equal to it. Or one of its 95 cases asserts no specific reason.

Results: falsifiers 2, 3, 4 and 5 did not fire. Falsifier 1 did not fire, because no round-1 child finding is recorded as fixed in code. Ten of them are still open. Falsifier 6 fired in its first part. The record does not show that the 88 test-build cases ran on the `1c3e` source. I closed that gap by hand: the code is equal (R2-N1).

## Key measurements

- **The current source is the source of the accepted child.** `child/splash` embeds one build id, `src-<h72>…b5bbd1`. I recomputed the identity from the current `splash/runtime` tree with `SEALED_DEFS=-DSPLASH_SEALED`, and I got `src-<h72>`. The compiler flags are hashed constants of the identity (`splash/Makefile:203-208`). So the production compile had no `SEALED_TEST_*` define.
- **The S-1 edit adds no production code.** I compared the round-1 child `<h22>…` (`scratch/ckv-pin-a/splash`, CD hash checked) with `child/splash` (`1c3e…`). Both files are 3,307,072 bytes. Before the signature, 74 bytes differ, and they are in two places only. One place is `LC_UUID` (offset `0x788`, 16 bytes). The other is the build-id string (`src-<h39>…` against `src-<h72>…`, offset `0xcebfd`). All code and all other data are equal.
- **The only source change since the <time> test builds is the S-1 edit.** `find splash/runtime -newer splash/build-reason/splash` lists four files only: `sealed_tee_probe.h` (<time>), `Bootstrap.mm` and `main.mm` (<time>), and `sealed_tee_probe.mm` (<time>). The diff against the pre-S-1 copy `scratch/k2-src/runtime` (<time>) shows these items:
  - one call `sealed_s1_share("sandboxed");` at `main.mm:529`,
  - one call `sealed_s1_share("loaded");` at `Bootstrap.mm:228`,
  - a header block with an inline no-op `#else` branch (`sealed_tee_probe.h:39-48`),
  - a body block `#if defined(SEALED_TEST_S1_SHARE)` … `#endif  // SEALED_TEST_S1_SHARE` (`sealed_tee_probe.mm:1229-1463`).
  The other differences in `k2-src` (`MetalBackend.*`, `Q8PageStorage.mm`) are K-2 test edits that exist only in the copy (`SEALED_TEST_K2_KVDUMP`).
- **The test builds are bound to the pre-S-1 source.** I recomputed the identities with the pre-S-1 versions of the four files:
  - production flags give `src-<h39>…dd119b2`, which is the id inside `9c84`;
  - `build-reason` flags give `src-<h73>…48613208`, which equals `splash/build-reason/engine/build-identity.json`.
- **Hygiene of `child/splash`.** Each of these counts is 0 in both `strings -a` and `nm -m`: `SEALED_TEST`, `test: `, `test: s1`, `test: t2`, `tee-probe`, `sealed-reason`, `mutant`, `r7: `, `r7i`, `ckv`, `newSharedTexture`, `SharedTextureHandle`, `newSharedEvent`, `MTLSharedEventHandle`, `IOSurfaceRootUserClient`, `IOSurfaceCreate`, `kIOSurfaceIsGlobal`, `NSXPC`, `xpc_`, `bootstrap_check_in`, `bootstrap_register`, `newMTL4CommandQueue`, `updateBufferMappings`, `NSKeyedArchiver`, `archivedData`, `newHeap` and `newBufferWithBytes:`. The S-1 service name `com.sealed.s1.host` is absent. `nm -m | grep -iE 'sealed_(s1|t2|tee|r7)|t2f|copyForTest'` is empty. The only `sealed_*` symbols are the R1 guard, R2, R4, R5, R6 and the reason functions. `sealed_reason_open` opens a file only under `#ifdef SEALED_TEST_REASON_FILE` (`sealed_r2.cpp:24-26`). `otool -L` shows Foundation, Metal, IOKit, libobjc, libc++, libSystem and CoreFoundation, and no IOSurface framework. `nm -u` has `_bootstrap_look_up` (the R5 mach-lookup arm) and `_sandbox_init_with_parameters`, and no IOSurface, XPC or archiver import.
- **No hook can run without a define.** Every `SEALED_TEST_*` guard in `splash/runtime` has one of two forms:
  - a positive guard (`#if defined(...)`) that adds test code;
  - a negative guard that keeps a production check when the define is absent: `main.mm:475` `!defined(SEALED_TEST_NO_R1)`, `main.mm:508` `#ifndef SEALED_TEST_NO_SANDBOX`, `main.mm:522`, `sealed_r5.mm:156`, `sealed_r6.cpp:361`, `:720`, `:724`, `:727`, `:730`.
  The `#ifndef` lines in `sealed_tee_probe.mm` only set default values inside guarded blocks. Outside `sealed_tee_probe.mm`, `splash/runtime` has no `getenv` call, so no runtime switch exists.
- **The running child is the accepted child.** `child/splash` pid 3513 (parent `SealedEngineV2` pid 3348) has `codesign -dvvv <pid>` `CDHash=<h23>`.

## Findings

| ID | Severity | Area | Finding | Evidence | Recommended action |
|---|---|---|---|---|---|
| R2-N1 | MEDIUM | Suite / evidence binding (round-1 N-1, now worse) | The accepted suite ran 88 of 95 cases on test builds made at <date> <time>. Those builds come from the source before the S-1 edit (<time>-<time>), not from the `1c3e` source. Round 1 said "the test builds are newer than every source file", and that is no longer true. The accept harness records the test-build mtimes but does not check them against the child's source, so it would accept a stale test set after a real code change. In this run the impact is nil. I proved this by hand: the source change is test-only code, `build-reason` = pre-S-1 source + the reason define, and `1c3e` differs from `9c84` only in `LC_UUID` and the build-id string. Only the 7 `L-*` cases run on `child/splash`. | `stat`: `splash/build-reason/splash` <date> <time>, `splash/build/splash` <date> <time>. `neg/run-all.sh:32` (`cp splash/build-reason/splash test-child/splash`). `sealed-accept/reports/…20261024ThhmmssZ/neg-inputs-before.txt` (`splash/build-reason/splash 1792782123`, `child/splash 1792819226`). `sealed-accept/accept.sh:153-157` (snapshot only), `:233` (`splash_tree_build_id` from `splash/build` only). Identity recomputation and the byte compare above. | Rebuild with `neg/build-all.sh` before each accepted suite run. In `accept.sh`, add a gate: every `splash/build-*/engine/build-identity.json` must be recomputable from the current source and its own `SEALED_DEFS`, or must be newer than every runtime source file. Record this file as the evidence for the 1c3e equivalence. |
| R2-C1 | LOW | R2 / N3 (round-1 C-1) | The code has not changed. `FIONREAD` is still checked once, right after the frame read, and no second check comes before `SLLD`. `OPEN-ITEMS-CLOSURE-2026-10-22.md:11` accepts this as a limit: "bytes present at the check are refused". `README.md:84` still says "Fixed and tested". The test is still racy: two `write` calls. Across the 22 `neg/final-*.txt` records that have this case, only `neg/final-2026-10-22-run1.txt` has `FAIL [frame-trailing]`. The accepted run refused it with the exact text. The engine sends the frame in one `write_all` (`sealed_bringup.c:85`). | `splash/runtime/sealed/sealed_r2.cpp:314-319`; `neg/B/r2neg.c:133-134`; `README.md:84`, `:205-207`; `review/OPEN-ITEMS-CLOSURE-2026-10-22.md:11`. | Change `README.md:84` to the narrowed claim. Optionally, add a second `FIONREAD` check just before `SLLD`, and split the test into a single-`write` case and a delayed case. |
| R2-C2 | LOW | Suite / R2 (round-1 C-2) | Still open. The `frame-trailing` regex is only `code=8`. The recorded reason is the right one. | `neg/run-all.sh:60`; accepted `neg-run-all.txt:21` (`refused code=8: bytes after the manifest in the config frame`). | Match `bytes after the manifest in the config frame`. |
| R2-C3 | LOW | R2 / v2 budget (round-1 C-3) | The range check has not changed and is correct (`sealed_r2.cpp:306-313`). The suite still has no case for 1 TiB + 1, for the boundaries, or for a short v2 frame. `frame-kv-budget` still asserts only `LOADED`. The accepted engine `<h74>` can send v2, but only when `SEALED_KV_BUDGET_BYTES` is set (`put32(p + 4, kv_budget ? 2 : 1)`). The running engine's environment has no `KV_BUDGET`, so the accepted child gets v1 and the 16 GiB default. No record shows a v2 frame from the engine that the child accepted. `CHUNKED-KV-2026-10-23.md:66,273` still says that the engine sends only v1. That is stale for the code, but true for the default. | `~/projects/morpheus-pnode/sealed-engine-v2/Sources/SealedSpawnC/sealed_bringup.c:70-85`; `main.swift:51-58`; `scripts/start-engine.sh:6,11`; `ps eww -p 3348` (0 `KV_BUDGET` entries); `neg/run-all.sh:64`. | Add the edge cases and one engine-sent v2 load with the applied budget recorded. Correct the chunked-KV record. |
| R2-C4 | MEDIUM | Records (round-1 C-4) | Still open, and now more stale. `README.md:6` names pin `<h22>…` and says that `child/` "is not restaged". The staged child is `1c3e`. `README.md:17` says 77 cases. No `neg/final-*.txt` header records the child pin. The `# build:` line is the run time, not the build time. Only the `facts.tsv` of the accepted run binds the 95 cases to `child_pin 1c3e…`. | `README.md:6`, `:17`, `:84`, `:233`; `neg/run-all.sh:12`; `sealed-accept/reports/…20261024ThhmmssZ/facts.tsv` (`child_pin`, `child_cdhash`). | Update the README. Write the child pin and the build-reason identity into the header of each suite record. |
| R2-S1 | LOW | R5 / IOGPU (round-1 S-1) | Mostly addressed. `review/S1-IOGPU-2026-10-23.md` tested the public Metal and IOKit share paths under the production profile with fired controls. Shared texture, shared event and IOSurface creation all returned NULL. `mach-register` and arbitrary `mach-lookup` are refused. Two record problems remain: (a) the S-1 record says "CLOSED on every path", but its residual 2 says that the private `IOGPUDeviceUserClient` selectors were not probed; (b) `CLAIM-v2-2026-10-23.md:22` still says that IOGPU "is not examined (audit S-1)". The profile is unchanged (`sealed_r5.mm:133`). | `review/S1-IOGPU-2026-10-23.md:7`, `:182-187`, `:201`; `review/CLAIM-v2-2026-10-23.md:22`. | Word the S-1 verdict as "closed for public APIs; private selectors not probed". Update the claim row to cite the S-1 record. The claim scope (IOSurface only) stays correct. |
| R2-S2 | LOW | R5 self-test (round-1 S-2) | Still open. `sealed_r5.mm` has not changed since <date> <time>, and the arm set is the same: no shm, `fork`, `bootstrap_check_in` or tokenizer-read arm. The suite stores only the `iosurface-open` line. The arm accepts only `kIOReturnNotPermitted` (`sealed_r5.mm:367`), and the allow mutant is still refused. So this arm is not vacuous. | `sealed_r5.mm:356-368`; accepted `neg-run-all.txt:3`, `R5-mutant-ALLOW_IOSURFACE` line. | As in round 1. |
| R2-R4 | LOW | R4 (round-1 R4-1) | Still open. R4 has no negative case or mutant in the 95. The code has not changed. | `sealed_r5.mm:72-88`; `neg/run-all.sh` (no R4 case). | As in round 1. |
| R2-F | LOW | R6 (round-1 F-1, F-2, F-3, N-4) | All four are still open. `sealed_r6.cpp` (<date> <time>) and `FdTransport.cpp` (<date> <time>) have not changed. `audit_fds` checks only vnode descriptors (`:554`). No case plants a hazard between `SLLD` and an input. Some branches have no case. `R6-symlink` and `R6-missing` still both give `open failed` with no errno. | `sealed_r6.cpp:267`, `:554`; `engine/FdTransport.cpp:195-203`; accepted `R6-symlink` and `R6-missing` lines. | As in round 1. |
| R2-N2 | LOW | Suite (round-1 N-2) | Still open. `cache-symlink` is refused by the TMPDIR listing check, not by the S1c `lstat` check. | accepted record: `refused code=3: TMPDIR must hold only metal-cache/`. | As in round 1. |
| R2-N3 | LOW | Hygiene (round-1 N-3) | The case still checks `splash/build/splash`. I showed that its bytes equal `child/splash` except for the signature and the three header fields that follow from it: `__LINKEDIT` filesize and vmsize, and the `LC_CODE_SIGNATURE` size (6 bytes at 1713-1730 and 2596-2597). So the count holds for the child. The dead `MTLSharedEventListener` import, `sharedListener` and `notifyListener` are still present. `newSharedEvent` is called only at `MetalBackend.mm:926`, in a branch that the sealed build does not reach. | Python Mach-O compare; `nm -m child/splash`; `MetalBackend.mm:474`, `:514`, `:926`. | Point the case at `child/splash`. Word the claim as "no MTLSharedEvent is created". |
| R2-K2 | INFO | Chunked KV residue (round-1 K-2) | Addressed with a stated limit. 16.1 GB of fresh memory, taken by another process while the child ran, gave 0 hits, and the heap control found 65,520 of 65,520. The record says that user space cannot show page identity. The child has no `newHeap` (count 0), so the one path that returned old bytes (a heap sub-allocation in the same process) does not apply. | `review/K2-FREED-KV-2026-10-23.md:9-13`, `:79-86`; `neg/k2-2026-10-23.txt`. | None. |
| R2-H | INFO | Hooks (task item 2) | The S-1 and T2 hooks compile out of the production child, and no hook is reachable without a define. Evidence: the identity recomputation (flags = `-DSPLASH_SEALED` only), the byte equality with `9c84` outside `LC_UUID` and the build id, the zero counts and empty symbol searches above, and the guard inventory. One limit: the build identity does not hash `sealed_guard.c` (outside the tree, already reported as A4-08). The byte compare covers its compiled code. | Key measurements above. | None for the child. Keep A4-08 open. |

## Round-1 finding status

| Round-1 ID | Status on `1c3e` |
|---|---|
| C-1 N3 race | Accepted as a limit (`OPEN-ITEMS:11`). The code has not changed. `README.md:84` still says fixed (R2-C1). |
| C-2 loose `frame-trailing` regex | Open (R2-C2). |
| C-3 budget edges, engine v2 | Open. The engine can send v2 now, but no record shows it (R2-C3). |
| C-4 stale records | Open and worse (R2-C4). |
| S-1 IOGPU share channel | Addressed for public APIs. Records overstate the result (R2-S1). |
| S-2 missing self-test arms | Open (R2-S2). |
| S-3 sandbox not widened | Still true. `sealed_r5.mm` has not changed. |
| R4-1 no R4 negative | Open (R2-R4). |
| F-1, F-2, F-3 R6 coverage | Open (R2-F). |
| N-1 suite on test builds | Open and worse. The test builds are older than the child source. The code is equal, which I proved by hand (R2-N1). |
| N-2 `cache-symlink` label | Open (R2-N2). |
| N-3 hygiene target | Open. The result holds for the child by byte equality (R2-N3). |
| N-4 `open failed` ambiguity | Open (R2-F). |
| K-1 no R6 bypass | Still true. No runtime file except the S-1 files changed. |
| K-2 freed KV | Addressed (R2-K2). |
| M-1 mutations | Still sound. The mutation lines and regexes have not changed (`neg/run-all.sh` mtime <date> <time>). |

## Accepted suite record (task item 4)

- The accepted record is `sealed-accept/reports/Mac17,7-27.2-beta-20261024ThhmmssZ/neg-run-all.txt`, written <time> to <time>, with 95 PASS, 0 FAIL and `# result: 0 failed`. `facts.tsv` binds it to `child_pin`, `child_cdhash` `<h23>…` and `neg_inputs_changed 0`.
- The record is equal to `neg/final-2026-10-24.txt` (<time> build, <time> run) except for the `# build:` time and the volatile pids, ports, handler addresses and timings.
- Every case that ends in `exit=113` has a non-empty reason or a hook line, because my parse found no refusal without text. The refusal regexes name the code and the exact text, except `frame-trailing` (`code=8` only, R2-C2).
- The cases that expect a load are controls or mutants. Each mutant line needs the mutant name and the hook proof. `frame-kv-budget` asserts only a load (R2-C3).
- The 7 `L-*` cases ran on `child/splash` (`GOOD=$(cat child/pin.txt)`). The other 88 ran on the <time> test builds (R2-N1).

## Verdict for the child area

The accepted child `<h23>` is the current source, built with `-DSPLASH_SEALED` and no test define. Its code is byte-equal to the round-1 child `<h22>`. The only differences are `LC_UUID` and the embedded build id. So the S-1 and T2 hooks compile out completely, and no hook is reachable without a test define. R2, R4, R5 and R6 have not changed since round 1, and the round-1 conclusions still hold:
- R2 refuses an out-of-range v2 budget and trailing bytes that are present at the check.
- The profile has no `IOSurfaceRootUserClient`, write or network rule.
- The `iosurface-open` arm accepts only `kIOReturnNotPermitted`, and its allow mutant is refused.
- The R6 funnel and self-audit have not changed.

The 95-case record has specific reasons, and `facts.tsv` binds it to `1c3e`. But 88 cases ran on test builds from the pre-S-1 source. That is harmless here only because I proved code equality by hand, and the harness has no gate for it (R2-N1, MEDIUM). The README and the claim records are stale for the pin, the case count, N3 and IOGPU (R2-C4, R2-C1, R2-S1). Most round-1 test gaps are still open as LOW items. I found no CRITICAL or HIGH issue in the child area.
