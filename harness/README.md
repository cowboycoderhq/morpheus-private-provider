# Sealed Splash on the M5

Host: M5, Mac17,7, macOS 27.2 beta (27.2-beta), 128 GiB.
Model: audreyt/Qwen3.8-27B-Splash-abliterated, served from `pkg/qwen38-27b/`
(hard links to the Hugging Face cache files; no symlinks).
Last update: 2026-10-25 (accepted build: child pin `8083a3388742668a68027de726b2a5eaef049ac6`, staged in `child/`; engine `<engine CD hash withheld>…`; 95-case suite; accept report `…20261025ThhmmssZ`; second-Mac build `review/SECOND-MAC-REBUILD-2026-10-25-r5.txt`).

## What runs

| Part | Path | Role |
|---|---|---|
| Sealed child | `child/splash` (pin in `child/pin.txt`, requirement `child/req-splash.bin`) | Splash 1.0.2 native engine built with `-DSPLASH_SEALED` from `splash/`. Signed ad-hoc, hardened runtime, identifier `sealed.splash`. |
| Engine stand-in | `launcher/sealed-launch` | A-13 canary (strict), sealed spawn (staged module), status words pinned, config frame, the "sandboxed" and "loaded" reports in order with a CD hash and status re-check at each, manifest-hash check, then a byte relay. |
| Manifest | `pkg/qwen38-27b/sealed-manifest.bin` | 75 entries, 17,355,949,400 bytes, hash `a1a25ecb519aa13cff2974a477ba918d0446820b0a7dd1b95077e2e9df290099` (kind 2). Made by `tools/make-manifest.py` from a record-mode load (`record/`). |
| Server | `run-sealed-server.sh` | Installed Splash 1.0.2 Python server on `127.0.0.1:8199` with `--binary launcher/sealed-launch`. |
| Regression check | `smoke.sh <tag>` | Start, one chat request, CD hash of the serving pid = pin, stop, nothing left. |
| Negative suite | `neg/build-all.sh`, then `neg/run-all.sh` | Builds the production child and its test builds (11 S3 builds added 2026-10-21, 11 mutation builds added 2026-10-22). After `./stage-child.sh`, it runs 95 cases. Each line is marked PASS or FAIL against its expected result in `neg/final-<date>.txt`. |
| Serving inspection | `tools/inspect-serving.sh` | One request, then the child's sandbox state, descriptors, file-backed regions, weight protections and `metal-cache`, stored in `logs/inspect/`. |

Child startup order (`splash/runtime/main.mm`), as the spec's R4 order:

1. R1 exception-port guard (`sealed_guard.c`, shared with the engine).
2. R2 self-check (`runtime/sealed/sealed_r2.cpp`): descriptors (the kernel's full list, `PROC_PIDLISTFDS`), exec-time environment, TMPDIR (owner, mode, only an empty `metal-cache`), working directory, signals, all six rlimits against compiled constants (the launcher sets them), argv form.
3. First byte `'S'`.
4. Config frame (`SLCF`): package root, target, draft, manifest. Roots must equal argv.
5. R6 init (`runtime/sealed/sealed_r6.cpp`): parse the manifest, open the roots by descriptor (`O_NOFOLLOW` per component, `F_GETPATH` must match), refuse two entries that differ only by case.
6. R5 sandbox (`runtime/sealed/sealed_r5.mm`), then its self-test (22 arms, `logs/selftest-arms-2026-10-20.txt`; 23 since 2026-10-23 with `iosurface-open`). A truncated profile text refuses.
7. R4 Metal guard: `MTL_SHADER_CACHE_SIZE=0`, shader and module cache path = `$TMPDIR/metal-cache` (the TMPDIR value that R2 checked).
8. `SLSB` ("sandboxed") to the engine. The child sends it only after steps 6 and 7 in that order. The engine re-checks the CD hash and status word through the audit token, then removes the self-test probe files.
9. Load. Every model file goes through the R6 funnel: one `openat` from the root descriptor with `O_NOFOLLOW_ANY | O_RESOLVE_BENEATH`, read into anonymous page-aligned memory, size and SHA-256 checked, then made read-only for life. The metallib is embedded in `__TEXT,__splash_metal`.
10. Open latch, then the address-space self-audit. The audit fails if the region walk errors or never sees the executable. It accepts only the executable and sealed-volume paths, and it refuses the firmlinked Data-volume folders.
11. `SLLD` + manifest hash to the engine. The engine re-checks the CD hash and status word, then compares the hash with its own. Then READY. A report out of order refuses.
12. Self-audit again each time input arrives.

## Results

All lines below come from stored logs. The final runs are of 2026-10-20 (production pin `<h13>`, M5, 27.2 beta 27.2-beta). The 2026-10-12 results stay in `neg/final-2026-10-12.txt` and `logs/inspect/inspect-2026-10-12.txt`.

| Check | Result | Evidence |
|---|---|---|
| Real request through the sealed child | `Paris`, smoke PASS (CD hash = pin, nothing left) | `logs/s7-final-2026-10-20.result.txt`, `logs/inspect/inspect-2026-10-20.txt` (raw JSON) |
| Report order and phase re-checks | `sandboxed` then `loaded`; status `0x22011311` and CD hash = pin at both | `logs/s7-final-2026-10-20.launch.log`, inspection file |
| Child is sandboxed while serving | `sandbox_check=1` | inspection file |
| Child's descriptors while serving | cwd, fd 0/1 socket, fd 2 `/dev/null`, fd 3/6 Splash's own wake pipe (`FdTransport.cpp:76`) | inspection file |
| Files mapped while serving | executable, system volume, and the logd residual (below) | inspection file |
| Weights read-only | 158 regions of 64 MiB or more are read-only (72.22 GiB virtual). 156 of them also have a read-only maximum. The other 2 (111.3 and 87.0 MiB, anonymous, copy-on-write) occur with the same sizes in an unrelated Python process, so they are system mappings. 6 regions are writable (1.44 GiB, Metal working memory). | inspection file, `tools/regions.c` |
| TMPDIR and `metal-cache` after a request | TMPDIR holds only `metal-cache`, and `metal-cache` is empty | inspection file |
| Manifest hash, child vs engine | equal, `a1a25ecb…0099` | launch log |
| Child resident memory while serving | 17.5 GB RSS | inspection file |
| No test switch in production | the only test-like string is the `r5-owndir-probe` name, which the production self-test reads | `strings splash/build/splash` |

Negative suite (`neg/final-2026-10-20.txt`, run <date> <time>): 53 of 53 PASS, with no process left after the run. Every child refusal happens before READY with exit 113 and a reason line.

- R2, 14 cases: extra descriptor (fd 7), high descriptor (fd 300), stdout not the socket, extra environment variable, HOME ≠ TMPDIR, TMPDIR mode, extra file in TMPDIR, working directory, blocked signal, ignored signal, RLIMIT_NOFILE changed, MAX_MEMORY not `auto`, non-canonical root, child started through a symlinked path.
- Config frame, 5 cases: truncated, bad magic, roots differ from argv, manifest does not parse, bytes after the manifest (N3).
- Cache directory, 2 cases: `metal-cache` mode, `metal-cache` as a symlink (S1c).
- R5 self-test, 2 cases: probe files absent (S7), own-folder probe absent (the sandbox gives `ENOENT` for a missing name, and the arm needs `EPERM`).
- R6, 8 cases: changed byte, symlinked file, truncated file, grown file, edited manifest hash, missing file, file not in the manifest, two entries that differ only by case (N6).
- R6 test builds: open after the latch, second read of a loaded path (S3).
- Self-audit test builds: mappings planted before the sandbox from `/private/etc/hosts`, `/System/Library/Caches`, `/usr/share/snmp` and `CoreTypes.bundle/Contents/Library` are refused (B1, S4).
- R5 profile mutants: allowing file writes, network, or any mach-lookup is caught by the self-test.
- R5 without the sandbox: the self-audit refuses, because Apple frameworks map `/private/var/db/analyticsd/events.allowlist`.
- N4: a profile text cut to 4096 bytes refuses.
- N7, 3 cases: a "sandboxed" report before the sandbox refuses in the child. A sandboxed child that skips the report sends "loaded" first. The launcher refuses that child and logs the `SLLD` bytes it got in place of `SLSB`.
- Launcher, 7 cases on the production child: the control serves. Wrong pin, wrong requirement with the canary off, tampered binary (good pin and own pin) and broken signature are refused by the spawn (codes 15, 16, 20). With the canary on, a requirement that admits the decoy fails the canary first.

## Review dispositions

Review: `review/REVIEW-DEEPSEEK.md` (DeepSeek; the Opus run stopped at a daily limit after its falsifiers, `review/REVIEW-OPUS.md`). Verdict FIX FIRST.

| Item | Disposition (2026-10-12 and 2026-10-20) |
|---|---|
| B1 audit fails open | Fixed. The walk refuses on errors and must see the executable. Planted mappings refused under the sandbox. |
| B2 descriptor scan bound | Fixed. The kernel's full descriptor list. fd 300 case refused. |
| S1 R2 items | Fixed. Four rlimits against constants, reason codes, `metal-cache` owner, mode and type. |
| S2 funnel memory writable | Fixed. Read-only with a read-only maximum (156 regions measured). |
| S3 audit items | Fixed 2026-10-21. A second read refuses. Share-mode, descriptor and open-log checks added and tested (see *S3 completion 2026-10-21*). |
| S4 audit allow-list | Fixed. Sealed-volume prefixes only, firmlinked folders refused. |
| S5 own-folder rule | Fixed. Literal rules from the record trace: the folder, the executable, and metadata for `Info.plist`, `en.lproj`, `Base.lproj`. A planted file gets `EPERM`. |
| S6 firmlinks in the profile | Fixed. `/usr/bin` and `/usr/libexec` removed (the child serves without them). The firmlink denies stay. |
| S7 self-test gaps | Fixed. Probe arms in TMPDIR and `metal-cache`. mach-lookup must return 1100. DNS uses the denied lookup and the denied socket. |
| N1 latch without the lock | Fixed. The latch takes the lock, and the read checks the latch again under the lock. |
| N2 size cap | Fixed. 0 < size ≤ 64 GiB before the page rounding. |
| N3 trailing frame bytes | Limit: bytes present when R2 checks the frame are refused; bytes that arrive later are not (one FAIL in `neg/final-2026-10-22-run1.txt`). |
| N4 profile truncation | Fixed and tested. |
| N5 absent `/usr/local` | Fixed. Absent arms are recorded before the sandbox and skipped. |
| N6 manifest tool and case fold | Fixed. `tools/make-manifest.py` refuses symlinks, the wrong charset, case collisions and empty files. It still makes the same manifest byte for byte. The child refuses case-fold duplicates. |
| N7 "sandboxed" report | Fixed and tested (above). |
| N8 TMPDIR from `environ` | Fixed. The R4 guard and the self-test use the checked `envp` value. |
| T1–T6 | Superseded 2026-10-24: see `review/OPEN-ITEMS-CLOSURE-2026-10-24.md`. T2 is closed in production (no `IOSurfaceRootUserClient` rule); T5 is superseded by the v2 engine; T6 and R7-T3 are closed. |

## S3 completion 2026-10-21

Production pin after this change: `<h7>`. Suite: `neg/final-2026-10-21.txt`, 66 of 66 PASS (the 53 earlier cases and 13 new ones), no process left. Smoke: `logs/s3-2026-10-21.result.txt`, `PASS smoke[s3-2026-10-21]: answer=Paris cdhash=pin left=0`. The launcher log shows the manifest hash `a1a25ecb…0099` and the pin at both phase checks.

### What each check enforces

All three run in `sealed_r6_self_audit` after the latch: before "loaded", and again each time input arrives. The share-mode check also runs once per file in the funnel, before the hash.

1. **Share mode** (`sealed_r6.cpp`, `audit_share` and the check in `sealed_r6_read`).
   - The funnel allocates each file with its own VM tag. It makes the memory read-only with a read-only maximum and sets inheritance to `VM_INHERIT_NONE`. These steps now occur **before** the hash.
   - Before the hash, each map entry of the region must be `SM_PRIVATE`, have ref count 1, no shadow, no submap, the funnel tag, and protection and maximum `r/r`. The child records the start, size and VM object id of each entry.
   - After the latch, each entry must have the same start, size, object id and tag. The share mode must be `SM_TRUESHARED` with ref count 1 + *w*. The value *w* is the number of Metal no-copy wraps of that region. `WeightStore` reports each wrap through `sealed_r6_note_gpu_wrap`. A file without a wrap (JSON) must stay `SM_PRIVATE` with ref count 1.
2. **Descriptors** (`audit_fds`). The check walks the kernel's full list (`PROC_PIDLISTFDS`). It reads each vnode descriptor with `F_GETPATH` and `fstat`. It refuses:
   - a descriptor with the device and inode of a funnel-opened file, so a hard link at another path is caught,
   - a model root (by device and inode),
   - a path below a model root,
   - a file outside the sealed-volume prefixes (the S4 list).

   Only `/dev/null` is accepted outside that list. Any failure to read a descriptor refuses. The walk must see fd 0, 1 and 2.
3. **Open log** (`audit_open_log`). For each manifest entry, the funnel records the `F_GETPATH` name of the opened file and its device and inode. The audit requires exactly one open per entry and a total equal to the manifest count. The kernel's name must equal the manifest path byte for byte.

### What share mode proves and what it does not prove

Measured on this M5 (27.2 beta) with standalone probes (`/tmp/s3probe`, not kept) and in the child:

- `share_mode` and `ref_count` are properties of the VM object behind a map entry. They count references, not processes. `SM_PRIVATE` with ref count 1 means that no other mapping, memory-entry port or task shares the object at that moment. `SM_TRUESHARED` / `SM_SHARED` means that something else holds a reference, but the kernel does not say what. It can be Metal, a memory entry, a remap alias, or a fork with `VM_INHERIT_SHARE`. All of them gave the same `sm=5`.
- Metal's `newBufferWithBytesNoCopy` turns the region into `SM_TRUESHARED` with ref count 2. That reference comes from the GPU driver in the child's own address space. So "weights must read private" from the spec cannot hold for wrapped weights. The child instead requires the exact count (1 + wraps). One extra reference of any kind refuses (case `S3-share-entry`).
- After `mach_vm_protect(..., set_maximum=TRUE, VM_PROT_READ)`, a new writable memory entry or a writable remap of the region fails (`KERN_PROTECTION_FAILURE`). A writable memory entry made **before** the protect keeps write access, and a write through it shows in the read-only view (case `S3-share-rw-alias`). For that reason, the child checks share mode and ref count after the protect and before the hash.
- The checks see only the child's side. They cannot show which task holds a reference. They cannot see a GPU write. A GPU blit fill into a no-copy buffer on read-only memory failed with status 4 (error) in a probe. That result is one probe, not a proof. They cannot see a write by a task that holds the child's task port or by root (for example `mach_vm_write` through `task_for_pid`, which the hardened runtime and the sealed spawn are meant to stop). A reference that someone takes and drops between two audits is also not seen.
- The ref count equals 1 + wraps only while the backend wraps each funnel buffer once and does not create memory entries itself. A Splash or Metal change that does so makes the child refuse. That is a fail-closed result, but it is also a maintenance cost.

### What the descriptor check and the open log prove and do not prove

- Under the R5 sandbox, `PROC_PIDFDVNODEPATHINFO` on self returns `EPERM` for any path the profile does not allow (measured). `fstat` is denied on the write-only `/dev/null` (fd 2). `F_GETPATH` works on every descriptor. The check therefore uses `F_GETPATH` + `fstat`, and it accepts an unreadable descriptor only if the kernel names it `/dev/null`.
- `F_GETPATH` on a hard-linked file gives the last name through which the file was opened (measured). The descriptor check therefore matches by device and inode, and the path in the reason line can differ from the opened path (case `S3-fd-hardlink`).
- The open log records only opens that go through the funnel. An open that bypasses the funnel and is still open at audit time is caught by the descriptor check (case `S3-bypass-open`). A bypass open that is **closed** before the audit is not caught by any check in the child (control `S3-bypass-open-closed` loads). That gap stays with R6-T7, which needs an independent trace (`fs_usage` / `eslogger`). `DYLD_INTERPOSE` in the child did not catch opens from Apple frameworks (measured), so an in-process open hook is not a full recorder.
- The open-log comparison catches a funnel open whose on-disk name differs from the manifest path. APFS folds case, and the sandbox literal admits the case variant (measured), so a case-variant name passed the hash and the earlier checks (case `S3-openlog-case`). It cannot catch an open made by another process.

### Per-case table (expected and actual reasons)

Each refused case has two proofs. The first is the test hook's own line: the hazard was planted, and in `S3-share-rw-alias`, the write changed the read-only view. The second is the bytes `<h14>` ("sandboxed") before the refusal, so R2, the frame and R5 passed. Each match is anchored on the hook line and on the reason. No mutation run (a check disabled on purpose) was done for the S3 checks.

| Case | Build | Planted | Expected | Actual |
|---|---|---|---|---|
| S3-share-rw-alias | `build-s3-rwalias` | Writable memory entry on `head.bin` before the protect, mapped and written after it (view changed, then restored) | `weights region not private before the hash: …/target/head.bin sm=5 ref=3 prot=1/1 inh=2 shadow=0` | same, PASS |
| S3-share-rw-alias-dropped (control) | `build-s3-rwalias-drop` | Same entry, released before the protect | loads | `SANDBOXED then LOADED`, PASS |
| S3-share-entry | `build-s3-share` | Read-only memory entry on `head.bin` after the load (`sm 5->5 ref 2->3`) | `self-audit failed: weights region shared: …/target/head.bin sm=5 ref=3 …, want sm=5 ref=2` | same, PASS |
| S3-share-entry-ctl (control) | `build-s3-share-ctl` | Same entry on ordinary anonymous memory (`sm 2->5 ref 1->2`) | loads | loads, PASS |
| S3-fd-hardlink | `build-s3-fd-blob` | fd kept on the Hugging Face blob that is a hard link of `head.bin` | `descriptor refers to a funnel-opened file: fd 4 … (manifest …/target/head.bin)` | same, PASS |
| S3-fd-root | `build-s3-fd-root` | fd kept on `pkg/qwen38-27b/target` | `descriptor refers to a model root: fd 4 …/target` | same, PASS |
| S3-fd-under-root | `build-s3-fd-under` | fd kept on `tokenizer/vocab.json` (not in the manifest) | `descriptor refers to a path under a model root: fd 4 …/tokenizer/vocab.json` | same, PASS |
| S3-fd-outside | `build-s3-fd-hosts` | fd kept on `/private/etc/hosts` | `descriptor refers to a file outside the sealed volume: fd 4 /private/etc/hosts` | same, PASS |
| S3-fd-system-ctl (control) | `build-s3-fd-sys` | fd kept on `/System/Library/CoreServices/SystemVersion.plist` | loads | loads, PASS |
| S3-bypass-open | `build-s3-bypass` | `open()` of `target/embedding.bin` past the funnel, after the load, under the sandbox (fd 9) | `descriptor refers to a funnel-opened file: fd 9 …/target/embedding.bin (manifest …)` | same, PASS |
| S3-bypass-open-closed (control) | `build-s3-bypass-close` | Same open, closed before the latch | loads (the known gap above) | loads, PASS |
| S3-openlog-case | reason build | `target/head.bin` renamed `Head.bin` on disk (same bytes) | `open log names a path not in the manifest: …/target/Head.bin (opened as …/target/head.bin)` | same, PASS |
| S3-openlog-case-ctl (control) | reason build | Same package, name restored | loads | loads, PASS |

The 53 earlier cases give the same verdicts as on 2026-10-20 (`neg/final-2026-10-21.txt`). The production binary has no test strings (`strings child/splash`: 0 hits for the reason path and hook markers).

### Files changed

- `splash/runtime/sealed/sealed_r6.{h,cpp}`: the three checks, the funnel VM tag, protect and `VM_INHERIT_NONE` before the hash, `sealed_r6_note_gpu_wrap`, and test hooks (`SEALED_TEST_RW_ALIAS`, `_RW_ALIAS_DROP`, `_SHARE_ENTRY`, `_SHARE_ENTRY_CTL`, `_KEEP_FD_PATH`).
- `splash/runtime/sealed/sealed_r2.{h,cpp}`: `sealed_reason_fd()`, so that R6 skips the test reason descriptor.
- `splash/runtime/model/WeightStore.cpp`: reports each no-copy wrap to R6.
- `splash/runtime/engine/Bootstrap.mm`: test hook `SEALED_TEST_BYPASS_OPEN` (`_BYPASS_CLOSE`).
- `neg/build-all.sh` (11 builds), `neg/run-all.sh` (section 4b; the reason filter now keeps 400 characters and strips every `$PWD/`).

## S3 mutation runs 2026-10-22

Rule: a refusal PASS counts only if a child with that check removed loads with the same planted hazard. Suite: `neg/final-2026-10-22.txt`, 77 of 77 PASS (the 66 earlier cases and 11 mutation cases), no process left. An earlier full run the same night is kept as `neg/final-2026-10-22-run1.txt`: 76 of 77, with one FAIL in `frame-trailing` (see *Finding: N3 race* below).

### Switches

Three test-only defines in `splash/runtime/sealed/sealed_r6.cpp`. Each one removes one S3 check from the build:

| Define | Removes |
|---|---|
| `SEALED_TEST_NO_SHAREMODE` | The share-mode check before the hash in `sealed_r6_read`, and `audit_share` in the self-audit |
| `SEALED_TEST_NO_FDCHECK` | `audit_fds` in the self-audit |
| `SEALED_TEST_NO_OPENLOG` | `audit_open_log` in the self-audit |

The funnel still records the open log, the VM entries and the descriptor identities, so the other checks keep their inputs. A mutant writes `test: mutant <define>` to the reason file at the start of R6 init, so each record line names the check that the child lacks.

The production source path keeps the original single `||` line. The production build was compared with the build before the change (snapshot in `scratch/prod-<h7>/`): 46 of 47 objects are byte-identical, including `sealed_r6.o` and `sealed_r2.o`. `main.o` differs only in the build ID string (`src-6e92…ce2f` before, `src-c56f…ad33` after), because the build ID hashes every runtime source file. Text disassembly of `main.o` and of the linked `splash` is identical except for that literal. `strings -a` on `splash/build/splash` and on `child/splash` gives 0 hits for each of `SEALED_TEST_NO_SHAREMODE`, `SEALED_TEST_NO_FDCHECK`, `SEALED_TEST_NO_OPENLOG`, `test: mutant`, `test: ` and `sealed-reason`.

`child/` was not staged again. It still holds pin `<h7>`, which the running SealedEngineV2 has compiled in (`morpheus-pnode/sealed-engine-v2/Sources/SealedEngineV2/ChildPin.swift`). The new production build has the same code and a different CD hash (`splash/build/splash`, linker signature `<h15>`, before the re-sign), only because the build ID changed. Use of the new build needs a re-pin in morpheus-pnode. That is outside this change.

### Builds (`neg/build-all.sh`, 11 added)

- Plain mutants (no hazard): `build-noshar`, `build-nofd`, `build-noopen`.
- Hazard mutants (the hook of one S3 case plus its check removed): `build-noshar-rwalias`, `build-noshar-share`, `build-nofd-blob`, `build-nofd-root`, `build-nofd-under`, `build-nofd-hosts`, `build-nofd-bypass`. `S3-openlog-case` needs no hook. It uses `build-noopen` with the case package.

### Mutation cases (`neg/run-all.sh` section 4c)

A mutation case is PASS only if all three hold: the mutant line names the removed check, the hook line shows the hazard arrived (the same proof pattern as section 4b), and the child sends `SLSB`, then `SLLD`, and loads (`exit=-9 SANDBOXED then LOADED`). A refusal on the mutant would mean that another check also catches the hazard.

| Normal-build case (refuses) | Mutant case | Mutant build | Hazard shown on the mutant | Result |
|---|---|---|---|---|
| S3-share-rw-alias | M-S3-share-rw-alias | `build-noshar-rwalias` | Writable alias kept, write after the protect changed the read-only view (`changed=1 restored=1`) | loads, PASS |
| S3-share-entry | M-S3-share-entry | `build-noshar-share` | Extra memory entry on `head.bin` (`sm 5->5 ref 2->3`) | loads, PASS |
| S3-fd-hardlink | M-S3-fd-hardlink | `build-nofd-blob` | fd 4 on the hard-linked blob of `head.bin` | loads, PASS |
| S3-fd-root | M-S3-fd-root | `build-nofd-root` | fd 4 on `pkg/qwen38-27b/target` | loads, PASS |
| S3-fd-under-root | M-S3-fd-under-root | `build-nofd-under` | fd 4 on `tokenizer/vocab.json` | loads, PASS |
| S3-fd-outside | M-S3-fd-outside | `build-nofd-hosts` | fd 4 on `/private/etc/hosts` | loads, PASS |
| S3-bypass-open | M-S3-bypass-open | `build-nofd-bypass` | fd 9 on `target/embedding.bin`, opened past the funnel | loads, PASS |
| S3-openlog-case | M-S3-openlog-case | `build-noopen` | The only `head.bin` on disk is `Head.bin` (listing in the line), so the weights loaded through a name not in the manifest | loads, PASS |
| (none) | M-plain-noshar, M-plain-nofd, M-plain-noopen | plain mutants | none. The unchanged package loads, so a mutation does not stop the child by itself | loads, PASS ×3 |

Each of the 8 refused S3 cases therefore depends on exactly its own check. No other check in the child catches these hazards. The five S3 controls (`-dropped`, `-ctl`, `-system-ctl`, `-open-closed`, `openlog-case-ctl`) load with the checks in place, so a mutation run cannot add evidence for them, and none was made.

What the mutation runs do not show: they show that each check is necessary for its case. They do not show that the hooks cover every form of the hazard. The limits in *What share mode proves* and *What the descriptor check and the open log prove* stay. The closed bypass open still loads with every check in place.

### Finding: N3 race (`frame-trailing`)

In run 1, `frame-trailing` loaded (`exit=-9 SANDBOXED then LOADED`) and did not refuse. Eight separate runs of that case after the suite all refused with `refused code=8: bytes after the manifest in the config frame`, and the second full run passed. `sealed_r2.o` is byte-identical to the production build before the change, so this is not caused by the mutation switches. Cause (from the code, not measured with a trace): `neg/B/r2neg.c:128-129` sends the frame and `EXTRA` in two `write` calls, and `sealed_r2.cpp:306` checks `FIONREAD` once, right after the frame read. If `EXTRA` arrives after that check, R2 sees no trailing bytes. So the N3 check catches only trailing bytes that are already in the socket buffer, and the case is timing-dependent. Open: decide whether R2 must refuse late bytes (for example, with an exact frame length and a bounded wait), or whether the N3 claim must say "bytes present at the check".

## Dense KV in production 2026-10-23

Record: `review/DENSE-KV-2026-10-23.md`. The sealed build (`-DSPLASH_SEALED`) has no placement-sparse KV, no MTL4 command queue and no `MTLSharedEvent`. Compute uses the legacy `MTLCommandQueue`. The R5 profile has no `IOSurfaceRootUserClient` rule, so `(deny default)` refuses the class. The self-test arm `iosurface-open` requires `kIOReturnNotPermitted` (`0xe00002e2`) for a probe open.

Runtime memory notes (measured on the M5, Qwen3.8-27B package):

| Item | Value |
|---|---|
| Dense KV pool | 65,536 tokens, 64 private Metal buffers (4 per attention layer), 2,181,038,080 bytes (2.03 GiB), 33,280 bytes per token |
| Allocation | All at start, all counted resident, never released until the process ends. The pool is part of the fixed footprint. |
| Largest context | 65,529 tokens (pool minus 7 speculative scratch tokens). `MAX_CONTEXT` 65530 refuses at bootstrap: `logical max_context exceeds the model or physical single-request Q8 KV capacity`. |
| Production `MAX_CONTEXT` | 32,768 (the engine and `run-sealed-server.sh`). The rest of the pool holds the prefix cache. |
| Child physical footprint | 19.49 GiB idle after load. 20.18 GiB peak sampled with a 31,940-token prompt, 19.81 GiB with a 63,935-token prompt. 20.61 GiB lifetime maximum, reached before the first request (load and warmup). |

The pool size is a compile-time constant (`kSealedDenseKvTokens`, `splash/runtime/engine/MemoryPlan.cpp`). A change to it changes the child CD hash.

> Superseded 2026-10-23 by *Chunked KV in production 2026-10-23* below: the fixed dense pool is gone. The IOSurfaceRootUserClient deny, the legacy queue and the `iosurface-open` arm stay.

## Chunked KV in production 2026-10-23

Record: `review/CHUNKED-KV-2026-10-23.md`. The sealed build allocates the KV cache as private `MTLBuffer` chunks of 512 tokens (16 Page32 pages, 17,039,360 bytes) on demand and releases them when they are empty. The kernels read one GPU address per (layer, tensor, chunk) from a shared table (`-DSPLASH_KV_CHUNKED` in the sealed metallib). No MTL4 queue, no `MTLSharedEvent`, no `updateBufferMappings`, no IOSurface import.

| Item | Value |
|---|---|
| KV budget | All live sessions and the prefix cache. Default 16 GiB (1,008 chunks, 516,096 tokens). `SEALED_KV_BUDGET_BYTES` on the launcher sends it in config frame version 2; the child accepts 256 MiB to 1 TiB. The engine sends version 1, so it gets the default. |
| Per-request limit | `min(MAX_CONTEXT, model 262,144, budget tokens - 7)`. A longer prompt gets HTTP 503 `capacity_exhausted` with the budget in the message. |
| Release | At every command-free control pass (500 ms): idle cache tails are evicted, empty chunks are freed, one empty chunk stays as the runway. |
| Prefix cache | Keyed by the chained hash of 32-token blocks (`KvCache`). It keeps the KV and composite states of the first 8,192 prompt tokens. Idle KV plus states are bounded to 1/16 of the budget (LRU). |

## Measured changes to the design inputs

- **R5 profile needs `IOSurfaceRootUserClient`.** Splash's MTL4 command queue and `MTLSharedEvent` return nil without it (`r5-extra/probe.mm`). The r5-profile test child never used them. *Superseded 2026-10-23:* the sealed child now uses dense KV on the legacy queue, and the profile has no rule for the class (see *Dense KV in production 2026-10-23*).
- **R6 opens must be one `openat` from the root.** Under the literal-only profile, opening an intermediate directory is denied; a single `openat(root, "a/b", O_NOFOLLOW_ANY | O_RESOLVE_BENEATH)` is allowed and refuses any symlink or `..`.
- **Exec-time environment.** CoreFoundation adds `__CF_USER_TEXT_ENCODING` to `environ` before `main`; the self-check reads `main`'s `envp`.
- **Residual mapping.** `MTLCreateSystemDefaultDevice` maps `/private/var/db/diagnostics/logd/.plist-cache.*` read-only, also inside the sandbox. Root can write that file. The self-audit accepts it only when protection and maximum protection are read-only.

- **The child's own path must be canonical.** The own-folder rules name the resolved path. A child started through a symlinked path (for example `/tmp`, which is `/private/tmp`) is denied its folder by CF and Metal and stopped with no reason line, right after `SLSB`. R2 now refuses such a path before the first byte, with a reason (measured 2026-10-20).

## Residuals (outside the seal)

- Tokenizer, chat template, HTTP server and the prompt text are in the Python server (operator decision 2026-10-12). The engine is a stand-in.
- The logd preference-cache mapping above.
- Status words and the requirement are pinned for this pair only.
- `MAX_MEMORY` is accepted only as `auto`; `MAX_CONTEXT` bounds are 1,024–262,144.
- The R5 profile allows the child's own folder by literal names only. The folder is still owned by the operator, so the operator can replace `Info.plist` metadata. A bundle layout with a root-owned folder would remove this.
- The release folder must hold `r5-owndir-probe` (written by `stage-child.sh`). Without it, the child refuses to start.
- Test-only switches (`SEALED_TEST_*`) are compile-time; the production build (`splash/build/`) has none of them.

## Build

```
cd splash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make -j6 SEALED_DEFS=-DSPLASH_SEALED
cd .. && ./stage-child.sh && ./smoke.sh <tag>
# full negative suite and inspection:
neg/build-all.sh && ./stage-child.sh && neg/run-all.sh && tools/inspect-serving.sh
```
