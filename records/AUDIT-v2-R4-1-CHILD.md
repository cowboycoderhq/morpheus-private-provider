# AUDIT v2 round 4, auditor 1: child on the round-4 build (2026-10-24)

Scope: the child with CD hash `<h23>` (`child/pin.txt`), source commit `bd77b6c` in `splash/` (branch `sealed-v2`), accept report `sealed-accept/reports/Mac17,7-27.2-beta-20261025ThhmmssZ.json`.

Task items:
1. The status of each round-3 child finding (fixed, open or accepted).
2. The HOME fix: no absolute or user path in the build-ID constants or the binary. The two SealedGuard copies are byte-identical. Other SealedGuard copies in use. Drift checks.
3. `child/splash` equals a fresh production build of `bd77b6c` and holds no test code.
4. The `splash` git repo: the committed tree against the build inputs, `.gitignore`, and the diff against upstream `incoai/splash` 1.0.2.
5. New issues.

Method: read-only. I used `codesign -d`, `strings -a`, `nm -m`, `nm -u`, `otool -l`, `otool -L`, `shasum`, `cmp`, `git ls-files`, `git status --ignored`, `git archive`, `unifdef` and a Python Mach-O byte compare. I ran `make -s check-build-identity` (the task names it; it only reads) and `neg/build-all.sh --check` (it only reads), with `PYTHONDONTWRITEBYTECODE=1`. `git status --porcelain` in `splash/` was empty before and after. My scratch files are `/tmp/r4c1-*` only. I did no build and no run. I did not start or stop the engine.

## Pre-registered falsifiers

1. A round-3 child finding that a record calls fixed is not fixed in the source, the binary or the harness.
2. A string `/Users/`, `<developer>`, a `HOME` path or another user path occurs in the build-ID constants, `build-identity.json`, `BuildIdentity.hpp` or `child/splash` (`strings`, `otool -l`, stabs).
3. `splash/runtime/sealed/guard/sealed_guard.{c,h}` differ from `sealed-engine-v2/Sources/SealedSpawnC/sealed_guard.c` and `include/sealed_guard.h`.
4. A build script, a launcher, a test or the Makefile still reads `~/projects/morpheus-pnode-sealed-v2/.../SealedGuard`.
5. No check compares the two SealedGuard copies, so they can drift with no alarm.
6. `make check-build-identity` against `child/splash` fails, or `child/splash` differs from `splash/build/splash` in code bytes.
7. `child/splash` holds a test string or a test symbol.
8. A file that the production build reads is not in `git ls-files`, or `.gitignore` hides one.
9. A change against upstream 1.0.2 outside the sealed scope is not described in the records.

Results:
- Falsifiers 2, 3, 4, 6, 7 and 8 did not fire.
- Falsifier 5 fired. The closure states it as a limit (R4-H2).
- Falsifier 9 fired once, for a record sentence, not for code (R4-U1).
- Falsifier 1 fired once, for a stale value in the closure (R4-R1).

## Key measurements

- **Pin and signature.** `codesign -dvvv child/splash`: `CDHash=<h23>`, `flags=0x10002(adhoc,runtime)`, `Identifier=sealed.splash`. `splash/build/splash` is linker-signed, `CDHash=<h73>…`.
- **Build-ID constants** (`make -n check-build-identity SEALED_DEFS=-DSPLASH_SEALED`):
  - `engine_cxxflags=-std=c++20 -O3 -Wall -Wextra -Werror -Iruntime -Iruntime/sealed/guard -mmacosx-version-min=26.4 -DSPLASH_SEALED`
  - `engine_objcxxflags=` the same plus `-fobjc-arc`
  - `engine_linkflags=-framework Foundation -framework Metal -framework IOKit -Wl,-sectcreate,__TEXT,__splash_metal,build/splash.metallib`
  - `production_metalflags=-std=metal4.0 -O3 -Wall -Wextra -Werror -Iruntime -mmacosx-version-min=26.4 -DSPLASH_KV_CHUNKED`
  - All paths are relative. There is no `$(HOME)` in `Makefile`, `dev/Makefile` or `dev/native.mk`. The only `abspath` is `SPLASH_MAKEFILE` (`Makefile:16`), which only the install targets use.
- **Stamp and header.** `build/engine/build-identity.json` holds only `build_id`, `schema_version` and `source_sha256`. `BuildIdentity.hpp` holds only the two `#define` lines. The id is `src-<h29>`.
- **Paths in the binary.** `strings -a child/splash`: 0 matches for `/Users`, `<developer>`, `projects`, `morpheus`, `sealed-backends`, `SealedGuard`, `sealed_guard` and `/var/folders`. The absolute strings are system paths of the R5 profile and the self-test (`/System/...`, `/usr/...`, `/private/etc/hosts`, `/private/tmp/r5-%u`, `/dev/null`). The `HOME` matches are the R2 message `environment must be exactly HOME and TMPDIR` and `HOME=`.
- **Load commands.** `otool -l`: no `LC_RPATH` and no `LC_DYLD_ENVIRONMENT`. `LC_LOAD_DYLINKER /usr/lib/dyld`. Seven `LC_LOAD_DYLIB`, all under `/usr/lib` or `/System/Library/Frameworks`. `LC_SOURCE_VERSION 0.0`. `nm -ap` shows 0 stab entries, so there are no `N_OSO` object paths.
- **Identity check.**
  - `make -s check-build-identity SEALED_DEFS=-DSPLASH_SEALED BINARY=../child/splash`: `{"build_id": "src-<h29>…", "verified": true}`, exit 0.
  - The same check without `BINARY` (that is, `splash/build/splash`): verified, exit 0.
  - Controls (each must fail): without `SEALED_DEFS` gives `generated build identity is stale`, exit 2. `BINARY=../test-child/splash` gives `embeds build identities ['src-<h74>…'], expected only src-<h29>…`, exit 2. `BINARY=../scratch/ckv-pin-a/splash` (child `<h21>`) gives a mismatch on `src-<h37>…`, exit 2.
  - `bash neg/build-all.sh --check`: 75 lines `current`, 0 `STALE`, exit 0. The accept report's `neg-build-check.txt` also lists 75 `current`.
- **Committed tree gives the same id.** I extracted `git archive bd77b6c` to `/tmp/r4c1-sv` and recomputed the id with `build_identity.build_id` and the constants above. The result is `src-<h29>…`, with 150 inputs (149 `runtime/` files and `build_identity.py`).
- **Byte compare with the production build.** `child/splash` and `splash/build/splash` have the same code-signature offset (3300368). Before it, only 6 bytes differ: offsets 1713, 1728-1730 (`__LINKEDIT` size) and 2596-2597 (`LC_CODE_SIGNATURE` size). The `__splash_metal` section (1,908,448 bytes) is equal to `splash/build/splash.metallib`.
- **Fresh builds.** The engine evidence runs `build/evidence-<date>-<time>.txt:2` and `…<time>.txt:2` (the accept report copy) say `PASS [child-reproducible] two folders give the same bytes and CD hash <h23>`. `scripts/evidence.sh:29-32` requires `SAME` and `a=$pin b=$pin`. `scripts/child-repro-check.sh:13-21` builds `/tmp/child-repro-a` with `$HOME` and `/tmp/child-repro-bb` with `HOME=/tmp/child-repro-home`. Both copies are `rsync` copies of the working tree at that time, not `git archive` exports. Only `.gitignore` (<time>) is newer than `build/engine/build-identity.json` (<time>).
- **Compare with the P6 child.** `child/splash` against `scratch/ckv-pin-a/splash` (`<h21>`, the child of the P6 arms): same length (3307072) and same signature offset. 78 bytes differ before the signature. 64 bytes are in the build-ID string at offset 846841, 16 bytes are `LC_UUID` (offset 1928, `82DB6112-…` against `BD9103B8-…`), and the rest are none. So the code is equal.
- **Test code.** `strings -a child/splash` gives 0 for each of `SEALED_TEST`, `test:`, `sealed-reason`, `r7:`, `T2F`, `SWEEP`, `KEEP_FD`, `bypass`, `plant`, `canary`, `getenv`, `s1:`, `ckv:`, `interpos`, `newSharedEvent`, `newMTL4CommandQueue`, `updateBufferMappings`, `IOSurfaceRootUserClient`, `IOSurfaceCreate` and `MTLSharedEventListener`. `sharedListener` and `notifyListener` occur once each (the dead import, R2-N3). Positive control: `build-reason/splash` and `build-tee/splash` give `sealed-reason` 1 each, and `build-r7-interpose/splash` gives `test:` 2 and `r7:` 12.
- **Symbols and imports.** `nm -m`: the only test-pattern match is `Engine::sweepTerminal`, which is production code. `nm -u`: 284 imports, with `_setenv` (R5 `MTL_SHADER_CACHE_SIZE`) and no `getenv`, `dlopen`, `dlsym`, `fork`, `posix_spawn`, `shm_*`, `IOSurface*`, `ptrace` or `task_for_pid`. `otool -L`: Foundation, Metal, IOKit, libobjc, libc++, libSystem and CoreFoundation.
- **SealedGuard copies.**
  - `sealed_guard.c`: sha256 `<h75>…87c2` in `splash/runtime/sealed/guard/` and in `sealed-engine-v2/Sources/SealedSpawnC/`. `cmp` reports them equal.
  - `sealed_guard.h`: sha256 `<h76>…a938` in `splash/runtime/sealed/guard/` and in `sealed-engine-v2/Sources/SealedSpawnC/include/`. The engine header is in `include/`, not next to the `.c` file.
  - All 70 `sealed_guard.[ch]` files under `~/projects` have one of these two hashes. This includes `morpheus-pnode-sealed-v2`, `rescue-…`, `morpheus-pnode/sealed-engine` (v1) and the `build-glm` waves.
- **Users of SealedGuard now.**
  - Production child and all 75 test builds: `Makefile:260-264` compiles `runtime/sealed/guard/sealed_guard.c` with `-Iruntime/sealed/guard`.
  - Test launcher `launcher/sealed-launch` and `neg/R7/sealed-launch-dlv`: `neg/build-all.sh:170-183` compiles `$G=splash/runtime/sealed/guard/sealed_guard.c` with `-I $S/include` and `$S/sealed_spawn.c`, where `S=~/projects/sealed-backends-spike/build-glm/wave-2026-10-06/code-s5-canary/staged`. `sealed_spawn.c:11` has `#include <sealed_guard.h>`, so it reads the header from `$S/include/sealed_guard.h` (sha256 `<h76>…`, a third copy). `$S/sealed_spawn.c` (sha256 `<h77>…`) differs from the engine's `sealed_spawn.c` (`<h78>…`) in line 48 only: `extern int proc_pidinfo(...)` against `#include <libproc.h>`.
  - Engine: its own `Sources/SealedSpawnC/` copy.
  - `grep` for `morpheus-pnode-sealed-v2` in every `*.sh`, `*.py`, `*.swift`, `Makefile`, `*.mk`, `*.c` and `*.json` of `sealed-m5/` (outside `scratch/`) and `sealed-engine-v2/`: 0 matches. The path occurs only in older review records.
  - No script compares the copies: `grep` for `sealed_guard`, `SealedGuard` and `runtime/sealed/guard` in `sealed-engine-v2/scripts`, `Package.swift`, `sealed-accept/*.sh`, `*.py` and `tools/*.sh`: 0 matches.
- **splash git repo.**
  - One commit `<h79>…` (<date> <time>, "sealed v2 child source (production pin <h23>)"). It has no parent and no remote.
  - `git ls-files`: 221 files. `git status --porcelain`: empty. `git ls-files -o -i --exclude-standard --directory` outside `build*`: only `dev/tools/__pycache__/` and `server/__pycache__/`.
  - Production build inputs: `Makefile`, `dev/Makefile`, `dev/native.mk` (`-include` at `Makefile:330`, `dev/Makefile:34`), `dev/tools/build_config.py`, `dev/tools/build_identity.py` and 149 `runtime/` files (1 `.c`, 35 `.cpp`, 27 `.h`, 52 `.hpp`, 23 `.metal`, 11 `.mm`). All are tracked. No `#include "…"` names a non-header file.
  - `.gitignore` (`build/`, `build-*/`, `.venv`, `.venv.install.lock`, `install/models/`, `install/download-token`, `.DS_Store`, `__pycache__/`, `.ruff_cache/`, `dist/`): no directory under `runtime/` or `dev/` matches `build`, `build-*`, `dist` or `.venv`.
  - `dev/Makefile:2` runs `git describe --tags --always` at parse time. Only the package targets use `RELEASE_VERSION`, so it does not enter the binary.
- **Upstream diff.** The upstream clone `~/projects/sealed-backends-spike/splash` has origin `https://github.com/incoai/splash.git`, and tag `1.0.2` is `<h80>…`. `git diff --no-index --shortstat` against the exported trees: 1.0.1 gives 105 files, 1.0.2 gives 42 files (+4662/−69) and 1.1.0 gives 238 files. So 1.0.2 is the base. No upstream file is missing in `bd77b6c`.
  - Added: `.gitignore`, `runtime/sealed/{sealed_r2.cpp,sealed_r2.h,sealed_r5.h,sealed_r5.mm,sealed_r6.cpp,sealed_r6.h,sealed_r7_interpose.h,sealed_tee_probe.h,sealed_tee_probe.mm}` and `runtime/sealed/guard/sealed_guard.{c,h}` (11 source files).
  - Changed: `Makefile` and 29 runtime files, which are `engine/{Bootstrap.mm,Cache.cpp,Cache.hpp,Engine.cpp,Engine.hpp,FdTransport.cpp,KvPool.cpp,KvPool.hpp,MemoryPlan.cpp,MemoryPlan.hpp,NativeRuntime.hpp,RuntimeResources.hpp,RuntimeResources.mm}`, `main.mm`, `metal/{MetalBackend.hpp,MetalBackend.mm,abi/ExecutionGeometry.h}`, `metal/kernels/common/{q8_attention_tile.h,q8_paging.h,q8_store_row.h}`, `metal/kernels/{decode,prefill}/{attention_q8.metal,attention_q8_store.metal}`, `model/{ModelDescriptor.mm,WeightStore.cpp}` and `ops/{PagedKv.hpp,Q8PageStorage.hpp,Q8PageStorage.mm}`.
  - `unifdef` with `SPLASH_SEALED`, `SPLASH_KV_CHUNKED` and all 50+ `SEALED_TEST_*` names undefined: `Bootstrap.mm`, `FdTransport.cpp` and `ModelDescriptor.mm` become equal to upstream. The other 26 files keep unconditional changes (R4-U1).

## Findings

| ID | Severity | Area | Finding | Evidence | Recommended action |
|---|---|---|---|---|---|
| R4-H1 | INFO | HOME fix (R2-4-02, task item 2) | The HOME fix holds. No user path or absolute source path is in the build-ID constants, the stamp, the header or `child/splash`. There are also no load-command paths outside the system and no stabs. Two fresh builds, one with `HOME=/tmp/child-repro-home`, gave the pinned CD hash `<h23>`. The code of `<h23>` equals the P6 child `<h21>`. Only the build-ID string and `LC_UUID` differ. This settles the gap that `CLAIM-v2-2026-10-24.md:42` states ("No byte compare of `<h23>` against `<h21>` is stored"). Limit: both fresh builds ran on this Mac, as this user, with this Xcode. | Key measurements: constants, `strings`, `otool -l`, `nm -ap`; `build/evidence-<date>-<time>.txt:2`; `scripts/child-repro-check.sh:13-21`; byte compare with `scratch/ckv-pin-a/splash`. | Store the `<h21>` compare (this report can serve). A build by a second party on another Mac is still the test that would remove the "same Mac, same user" limit. |
| R4-H2 | LOW | SealedGuard drift (task item 2) | Today the copies are byte-identical, but nothing stops drift. (1) Two live copies are compiled into pinned binaries: `splash/runtime/sealed/guard/` (child) and `sealed-engine-v2/Sources/SealedSpawnC/` (engine). No script compares them. The closure states this as a limit. (2) The test launcher uses a third header copy, `build-glm/…/code-s5-canary/staged/include/sealed_guard.h`, through `-I $S/include`. It also links a spawn module (`$S/sealed_spawn.c`) that differs from the engine's module (one include line today). The launcher build reads a `~` path outside both repos. (3) `neg/build-all.sh --check` covers only the 75 Splash builds. It does not cover `launcher/sealed-launch`, `neg/R7/sealed-launch-dlv` or `neg/B/r2neg`. A drift would not weaken a pin, because each binary is pinned by its own hash. But the record "shared with the engine" (`Makefile:257`) would then be false, and the suite's launcher could test spawn code that differs from the engine's code. | `shasum` of all copies; `neg/build-all.sh:170-183`; `staged/sealed_spawn.c:11`, `:48`; `OPEN-ITEMS-CLOSURE-2026-10-24.md:104` ("no check yet refuses a build when they differ"); `grep` with 0 matches in the scripts. | Add a required accept row: `cmp` of the child guard `.c`/`.h` with the engine guard `.c`/`include/.h`. Build the test launcher from the engine's `SealedSpawnC` sources (or `cmp` the staged copy against them, ignoring line 48). Record the launcher and `r2neg` source hashes in the report. |
| R4-B1 | LOW | Build-ID coverage (follows R3-G1) | The build ID still does not hash the build rules. `Makefile`, `dev/native.mk` and `dev/tools/build_config.py` are not inputs (`build_identity.py:24-31`). The SealedGuard object's flags (`xcrun -sdk macosx clang -std=c17 -O2 -Wall -Wextra … -I$(SEALED_GUARD_DIR)`, `Makefile:264`) are hard-coded and are not a `--constant`. So a change to them passes both identity checks. The closure states the Makefile part (`:81` "It does not hash the Makefile"). The CD hash pin and `child-reproducible` still bind the bytes. | `splash/dev/tools/build_identity.py:24-31`; `splash/Makefile:203-208`, `:264`; `OPEN-ITEMS-CLOSURE-2026-10-24.md:81`. | Add `Makefile`, `dev/native.mk` and `dev/tools/build_config.py` to `production_input_paths`, or add `BUILD_RULES_DIGEST` as a constant. Put the guard compile flags in a variable and pass it as a constant. |
| R4-S1 | LOW | Source binding (task item 4) | The harness does not bind the child to a git commit. The engine has `source/engine-branch` and `source/engine-tree-clean` rows, but the child has no commit row and no clean-tree row. The accept run (`…031333Z`, <time> local) ran 50 minutes before commit `bd77b6c` (<time> local). The commit message names the pin after the fact. I settled the binding read-only: the id from `git archive bd77b6c` is `src-<h29>…`, the id of `child/splash`. Only `.gitignore` changed after the build. No stored record shows this. The commit has no parent (the 1.0.2 base is only stated) and no remote. | `sealed-accept/reports/…031333Z/facts.tsv` (no splash commit fact); `git log --format=%P` (empty); `git remote -v` (empty); recomputation in Key measurements; `OPEN-ITEMS-CLOSURE-2026-10-24.md:105`. | Add required rows `source/child-commit` (`git -C splash rev-parse HEAD`) and `source/child-tree-clean` (`git status --porcelain` empty except `build*`). Rebase the commit on upstream tag `1.0.2`, so that `git diff 1.0.2..sealed-v2` is the record of the change. Push it to the hub. |
| R4-U1 | LOW | Upstream diff record (task item 4) | Every change against 1.0.2 serves the sealed build and is described in a record (`CHUNKED-KV-2026-10-23.md` for the KV, kernel and Metal changes, `README.md` and `REVIEW-DEEPSEEK.md` for R2/R5/R6, `WeightStore`, `RuntimeResources` and `FdTransport`). I found no undescribed change to security code. But `CHUNKED-KV-2026-10-23.md:118` says "Not changed: the non-sealed build paths", and that is not exact. With all sealed and test macros undefined, 26 files still differ from upstream. Most of the extra code is dead in other builds (`releaseIdleKv`, `ensureRunway`, `addIndirectResource`, `kvBudgetMessage`). The flat kernel paths changed form, but the index arithmetic is the same (`splash_q8_*_index` is linear in `page`). Three changes run in every build: `Cache::releaseUnusedKvBacking` calls `pool_.adoptBackedExtents()` (`Cache.cpp:309`), the memory-plan JSON and summary add `kv_budget_bytes` and `KV budget: none` (`MemoryPlan.cpp:165`, `:203-204`), and each command encoder loops over `indirectResources` (`MetalBackend.mm`, empty outside the sealed build). The only stored diff, `review/splash-runtime.diff` (2026-10-12), is out of date. | `unifdef -f` output in `/tmp/r4c1-plain/`; `CHUNKED-KV-2026-10-23.md:51`, `:97-118`; `review/splash-runtime.diff` (mtime 2026-10-12). | Correct `CHUNKED-KV:118` to name the three changes that run in every build. Replace `splash-runtime.diff` with `git diff 1.0.2..bd77b6c` after the rebase in R4-S1. |
| R4-R1 | LOW | Records | The closure row for R3-G1/R3-P1 gives the wrong accept-run value: "Accept run: child build ID `src-<h70>…` verified". That is the id of the round-3 child `<h22>`. The round-4 accept run verified `src-<h29>…`. | `OPEN-ITEMS-CLOSURE-2026-10-24.md:92`; `…031333Z/results.tsv` row `source/child-is-current-production`. | Change the value to `src-<h29>…`. |
| R4-C1 | INFO | Identity gates (task item 3) | Both identity gates can fire, and they pass for the right reason. The production check passes for `child/splash` and `splash/build/splash`. It fails for wrong flags, for the staged test child and for an older child. `neg/build-all.sh --check` lists all 75 variants as current. `child/splash` is byte-equal to `splash/build/splash` except for the signature, and two fresh builds gave the pin. It holds no test strings, test symbols or `getenv`, and the scan itself finds test strings in three test builds. | Key measurements. | None. Store one failing control (see R3-G2). |

## Round-3 finding status

| Round-3 ID | Status on round 4 (`<h23>`, report `…031333Z`) |
|---|---|
| R3-G1 stale-build gate too narrow (MEDIUM) | **Fixed.** The mtime test is gone. `accept.sh:289-294` runs `neg/build-all.sh --check`, which recomputes the build ID of all 75 variants with their own defines (`build-all.sh:133-147`). It covers `.hpp`, `.metal`, SealedGuard (now under `runtime/`) and the defines. A failed variant build writes a new stamp and leaves the old binary, so `--check` shows it as `STALE`. Rest: the build rules are not hashed (R4-B1), and the launcher and `r2neg` are not covered (R4-H2). |
| R3-G2 no stored firing of the gate (LOW) | **Open.** No report, log or review file holds `STALE`, `test builds do not match` or `not a production build of the current source`. This report records the controls that I ran (R4-C1), but no harness run shows them. |
| R3-N1 test builds current (INFO) | **Still true** for round 4: 75 `current` in my run and in the report's `neg-build-check.txt`. |
| R3-P1 harness does not bind the child to production source (MEDIUM) | **Fixed for parts 1, 2 and 4.** Required row `source/child-is-current-production` (`accept.sh:243-247`, in `required.json`) recomputes the id with `-DSPLASH_SEALED`. A staged test build fails it (control in R4-C1). **Part 3 is open:** `CKV-production-hygiene` still scans `splash/build/splash` (`neg/run-all.sh:343`). The result still holds for the child by byte equality. |
| R3-P2 production child hygiene (INFO) | **Still true** for `<h23>` (R4-C1). The "fresh build" limit is now settled by `child-reproducible` with the pin. |
| R3-R1 records (LOW) | **Partly fixed.** `README.md:6` now names engine `<h19>…` and child `<h23>`. The suite header still has no pin: `neg-run-all.txt:1` is `# build: <date> <time> host=Mac17,7 27.2-beta`. |
| R3-C3 budget edges (LOW) | **Open on the child side.** `neg/run-all.sh` has not changed since <date> <time>. There is still no case for 1 TiB + 1, the exact boundaries or a short v2 frame. `CHUNKED-KV-2026-10-23.md:273` still says that the engine sends only version 1 and that the change "was not made". The engine-side v2 arms are now stored, according to the closure (`:32`), but that is the engine area. |
| R3-H1 four stale test folders (LOW) | **Open.** `build-noown`, `build-ownlog`, `build-nobin` and `build-nolibexec` (2026-10-20) are still in `splash/`. They are not in `VARIANTS`, so `--check` ignores them, and `.gitignore` hides them. |

Round-2 items carried in round 3:

| Round-2 ID | Status on round 4 |
|---|---|
| R2-C2 loose `frame-trailing` regex | **Open.** `neg/run-all.sh:60` still matches `${REFUSED}.*code=8`. |
| R2-S2 missing self-test arms | **Open.** `sealed_r5.mm` has not changed (<date> <time>). |
| R2-R4 no R4 negative | **Open.** `neg/run-all.sh` has 0 R4 cases. |
| R2-F R6 coverage, `open failed` ambiguity | **Open.** `sealed_r6.cpp` (<date> <time>) has not changed. `:554` still skips non-vnode descriptors. `R6-symlink` and `R6-missing` still both expect `open failed`. |
| R2-N2 `cache-symlink` label | **Open.** It is still refused by `TMPDIR must hold only metal-cache` (`run-all.sh:68`). |
| R2-N3 hygiene target, dead import | **Open** (see R3-P1 part 3). `sharedListener` and `notifyListener` are still in the binary once each (`MetalBackend.mm:514`, `:953`, `:982`). |
| R2-K2 freed KV, R2-H hooks compile out | **Still true.** No change. Hooks compile out (R4-C1). |

## Verdict for the child area

The round-4 child `<h23>` is a clean production build of commit `bd77b6c`. Its build ID equals a recomputation from a `git archive` of that commit. Its code equals `splash/build/splash`, and two fresh builds with different `HOME` values gave the pinned CD hash. It holds no test code. Its code also equals the P6 child `<h21>`, apart from the build-ID string and `LC_UUID`.

The HOME fix (R2-4-02) holds. No user path enters the build-ID constants, the stamp or the binary. The child and engine SealedGuard copies are byte-identical. No script still reads `~/projects/morpheus-pnode-sealed-v2`.

The round-3 MEDIUM findings R3-G1 and R3-P1 are fixed by the two build-ID gates, and both gates fail on wrong input. The remaining items are LOW. Nothing compares the SealedGuard copies, and the test launcher uses a third header copy and a staged spawn module (R4-H2). The build ID does not hash the build rules (R4-B1). The harness does not bind the child to a commit (R4-S1). One record says that the non-sealed paths did not change, which is not exact (R4-U1). One closure value is stale (R4-R1).

The committed tree holds every production build input, and `.gitignore` hides none. Every change against upstream 1.0.2 serves the sealed build and is described in a record. I found no CRITICAL, HIGH or MEDIUM issue in the child area.
