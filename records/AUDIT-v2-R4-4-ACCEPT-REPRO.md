# AUDIT v2 round 4 / 4: acceptance harness, matrix, reproducibility (2026-10-24)

Auditor 4 of 5, round 4. Read-only. I changed no source, script, report, pin, `matrix.json`, `required.json` or approval file. All attacks ran on copies in `/tmp/r4-4/`:
- `sa/`: copies of `matrix.py` (sha256 `13243421…`, equal to the live file), `required.json` (`<h29>…`), `approved-harness.txt`, `approved-required.txt`, the accepted report and its folder. `sa/matrix.json` is a scratch registry.
- `attack.py`, `attack30b.py`: 35 cases. Results in `attack-out.tsv`. Each case is `sa/reports/cNN.json` with folder `sa/reports/cNN/`.
- `procs.awk` (byte-equal to the `accept.sh` heredoc), `synth.txt`, `procs-probe.awk`, `sampler.sh`, `seen.txt`: isolation tests.
- `splash-git/`: `git archive bd77b6c` of the child source.

After the attacks, the live files still hash to `accept.sh <h30>…`, `matrix.py 13243421…`, `required.json <h29>…`, report `<h94>…`.

Short path names:
- `M` = `~/projects/sealed-backends-spike/sealed-m5`
- `E` = `~/projects/morpheus-pnode/sealed-engine-v2`
- `R4` = `M/sealed-accept/reports/Mac17,7-27.2-beta-20261025ThhmmssZ` (the accepted report, `R4.json` sha256 `<h94>…`)

## Pre-registered falsifiers

1. A changed copy of `R4.json` gets ACCEPTED by the current `matrix.py` with one of these changes: a forged EXEMPT line, a missing required check, a revoked engine, an unapproved harness, a harness copy with a different hash, or a missing evidence folder.
2. The closure file calls a round-3 finding fixed, but the code does not hold the fix.
3. A foreign process that lives for less than 3 seconds runs during a step, and the step still gets `run/<step>-isolated` PASS.
4. `child-repro-check.sh` gives SAME, but it does not change the user name, the build folder or the time.
5. A second user or a second Mac cannot get the source, the toolchain or the files for child `<h24>` and engine `<h20>`.

Results:
- Falsifier 1 fired for a forged evidence file (case 03), a PASS row that the file contradicts (04), a sibling-folder citation (05), a folder with only `harness/` and `root-pass.txt` (07), a revoked child (18), an edited `matrix.py` copy (23), a self-approved harness (24), and an A-2 line longer than 400 characters (30b).
- Falsifier 1 did not fire for these cases: a forged line in the JSON only, an appended cause, a missing or dropped required check, a cut `required.json`, a revoked engine, an unapproved or missing `tool_sha256`, an edited `accept.sh` copy, and no evidence folder.
- Falsifiers 3, 4 and 5 fired. Falsifier 2 fired only for record text (R4-4-13).

## Round-3 findings: status

| Round-3 id | Status | Evidence now |
|---|---|---|
| R3-4-01 (no second assembly of current pins) | OPEN | `grep -rl '<h24>\|<h20>' E/evidence`: no output. Newest file in `E/evidence/` is 2026-10-22. `OPEN-ITEMS-CLOSURE-2026-10-24.md:103` and `CLAIM-v2-2026-10-24.md:57` state this limit correctly. See R4-4-01. |
| R3-4-02 (`$HOME` in child build ID) | FIXED (build-ID level) | `M/splash/Makefile:50`: `-Iruntime -Iruntime/sealed/guard`, no `$(HOME)`. The guard files are in `runtime/sealed/guard/`, so `build_identity.py:24-31` hashes them. I ran `make -s check-build-identity SEALED_DEFS=-DSPLASH_SEALED BINARY=M/child/splash` in `/tmp/r4-4/splash-git` (`git archive bd77b6c`) four times: `HOME` set to `~` and `<other-home>`, and `USER`/`LOGNAME` set to `<developer>` and `outsider`. Each run gave `{"build_id": "src-<h31>…", "verified": true}`. That equals the ID in `R4.json`. Bytes were not rebuilt by me. |
| R3-4-03 (source not on the hub) | OPEN | `git ls-remote origin refs/heads/feat/sealed-v2-splash-engine`: `<h16>…`. `git branch -r --contains <h83>`: no output. The local branch is 13 commits ahead. `M/splash` is now a git repo, but `git remote -v` gives nothing, and `bd77b6c` has no parent (`rev-list --count` = 1). |
| R3-4-04 (`EXEMPT_CAUSE` not anchored, file not opened) | FIXED, with gaps | `matrix.py:149-166` opens the cited file and requires the exact line. `:240` uses `re.fullmatch`. Cases 01, 02, 06, 09 and 10 are REFUSED. Gaps: the cited file can be in another report's folder (case 05). The evidence files are not hashed (case 03). See R4-4-02. |
| R3-4-05 (A-2 pattern) | FIXED, LOW gap | Kit `tee-rootpass.sh:181` gives FAIL first when `r_child > 0`. Pattern `matrix.py:56-58` requires `child=0;` and "does not match any probes". Case 31 (`child=7`) is REFUSED. Gap: the trailing `.*` and the 400-character cite (case 30b, R4-4-08). |
| R3-4-06 (`required.json`) | FIXED, LOW gap | `required_sha256` is in the report. The value must be in `approved-required.txt` (`matrix.py:182-183`). The harness copy must hash to it (`:185-193`). `full_required` reads the copy (`:66-74`). `accept.sh:654-660` reads the file and adds SKIP rows for missing names. Cases 11-14 are REFUSED. The comment in the file is now correct. Gap: the approval file is in the same folder, which is not in git. Mode 0444 does not stop the owner (case 24, R4-4-06). |
| R3-4-07 (harness version and hash) | FIXED, LOW gap | `matrix.py:175-193`. Cases 20, 21 and 22 are REFUSED. Gaps: the `harness/matrix.py` copy is not checked (case 23). The approval list can be edited (case 24). |
| R3-4-08 (artifacts, revocation) | FIXED for the engine, LOW gap | `REVOKED_ARTIFACTS` and a 64-hex check (`matrix.py:124-137`, `:194-201`). Cases 16 and 17 are REFUSED. `child_cdhash == child_pin` is required. Gap: there is no child revocation list (case 18), and `kit_engine_cdhash` is not checked (case 19). See R4-4-07. |
| R3-4-09 (stored-row swap) | FIXED | `matrix.py:300-303`. End to end, I added `c05.json`, then changed the file: "REVOKED by the current gates: the report file changed after it was added" (rc 1). |
| R3-4-10 (row content) | OPEN | Cases 25 (PASS with control FAIL), 26 (PASS with empty evidence), 27 (junk names), 28 (`suites`/`totals`/`legal_boot.sip` contradict the rows) and 29 (`evidence_dir` names another folder) are all ACCEPTED. |
| R3-4-11 (SKIP to EXEMPT) | FIXED. New LOW in R4-4-10 | `accept.sh:644-648` converts only INCONCLUSIVE. |
| R3-4-12 (devicecheck retry) | OPEN | `accept.sh:327` still triggers on any "devicecheck" text. `:331` overwrites `engine-evidence.txt`. `engine_retries` goes only to `facts.tsv` (`:334`), not to the JSON (`:682-724`). The retry did not fire in `R4`. |
| R3-4-13 (stale-build gate) | FIXED | `accept.sh:289-294` runs `neg/build-all.sh --check`. It recomputes the build ID of each variant from the current source and its own flags (`neg/build-all.sh:136-147`), and it gives STALE when a build is missing. `R4/neg-build-check.txt` lists 75 builds as current. |
| R3-4-14 (records) | OPEN | `E/README.md:76` names commit `<h26>` for the current build. The accepted commit is `<h83>`. No current-pin evidence is under `E/evidence/`. See R4-4-13. |
| R3-4-15 (toolchain not recorded) | OPEN | `R4/engine-evidence.txt:1` holds "xcode-select: error: tool 'xcodebuild' requires Xcode…". `E/scripts/evidence.sh:26` calls `xcodebuild` before it sets `DEVELOPER_DIR`, and `xcode-select -p` is `/Library/Developer/CommandLineTools`. |
| R3-4-16 (round-1 LOW items) | PARTLY FIXED | `accept.sh:215` still has `--untracked-files=no`. `:568` still has `"RESULT: PASS" in text`. The tree build ID is now compared (`:243-247`, `source/child-is-current-production`). |

## Gate attacks (copies of `R4.json`, live `matrix.check_report` code)

"ACCEPTED" means that `check_report(report, path)` raised nothing and both levels are ACCEPTED. In most cases the citations point to the case's own folder (`cite_own`).

| Case | Change | Result |
|---|---|---|
| 00 | full folder copy, citations point to its own folder | ACCEPTED (control) |
| 01 | A-4 `arm_evidence` = a FAIL text cited at line 48, file not changed | REFUSED: line does not equal the file |
| 02 | the cause line with a FAIL text appended, in both the file and the JSON | REFUSED: no full-line cause match |
| 03 | evidence file and row hold the exact cause text, but the original line was a FAIL. No hash binds the file to the report | **ACCEPTED** |
| 04 | `root-pass.txt` copy: the P10-lo0 line changed to FAIL, the JSON row stays PASS | **ACCEPTED** |
| 05 | new report, folder holds `harness/` only, EXEMPT rows cite the original report's folder | **ACCEPTED** (also end to end: `add`, then `accepted` "yes … 142/142", rc 0) |
| 06 | folder holds `harness/` only, citations point to its own missing `root-pass.txt` | REFUSED |
| 07 | folder holds `harness/` and `root-pass.txt` only (no neg, engine, chat, facts or steps files) | **ACCEPTED** |
| 08 | no evidence folder | REFUSED: harness copy missing |
| 09 | A-4 cites `../../../../etc/hosts` | REFUSED: outside the report folder |
| 10 | `root-pass.txt` is a symlink to a file outside `reports/` | REFUSED (resolved path is outside) |
| 11 | row `root/P10-lo0-ciphertext-only` removed | REFUSED |
| 12 | that check removed from the rows and the required lists | REFUSED: required list omits 1 |
| 13 | cut `harness/required.json` with a matching `required_sha256` | REFUSED: not approved |
| 14 | cut `harness/required.json`, hash in the report not changed | REFUSED: copy hash differs |
| 15 | `engine/verified-chat` SKIP, verdict recomputed | INCOMPLETE |
| 16 | `engine_cdhash` = revoked `<h21>…` | REFUSED: revoked |
| 17 | revoked `<h27>…` in upper case | REFUSED: not 64 lower-case hex |
| 18 | `child_cdhash` = `child_pin` = `<h23>…` (the child of revoked engine `<h21>`) with engine `<h20>` | **ACCEPTED** |
| 19 | `kit_engine_cdhash` = revoked `<h21>` | **ACCEPTED** |
| 20, 21 | `tool_sha256` = 64 zeros, or removed | REFUSED |
| 22 | `harness/accept.sh` copy edited | REFUSED: copy hash differs |
| 23 | `harness/matrix.py` copy edited | **ACCEPTED** (not checked) |
| 24 | `accept.sh` copy edited, its hash in `tool_sha256`, and the hash appended to the scratch `approved-harness.txt` after `chmod` | **ACCEPTED** |
| 25-29 | PASS with control FAIL, PASS with empty evidence, 3 junk required PASS rows, contradictory `suites`/`totals`/`sip`, wrong `evidence_dir` | **ACCEPTED** |
| 30 | A-2 line with text appended, cite not cut | REFUSED (cite ≠ first 400 characters) |
| 30b | A-2 line of 539 characters with "FAIL [A-2-dtrace-read] child: 3 buffers copied" after character 400. The cite is cut at 400 characters, as `accept.sh` `cite()` does | **ACCEPTED** |
| 31 | A-2 line with `child=7` | REFUSED |
| 32 | `root/A-1-task-ports` marked EXEMPT | REFUSED: not on the list |
| 33 | `dry_run` true | REFUSED |

Summary: the new gates hold against edits to the JSON alone. The gates do not hold against edits to the JSON and the evidence files together. This is because `matrix.py` compares only the 4 EXEMPT lines with files, and no hash of the evidence files is recorded anywhere.

## Isolation detection (question 3)

How it works: `procs.awk` (`accept.sh:115-128`) lists a process as foreign only when all of these are true:
- its command contains `sealed-m5/`, `serve-native`, `tee-rootkit` or `SEALED_DEFS`;
- its command does not contain `sealed-accept/`, `SealedEngine` or `tee-rootkit/fake/`;
- its parent is not a `SealedEngine` process;
- it is not a descendant of the step pid.

`watch_start` (`:134-136`) samples `ps` every 3 seconds.

1. **Sampling, measured.** `sampler.sh` runs the same loop with the pattern changed to `r44probe`, against a dummy step. It ran 8 probe processes of each lifetime, one after another:

   | lifetime | seen |
   |---|---|
   | 0.3 s | 1 of 8 |
   | 1 s | 1 of 8 |
   | 2 s | 7 of 8 |
   | 2.9 s | 8 of 8 |
   | 3.5 s | 8 of 8 |
   | 6 s | 8 of 8 |

   So a foreign process that lives for 1 second or less usually escapes. The trials were back to back, so the phase is correlated, and the 2-second figure is probably high. The expected rate is about lifetime / 3.1 s.
2. **Pattern blind spots (`synth.txt`).** These command lines are NOT reported, whatever their lifetime:
   - `bash neg/run-all.sh` and `bash ./neg/run-all.sh`. This is how the operator, and `accept.sh:302`, start the neg suite. Its child processes use `$PWD/…` absolute paths (`neg/run-all.sh:90-99`), so they are visible only when a sample hits one of them.
   - `bash …/sealed-engine-v2/scripts/evidence.sh` (a second engine evidence run).
   - a `server.py --port 8199` started from its own folder.
   - `clang++ … -c runtime/main.mm` in `/tmp/child-repro-a`.
   - `./child/splash`.
   - any path that contains `sealed-accept/`.
   - any process whose command contains `SealedEngine`, and every child of such a process, including a second engine copy in another folder and its child.

   `wait_idle` and `busy` use the same awk, so the pre-step wait has the same gaps.
3. **The kit's own server (`tee-rootpass.sh:75-94`).** The fix is structural for the wrapper. The wrapper `$SP` is now killed last, so `sudo -u`, `python3 server.py` and `sealed-launch` no longer move to launchd when the wrapper dies, which is what happened in `…001248Z/root-foreign.txt`. The levels below the wrapper are still bounded by time:
   - `server.py` turns SIGTERM into `KeyboardInterrupt` (`server.py:1913-1925`).
   - Then `runtime.py:1328` sends SIGTERM to `sealed-launch` and waits `_shutdown_grace_seconds = 15.0`. After that it sends SIGKILL, waits 1 s, and exits.
   - `sealed-launch` kills and reaps the child at most 3 times (`sealed-launch.c:331-336`).

   If the child or the launcher takes longer than these limits, the next level up exits first, and the orphan moves to launchd. The kit's own comment says "A clean stop took 66 s once" (`tee-rootpass.sh:84`). Such an orphan has `sealed-m5/child/splash` in its command, so it is reported, and the run is marked INCONCLUSIVE. That is fail-safe: a false "not isolated", not a missed foreign process. So the fix is sound for what it targets, but it does not remove the timing dependence below the wrapper.
4. The input snapshot (`accept.sh:153-157`) records only the mtime and size of files under `child neg/B launcher tools pkg splash`. It does not cover `/tmp/sealed-reason.log`, the ports, or the scratch folders. A change that the step restores (same size, `touch -r`) is not seen.

Conclusion: `run/<step>-isolated` PASS means "no process whose command matched the pattern was seen at a 3-second sample". It does not mean "no other suite process ran", which is the evidence text (`accept.sh:630`). A short or differently named foreign process escapes.

## Reproducibility (question 4)

What `child-repro-check.sh` (`E/scripts/child-repro-check.sh`, commit `<h83>`) covers:

| Factor | Covered? | Evidence |
|---|---|---|
| Build folder | Yes | Copies in `/tmp/child-repro-a` and `/tmp/child-repro-bb` (different lengths). Both equal the pin, which was built in `M/splash`. |
| `HOME` | Yes, in the script. The stored evidence does not show it | `:17` sets `HOME=/tmp/child-repro-home` for copy 2. `evidence.sh:29` keeps only `tail -3` in a variable and writes a PASS line that does not name `HOME` (`R4/engine-evidence.txt:3`). The "HOME a=… b=…" line is in no file. My build-ID test (above) shows that `HOME` and `USER` do not change the ID. |
| User name, uid, `TMPDIR` | No | Both copies run as the same uid with the same `USER`, `LOGNAME` and `TMPDIR`. |
| Time | Partly | The two builds are minutes apart on the same date. `grep -rn '__DATE__\|__TIME__\|__TIMESTAMP__' M/splash/runtime` gives no output. The ad-hoc signature carries no timestamp. A different date is not tested. |
| Source from git | Not in the check (it uses `rsync` of the working tree). Settled by me at build-ID level | `git status --ignored` in `M/splash` shows only `build*/` and `__pycache__/` as ignored. All 150 build-ID inputs are tracked. `git archive bd77b6c` gives `src-<h31>…`. |
| Toolchain | No (same Xcode for both copies, and not recorded) | At audit time, with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`: Xcode 27.1 (27A9275), SDK 27.0, Apple clang 21.0.0 (clang-<build>), metal 32023.921 (metalfe-32023.921.6), Swift 6.4. The active `xcode-select` is CommandLineTools. |
| Machine | No | Same Mac17,7, same macOS 27.2-beta. |

What a second user or a second Mac still needs:
1. **Child `<h24>` source.** `M/splash` commit `bd77b6c` exists only on this Mac. It has no remote and no parent. It was committed at "<date> <time> 2026", which is after the accept run (<time> UTC). So `R4.json` names the child only by build ID, not by commit. Its base, incoai/splash 1.0.2, is the separate clone `~/projects/sealed-backends-spike/splash` (`6c6002d`). No history links the two, so an outsider cannot diff against upstream from git.
2. **Child recipe.** These are in the local-only engine commit: `make SEALED_DEFS=-DSPLASH_SEALED`, and `codesign -f -s - --options runtime -i sealed.splash` (`child-repro-check.sh:19-21`). `M/stage-child.sh` is not in git.
3. **Engine `<h20>` source.** Commit `<h83>` and the `proxy-router` client and verifier exist only on this Mac (hub `<h16>`).
4. **Engine identity.** A second party cannot make `<h20>` themselves. The CD hash covers the designated requirement of the operator's Apple Development certificate, the entitlements from the profile, and the resource seal that includes `embedded.provisionprofile` (`bundle.sh:22`, `:37`, `:68`). The route is `sealed-verify rebuild` against the published app. That needs `E/build/SealedEngineV2.app` (git-ignored, on this Mac only), the profile file (`bundle.sh` needs it in verify mode too), the fixed path `/private/tmp/sealed-engine-v2-build`, and Xcode 27.1 / Swift 6.4.
5. **Model hash `888212…`.** It needs the 16 GB `M/pkg/qwen38-27b` package and the child pin. The package is not in git.
6. **Layout.** `evidence.sh:19`, `r8-check.sh:11-12` and `start-engine.sh:8` hard-code `$HOME/projects/sealed-backends-spike/sealed-m5`. A second user must use that layout. `accept.sh` accepts `SEALED_M5` and `MORPHEUS_PNODE`.
7. **Two SealedGuard copies.** They are byte-identical today (`cmp`: SAME for `.c` and `.h`), but no check refuses a drift. The closure file states this (`:104`).
8. **Last second-Mac record.** `E/evidence/SECOND-MAC-REBUILD-r4-2026-10-22.md` covers engine `<h6>` and child `<h7>` only.

This test would settle byte reproducibility: on <host-b>, as a second user account with its own `TMPDIR`, build `git archive bd77b6c` with Xcode 27.1 (27A9275). Then sign it with the recipe in item 2 and compare the CD hash with `<h24>`. Then run `sealed-verify rebuild` from `git archive <h83>` against a copy of the published app.

## Findings

| id | severity | area | finding | evidence | recommended action |
|---|---|---|---|---|---|
| R4-4-01 | HIGH | reproducibility | No second-Mac, second-user or outside rebuild covers child `<h24>` or engine `<h20>`. The only proof is the same-Mac, same-uid `evidence.sh` run. The claim and the closure state this limit correctly. R3-4-01 is open. | `grep -rl '<h24>\|<h20>' E/evidence`: none. `CLAIM-v2-2026-10-24.md:57`. `OPEN-ITEMS-CLOSURE-2026-10-24.md:103`. | Run the <host-b> test in the section above, and commit the record under `E/evidence/`. |
| R4-4-02 | MEDIUM | matrix (evidence binding) | `matrix.py` checks the text of the 4 EXEMPT lines against files. It does not check the 138 PASS rows, and the report holds no hash of any evidence file. So an edit of the JSON and the file together passes (03), a PASS row that its file contradicts passes (04), and a folder with only `harness/` and `root-pass.txt` passes (07). `check_evidence_line` takes `base` = `reports/`, not the report's own folder, so a new report can cite a sibling report's lines (05, end to end rc 0). The closure says "Forged copies refused (session output only, no stored test)". That is true only for edits to the JSON alone. | `matrix.py:155-158` (`base = …parent`). `accept.sh:682-724` (no file hashes). `/tmp/r4-4/attack-out.tsv` cases 03, 04, 05, 07. `OPEN-ITEMS-CLOSURE-2026-10-24.md:88`. | Make `accept.sh` write a sha256 for each evidence file into the report (an `evidence_sha256` map). In `matrix.py`, check every file in that map, require the folder named by `evidence_dir` to equal the report stem, and set `base` to that folder. Store the attack cases as a regression test. |
| R4-4-03 | MEDIUM | harness (suite identity) | The scripts that make most of the evidence are not bound to the report. `neg/run-all.sh`, the neg case files outside `neg/B`, and `tools/entitlement-audit.sh` are in `M`, which is not in git. The report records no hash of them, and `snapshot` only shows whether they changed during the run. The kit hashes are checked but not recorded (`kit-installed-check.txt` holds only "OK" lines). An edited `run-all.sh` that prints 95 PASS lines and the controls gives an ACCEPTED report with an approved `tool_sha256`. | `R4/facts.tsv` keys (no suite hash). `accept.sh:153-157` (`find child neg/B launcher tools …`). `M`: "not a git repository". `R4/kit-installed-check.txt:1-3`. | Record the sha256 of `neg/run-all.sh`, `neg/` (a tree hash), `tools/entitlement-audit.sh` and the kit `SHA256SUMS` in the report, and add them to an approval list. Better: put `M` under git and record its commit, as for the engine. |
| R4-4-04 | MEDIUM | isolation | `run/<step>-isolated` PASS overclaims. The watcher samples every 3 s. Measured: a 0.3 s or 1 s foreign process was seen in 1 of 8 trials each. A 2.9 s or longer process was seen in 8 of 8. The pattern misses `bash neg/run-all.sh` (the usual way to start it), a second `evidence.sh`, relative-path servers, builds in `/tmp`, and any process that contains `SealedEngine` or `sealed-accept/`, plus every child of a `SealedEngine` process. The evidence text says "no other suite process ran". | `accept.sh:115-136`, `:630`. `/tmp/r4-4/sampler.sh` results. `/tmp/r4-4/synth.txt` with `awk -f procs.awk` (only 503, 507, 513 and 516 reported). | Use one shared lock that `neg/run-all.sh`, `evidence.sh`, `child-repro-check.sh`, `neg/build-all.sh` and `tee-rootpass.sh` all take (`flock` or `mkdir`), and make `accept.sh` hold it. Change the evidence text to "no matching process seen at 3 s samples". For level B, consider `eslogger exec` as root during the step. |
| R4-4-05 | LOW | root kit (server stop) | The wrapper fix is structural, but the lower levels still depend on time limits: the `server.py` grace of 15 s, then SIGKILL and a 1 s wait (`runtime.py:447`, `:1345`), and `sealed-launch` 3 kill tries (`sealed-launch.c:336`). A slow child teardown (66 s was seen once) still makes an orphan move to launchd. The result is a false INCONCLUSIVE (fail-safe), not a false PASS. | `tee-rootpass.sh:75-94`. `…001248Z/root-foreign.txt`. `R4/root-foreign.txt` (0 bytes). | Keep the fix. If false INCONCLUSIVE comes back, kill the child pid (recorded in `KIDS`) before the SIGTERM to the listener, or wait for `alive_recorded` to be empty before the server exits. |
| R4-4-06 | LOW | approval files | `approved-harness.txt` and `approved-required.txt` are mode 0444 in a folder that is not in git. The owner can `chmod` them and append a hash (case 24, ACCEPTED). The `harness/matrix.py` copy is not checked (case 23). The closure gives "file mode 0444" as the fix (`:89`). | `ls -l M/sealed-accept` (`-r--r--r--`). `matrix.py:140-146`, `:186`. Cases 23, 24. | Put `sealed-accept/` under git, and record the git blob of each approval file in the report. Check `harness/matrix.py` against an approved list too. |
| R4-4-07 | LOW | matrix (revocation) | `REVOKED_ARTIFACTS` has an `engine` key only. A report with engine `<h20>` and child `<h23>` (revoked for R2-4-02) is ACCEPTED (case 18). `kit_engine_cdhash` is not compared with `engine_cdhash` (case 19). The engine pins the child, so a real run cannot produce case 18, but the gate does not know that. | `matrix.py:124-137`, `:194-201`. Cases 18, 19. | Add a `child` list (`<h23>…` and earlier). Require `kit_engine_cdhash == engine_cdhash`. |
| R4-4-08 | LOW | matrix (A-2 pattern) | `cite()` keeps 400 characters (`accept.sh:473`). `check_evidence_line` compares only `[:400]` and returns the full line (`matrix.py:164-166`). The A-2 pattern ends in `.*`. So text after character 400 of a real line is never compared and always matches. Case 30b (a FAIL text after character 400) is ACCEPTED. The kit cannot make that line today, because `child=0` is fixed before the free text (`tee-rootpass.sh:181-183`). | Case 30b. `matrix.py:56-58`. | Make `cite()` keep the whole line, compare the whole line, and end the A-2 pattern at "System Integrity Protection is on ?". |
| R4-4-09 | LOW | matrix (row content) | R3-4-10 is open: PASS with control FAIL, PASS with empty evidence, junk required names, `totals` or `sip` that contradict the rows, and a wrong `evidence_dir` all pass. | Cases 25-29. `matrix.py:209-214`. | Apply the R3-4-10 action. Check `evidence_dir` (see R4-4-02). |
| R4-4-10 | LOW | harness (EXEMPT after isolation) | `isolation()` (`accept.sh:620-638`) runs before the EXEMPT loop (`:644-648`). In a run that is not isolated, a real `FAIL [A-4-endpoint-security]` becomes INCONCLUSIVE and then EXEMPT, with `arm_evidence` "run not isolated (was FAIL): …". `matrix.py` refuses the row (the cite does not parse), and `run/root-isolated` is required, so the verdict is INCOMPLETE. But the report counts a FAIL as EXEMPT in `totals`. Settled by reading the code, not by a run. | `accept.sh:634-636`, `:644-648`. `matrix.py:152-154`. | Convert to EXEMPT only rows whose evidence does not start with "run not isolated". |
| R4-4-11 | LOW | harness (retry, toolchain) | R3-4-12 and R3-4-15 are open. The retry count is not in the JSON, any "devicecheck" text triggers a retry, and each attempt overwrites the evidence. The evidence header still holds the `xcodebuild` error, so no file records the toolchain for the current pins. | `accept.sh:326-334`. `R4/engine-evidence.txt:1-2`. `E/scripts/evidence.sh:26`. | Apply the round-3 actions. Export `DEVELOPER_DIR` in `evidence.sh` before line 26, and record Xcode, SDK, clang, metal and Swift versions. |
| R4-4-12 | LOW | reproducibility (evidence) | The `child-reproducible` PASS line does not show that copy 2 used another `HOME`, so the evidence alone does not support the claim "two builds with different `HOME` values give the same bytes" (vacuous-pass rule 2c). The script does it, and my build-ID test agrees. User name, uid, `TMPDIR`, date and toolchain are not varied. | `evidence.sh:29-32`. `R4/engine-evidence.txt:3`. `child-repro-check.sh:13-21`. | Write the three tail lines (`HOME a=…`, `CD hash a=…`, `SAME…`) into the evidence file. Also run copy 2 with another `TMPDIR` and, where possible, as a second user. |
| R4-4-13 | LOW | records | `E/README.md:76` names commit `<h26>` for the current build, and the accepted commit is `<h83>`. `OPEN-ITEMS-CLOSURE-2026-10-24.md:92` gives the proof "child build ID `src-<h72>…` verified", which is the round-3 ID. The current ID is `src-<h31>…`. `E/README.md:3` still says "State: 2026-10-20". | Quoted lines. `R4.json` `source.SPLASH_BUILD_ID`. | Correct the three lines. |
| R4-4-14 | LOW | harness (TOCTOU) | `tool_sha256` and the harness copy are taken at the start (`accept.sh:177-180`). bash reads the rest of the script, including the report writer at `:420-741`, from the file while it runs. An in-place edit during the 18-minute run changes the code that runs, and the recorded hash does not change. Not tested. | `accept.sh:177-180`. | Copy the script to the report folder first and `exec` the copy, or put the whole body in a function that bash parses before the run. |
| R4-4-15 | INFO | checks that held | These checks held: `R4` totals are A 122/122 and B 138 PASS + 4 EXEMPT of 142. The four EXEMPT lines equal `R4/root-pass.txt:43, :48, :54, :55`. The harness copies hash to `<h30>…` (accept.sh) and `<h29>…` (required.json), and both are approved. `matrix.py accepted` answers yes in the scratch registry. The child CD hash is `<h24>…`, equal to `child/pin.txt`. The installed kit `tee-rootpass.sh` equals `tools/tee-rootpass.sh` (`<h91>…`). `neg-build-check.txt` lists 75 builds as current. `R4/root-foreign.txt` is empty. JSON-only forgeries, cut required lists, missing rows, revoked engines and unapproved harness hashes are all refused. | `/tmp/r4-4/attack-out.tsv`. `shasum` outputs above. | None. |

## Verdict

The round-3 fixes in the harness are real for edits to the JSON alone falsification-beats-confirmation:
- The EXEMPT gate opens the file and needs a full-line match.
- `required.json` and `accept.sh` are hash-bound and approved.
- Revoked engines are refused.
- A swapped stored file is caught.
- Stale test builds are refused.

`R4` passes every gate, and none of my findings changes its verdict.

The gates still trust the evidence folder and the suite scripts fail-loudly-not-silently:
1. No evidence file is hashed, and citations can point to a sibling folder (R4-4-02).
2. The neg suite and the entitlement audit are not bound to the report (R4-4-03).
3. The approval lists sit in the same writable folder, which is not in git (R4-4-06).

So anyone who can edit the folder can make an accepted report. These are hand-edit and harness-bug risks, so I rate them MEDIUM, not HIGH.

The isolation check is a 3-second sample over a name pattern. It misses processes that live for 1 s or less, and it misses the usual relative-path start of the neg suite (R4-4-04). The server-stop fix is sound for the wrapper. Below the wrapper, it depends on time limits, but it fails safe (R4-4-05).

`$HOME` no longer enters the child build ID. I confirmed this from `git archive bd77b6c` with two `HOME` and two `USER` values. But no second user, second Mac or outside party has rebuilt `<h24>` or `<h20>` judge-the-method-not-the-claim. Both sources exist only on this Mac, and the toolchain is not recorded (R4-4-01, R4-4-11, R4-4-12). I could not settle byte reproducibility with read-only work. The <host-b> test in the reproducibility section settles it.
