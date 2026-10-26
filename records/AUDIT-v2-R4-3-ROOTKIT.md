# AUDIT v2 round 4, area 3: root kit (2026-10-24)

Scope:

1. `tools/tee-rootpass.sh` and the installed copy `/usr/local/libexec/tee-rootkit/`.
2. The root-pass run `logs/tee-rootpass-<date>-<time>/` of the accepted report `sealed-accept/reports/Mac17,7-27.2-beta-20261025ThhmmssZ.json`. The copy in the report folder is `root-pass.txt` (`root-pass.txt:1` "=== TEE ROOT PASS <date>-<time>").
3. The round-3 findings in `review/AUDIT-v2-R3-3-ROOTKIT.md`.

The work was read-only. I did not use sudo. I did not start or stop the engine or any process. I wrote only this file. Side effects:

- One `ps -o lstart= -p 99999` call (a pid that does not exist). It printed nothing, `rc=1`.
- One temporary list `/tmp/r4a3-inst.txt` (file names of the installed kit) for a `diff`. I deleted it at once.

Line numbers below refer to the current `tools/tee-rootpass.sh` (sha256 `<h89>…5069078`). The installed copy and the copy that made the run are the same file (section 5).

## Pre-registered falsifiers

1. A round-3 finding counts as fixed only if the code changed and the new run shows the new behavior.
2. `stop_server` fails if it can leave a kit server alive, kill a process that is not the kit's, or wait without a bound. It also fails if a server that does not stop can go unnoticed.
3. A `P6-gcore` PASS is vacuous if a decoy failure (no pid, dead pid, no core, empty file) can still give PASS.
4. A root PASS is vacuous if the bad input did not reach the check, the control did not fire, or the evidence file is empty.
5. The installed kit fails identity if any file hash differs from the source, or if `engine-cdhash` is not `<h19>…`.

## 1. Round-3 findings: status

| Round-3 ID | Status | Basis |
|---|---|---|
| R3-01 decoy control evidence | FIXED | `tee-rootpass.sh:374-381` writes the decoy pid, user, flags, `rc`, core size and core sha256 into `gcore-ctl.txt`. PASS needs the line `^# decoy pid=[0-9]` (`:392`). This run: `gcore-ctl.txt` 149 B: "# decoy pid=93884 user=<developer> flags=0x2", "# gcore rc=0", "# core bytes=81920 sha256=<h90>…3532". Residual: see R4-3-07. |
| R3-02 decoy leak | PARTLY FIXED | `:383` stops the `sudo` child of the job (`pkill -P "$GCTL"`), the decoy and the job. This run: no "still alive" line in `gcore-ctl.txt`. The cleanup line says "0 control pids" (`root-pass.txt:80`). `pgrep -fl 'tee-rootkit\|ctlproc'` today prints nothing. Open part: the `kill -0` check at `:385` writes a log line only. `cleanup` (`:96-111`) does not kill a decoy that survived. No step grades `leftover > 0` (R4-3-03). |
| R3-03 engine pid binding (F-12) | OPEN in code, holds for this run | `:302` still takes `EPID` from `pgrep -f … \| head -1`. The run records no lstart and no CD hash for `EPID`. I checked it live: pid 87624 is the :29452 listener (`lsof`), started "<date> <time> 2026" (before the run at <time>), CD hash `<h19>…<h91>`, `flags=0x10000(runtime)`. Child 87817 has ppid 87624, lstart <time> (equal to `engine-child.txt`), CD hash `<h23>…ea6`. Only one process matches the `pgrep` pattern. |
| R3-04 hardened decoy (R2-09) | OPEN | The decoy is still ad-hoc: `gcore-ctl.txt` "flags=0x2". No hardened decoy runs in the arm. `OPEN-ITEMS-CLOSURE-2026-10-24.md:28` still says "R2-09 … fixed". `neg/P6/p6-gcore-retry.sh:6-7` still says the cores go to `/cores` (mtime <date> <time>, not changed). |
| R3-05 A-4 cause | PARTLY FIXED | The EXEMPT text is now correct about the binary: `accept.sh:433` "AMFI kills the kit client at launch (exit 137) … Not measured: … /usr/bin/eslogger". `matrix.py:47-49` matches the whole kit line. Open: no log excerpt shows that AMFI is the killer (`es.txt` 0 B, `root-pass.txt:47` "Killed: 9"). No `eslogger` arm exists. `accept.sh:429` still says "cannot PASS on any Mac of this fleet". |
| R3-06 A-2 pattern and FAIL-first | FIXED | `:179-184`: a child copy gives FAIL before any control branch. `matrix.py:56-58` needs "child=0; " and "probe description syscall::read:entry does not match any probes\.", as a full-line match (`matrix.py:240`). This run: `root-pass.txt:43` holds both. The INFO label (not INCONCLUSIVE) stays, which is cosmetic, because the gate maps INFO to EXEMPT or INCONCLUSIVE. |
| R3-07 R4-T5 rows | PARTLY FIXED | The patterns are now full-line (`matrix.py:50-55`). They still accept the generic "Bootstrap failed: 5: Input/output error". The launchd reason ("failed to uncork PID domain … 131", `:229`) is not in `bootstrap*.txt` (40 B each, that text only). `r4t5-control.sh` exists in `tools/tee-rootkit/` but is not in `SHA256SUMS` (`grep -c r4t5` = 0) and neither the kit nor `accept.sh` runs it. |
| R3-08 round-1 kit findings | OPEN | F-6: `mount-ctl.txt` 0 B, `mc_rc` not written (`:208-213`). F-7: no request to the second server, no positive control (R4-3-02). F-8: three failed `com.apple.Metal.plist` reads at <time> (`fsusage.txt`). F-9: `/dev/dtracehelper` opened `(RW…)` at <time> by `splash.79165264`. F-10: `:203` does not gate on `on8199` (2 in this run). F-11: `:306-310` P10 engine arms have no control in their rule. F-12: R3-03. F-13: `kern.coredump: 1`, `kern.corefile: /cores/core.%P` (`root-pass.txt:22-23`). F-15: `zero_pages=16384` of 16384 (`root-pass.txt:58`). F-17: `answer=` empty (`root-pass.txt:28`): `answer1.json` has `"content":null`, and the 48 tokens went to `reasoning_content`. |
| R3-09 length record | OPEN (checked by listing only) | `neg/LEN/len-grade.py` and `len-root.sh` keep mtime <time>. The run folder `len-20261024-<time>/` still holds no grader output and no tokenizer count. |
| R3-10 length grader | OPEN (checked by listing only) | `len-grade.py` is not changed (mtime <time>). |
| R3-11 end token | FIXED | `LENGTH-ROOT-2026-10-24.md:3` "the reply token count (including the end token)". |
| R3-12 length wording | FIXED | `LENGTH-ROOT-2026-10-24.md:3` "`fs_usage` shows byte counts and times, not payloads, so this test can not show content either way". `:24` "the network shows the prompt byte length, not the token count". |

## 2. New `stop_server` logic (`:75-95`)

Sequence:

1. SIGTERM goes to the :8199 listener (`port_pid`). If no listener exists, it goes to the recorded inner pids, deepest first (`:82-83`).
2. The kit waits up to 90 s for the recorded inner pids and the listener to go (`:85`).
3. SIGKILL goes to the inner pids and the listener (`:86`). The kit waits 10 s (`:87`).
4. SIGKILL goes to all `server_pids`, which includes the wrapper `$SP` (`:88`).
5. The kit waits up to 300 s for the port to free (`:89`). If it stays busy, `STOP_WHY` is set and the function returns 1 (`:90-93`).

### 2.1 Can it leave a process alive?

Yes, in two narrow cases. Neither occurred in this run.

- The function returns 0 when the port is free (`:89-94`). It does not check that the recorded pids are gone. A recorded process that survives SIGKILL (for example, a process in an uninterruptible kernel wait) is not reported by `stop_server`. `:275` and `:102` send SIGKILL again, and the cleanup line counts it, but nothing grades that count (R4-3-03).
- Only recorded pids and the :8199 listener get signals. A descendant that starts after the last `record_tree` (`:141`, `:148`, `:280`) and does not hold :8199 gets no signal (R4-3-04).

This run: `root-pass.txt:80` "leftover=0 kit pids, 0 control pids". `root-foreign.txt` 0 B, `ent-foreign.txt` 0 B. Today no :8199 listener and no `ctlproc` exist.

### 2.2 Can it kill a process that is not the kit's?

Yes, in one narrow case. `port_pid` (`:63`) returns any :8199 listener, and root sends it SIGTERM (`:82-83`) and SIGKILL (`:86`, `:88`). The preflight (`:122`) shows that :8199 was free at the start. A foreign process can be hit only if the kit server lost the port during the run and another process bound it. The engine (:29452) and the engine child (not recorded, not on :8199) cannot be hit. Recorded pids carry the lstart, so a reused pid does not match (but see R4-3-05). The header comments do not describe the port kill: `:26-28` and `:55-57` say "kills only those", and `:71-72` says "send SIGTERM to every recorded pid", which the new code at `:78-83` does not do (R4-3-04).

### 2.3 Can it hang?

No, not without a bound. The loops are bounded: 90 s + 10 s + 300 s, so about 400 s for each call. `stop_server` runs at most twice (R4-T4 at `:272` and `cleanup` at `:101`), so the worst case is about 800 s. `accept.sh` `run_step` uses `wait` with no timeout, so these loops are the only bound. Measured in this run:

- R4-T4 stop: `server.log` "<time> Stopping", and `server2.log` "<time> Loading". The stop took about 2 s.
- Cleanup stop: `server2.log` "<time> Stopping", and the folder mtime is <time>.

A phantom entry (R4-3-05) makes the 90 s loop run in full. It is still bounded.

### 2.4 Does the kit still detect a server that does not stop?

- At R4-T4: yes. A return of 1 sets `R4T4_OK=0` and prints `STOP_WHY` (`:272-273`). Both R4-T4 arms then print INCONCLUSIVE (`:291`, `:294`).
- At cleanup: no. `:101` ignores the return value and does not print `STOP_WHY`. The exit code stays 0, because the trap does not call `exit`. The cleanup line is written after the copy to `logs/` (`:109-110`), so the run folder log does not hold it (the run log ends at the "end" line; only `root-pass.txt:80` has it). `accept.sh` grades `root/suite` on the exit code and the end line only. It watches for foreign processes only while the step runs, and `isolation()` is called for `neg`, `engine` and `root` only (`accept.sh:640-642`), not for `ent`. So a server that does not stop at cleanup gives no FAIL in this report. The next accept run fails closed: `wait_idle` sees it through `procs.awk` and SKIPs its steps (R4-3-03).

## 3. `P6-gcore` decoy (`:371-396`)

### 3.1 This run

- `gcore-ctl.txt`: "# decoy pid=93884 user=<developer> flags=0x2", "# gcore rc=0", "# core bytes=81920 sha256=<h90>". No "still alive" line.
- The decoy is not the A-1 control. The A-1 control is pid 89998 (`lsmp-ctl.txt:1` "Process (89998) : ctlproc"). The job subshell was 93880 (`root-pass.txt:71` "93880 Terminated: 15"). `pgrep -n -u "$U" -x ctlproc` (`:374`) excludes the root `sudo` wrapper.
- Targets: `gcore-engine.txt` and `gcore-engine-child.txt` are 55 B each: "gcore: insufficient privilege: Operation not permitted". Both lines say `rc=77`. Both pids were live and bound to the accepted build (section 1, R3-03).

### 3.2 Can a decoy failure give PASS?

No. I checked each branch of `:391-394`:

| Decoy failure | Effect | Can it PASS? |
|---|---|---|
| No decoy started, and no other user `ctlproc` | `GCTLPID` empty. The header is "# decoy pid= user=…", so `^# decoy pid=[0-9]` fails. INCONCLUSIVE. | no |
| `gcore` on the decoy fails | `g_ctl ≠ 0`. INCONCLUSIVE. | no |
| `gcore` returns 0 but writes no core | `g_ctl_sz` = 0 (`stat` of the fresh `$GD/ctl` fails). INCONCLUSIVE. | no |
| `rc` line missing | `g_ctl` empty, so `[ "" != 0 ]`. INCONCLUSIVE. | no |
| Decoy alive after cleanup | `:385` writes a line, and the grade ignores it. | no effect on the grade |
| The new decoy did not start, but the A-1 `ctlproc` (alive) is picked | The control dumps the A-1 process. It is the same binary, flags and uid, so it is a valid control of the same kind. The record calls it the decoy (R4-3-07). | PASS, with a valid control |

The `kill -0` check is a hygiene log only. A surviving decoy does not change the grade and is not killed in `cleanup` (R3-02 open part).

## 4. Vacuous-pass check of every root arm in `root-pass.txt`

(a) = the bad input reached the check. (b) = the control fired. (c) = the evidence file is non-empty and supports the verdict.

| Arm (`root-pass.txt` line) | (a) | (b) | (c) | Result |
|---|---|---|---|---|
| A-1-task-ports (`:40`) | `tp-child.txt` on pid 89154. 89154 is in `kit-pids.txt` and is `child/splash` (`lsmp-child.txt:1`). | `tp-ctl.txt`: "task_for_pid kr=0", "read kr=0". | `tp-child.txt` 92 B: "kr=5", "kr=-1" (`taskports.c:27`: -1 is the real return, the symbol was found). | Passes. |
| A-2-dtrace-attach (`:42`) | `dt-attach-child.txt` "failed to grab pid 89154". | `dt-attach-ctl.txt` "matched 2 probes". | 120 B and 682 B. | Passes. |
| A-21-mount-over (`:51`) | `mount.txt` "Operation not permitted" over `/usr/share/man`. | Only by the code path (`mc_rc=0` is needed for this branch). | `mount-ctl.txt` 0 B. `mc_rc` is not written. | **Fails (c) for the control** (R4-3-01). |
| R4-T4-no-metal-cache-outside-tmpdir (`:62`) | 467 child events from dyld (<time>) up to <time>. Ready is <time>. No request goes to the second server, so a first-request compile is not covered. | None. No positive control shows that a Metal cache write would be seen. | `fsusage.txt` 116,283 B. | **Fails (b)**, and (a) only partly (R4-3-02). |
| P10-engine-task-ports (`:65`) | `tp-engine.txt` on 87624 (live check, R3-03). | Not in the arm's rule (`:306`). The shared control fired in this run (`tp-ctl.txt`). | 92 B, "kr=5", "kr=-1". | Passes in this run. Rule gap F-11. |
| P10-engine-dtrace-attach (`:66`) | "failed to grab pid 87624". | Not in the rule (`:309`). The shared control fired (`dt-attach-ctl.txt`). | 120 B. | Passes in this run. Rule gap F-11. |
| P10-engine-child-task-ports (`:68`) | 87817, ppid 87624. | `k_for=kr=0`, reads ≥ 1 (`:340`). | 92 B. | Passes. |
| P10-engine-child-dtrace-attach (`:69`) | "failed to grab pid 87817" (by the line). | `a_ctl ≥ 1` (`:351`). | 120 B. | Passes. |
| P10-lo0-ciphertext-only (`:70`) | `p10-chat.txt`: the attested CD hash `<h19>…` "matches the pinned hash", and "REPLY … P10ROOTCANARY17928990773571". | Not in the rule (F-10). In the same run, `strings lo0.pcap` finds the :8199 canary 2 times. | `lo0-engine.pcap` 14,393 B, 40 packets on 3 connections to :29452, 0 canary hits (my recount). | Passes in this run. Rule gap F-10. |
| P6-gcore-engine (`:72`) | `rc=77` "insufficient privilege" on live 87624. | The decoy dumped 81,920 B (section 3). | 55 B, and `gcore-ctl.txt` 149 B. | Passes. |
| P6-gcore-engine-child (`:73`) | `rc=77` on live 87817. | Same decoy. | 55 B. | Passes. |
| root/suite (report) | exit 0, end line "11 PASS, 0 FAIL, 3 INCONCLUSIVE, 8 INFO". | n/a | `root-pass.txt` 6,887 B. | Passes. |

The four EXEMPT rows (A-2-dtrace-read, A-4, R4-T5 ×2) are not PASS rows. Their status is in section 1 (R3-05, R3-06, R3-07).

## 5. Installed kit identity

- `shasum -a 256` gives `<h89>` for `tools/tee-rootpass.sh`, `tools/tee-rootkit/tee-rootpass.sh` and `/usr/local/libexec/tee-rootkit/tee-rootpass.sh`. `SHA256SUMS` lists the same hash.
- `diff tools/tee-rootkit/SHA256SUMS /usr/local/libexec/tee-rootkit/SHA256SUMS` is empty.
- All 16 entries print OK in both folders. I compared each installed file with its source file by hash, and no file differs.
- The installed folder holds 17 files: the 16 listed files and `SHA256SUMS`. No unlisted file exists.
- `engine-cdhash` = `<h19>`. `engine-modelhash` = `<h83>`. `engine-appid` = `<TEAM>.<bundle-id>`. These equal the round-4 pins.
- The installed files have mtime <time>. The run started at <time>. The stderr line numbers in `root-pass.txt` (`line 196` esclient, `line 85` the stop loop, `line 398` the end of the P10 block) match the current source.
- The report rows `kit/installed-hashes`, `kit/installed-equals-source` and `kit/engine-identity` are PASS, and they agree with my check.

## Findings

| ID | Severity | Area | Finding | Evidence | Recommended action |
|---|---|---|---|---|---|
| R4-3-01 | MEDIUM | A-21 control (F-6) | A-21-mount-over PASS fails vacuous-pass rule (c) for its control. The control evidence is empty, and its return code is not recorded. Only the code path shows that the control fired. | `mount-ctl.txt` 0 B. `tee-rootpass.sh:208-213`. `root-pass.txt:51`. | Write `mc_rc`, the `mount` line of the scratch mount and the `umount` result into `mount-ctl.txt`. Require that line for PASS. |
| R4-3-02 | MEDIUM | R4-T4 (F-7) | R4-T4 PASS has no control, and the second server gets no request. It shows absence only. The `splash` name filter also matches the engine's live child 87817, so the 467 events cannot be tied to one pid. | `root-pass.txt:62`. `fsusage.txt` (threads `splash.79165264`, `splash.79165266` only). `server2.log` has no "Done" line. `tee-rootpass.sh:276`. | Send one request to the second server under `fs_usage`. Add a positive control (an unsandboxed Metal client that writes a cache under the same capture). Filter by the kit child's pid. |
| R4-3-03 | LOW | Cleanup detection | `cleanup` ignores the return of `stop_server` and does not print `STOP_WHY`. The exit code stays 0. The cleanup line is written after the copy to `logs/`, so the run folder does not hold it. `accept.sh` does not grade it, and does not grade `ent` isolation. A server or decoy that does not stop at cleanup gives no FAIL in the report. The next accept run fails closed. | `tee-rootpass.sh:101`, `:109-110`, `:385`. The run log ends at the end line, and `root-pass.txt:80` has the cleanup line. `accept.sh:640-642`. | Check the return at `:101` and print `STOP_WHY`. Write the cleanup line before the copy. Exit non-zero if `leftover > 0` or control pids > 0, so `root/suite` FAILs. |
| R4-3-04 | LOW | `stop_server` scope | It returns 0 when the port frees, without a check that the recorded pids are gone. A descendant started after the last `record_tree` that does not hold :8199 gets no signal. Any :8199 listener gets SIGTERM and SIGKILL, including a foreign one that bound the port during the run. The comments `:26-28`, `:55-57` ("kills only those") and `:71-72` ("SIGTERM to every recorded pid") do not match `:78-88`. Nothing of this occurred in this run. | `tee-rootpass.sh:63`, `:82-94`. `root-pass.txt:80` "leftover=0". `root-foreign.txt`, `ent-foreign.txt` 0 B. | Check that `server_pids` is empty before return 0. Record the tree again just before the stop. Before the signal, check that the listener is in `kit-pids.txt`, or log it as foreign. Correct the comments. |
| R4-3-05 | LOW | Pid records | `record_tree` writes an empty lstart if the pid exits between `pgrep` and `ps`. `alive_recorded` then reports that dead pid as alive, because the empty `ps` output equals the empty field. The effect is fail-noisy: the 90 s wait runs in full, and the cleanup count is falsely above 0. It is not fail-open. All 18 lines in this run have an lstart. | `tee-rootpass.sh:60-61`. Measured: `ps -o lstart= -p 99999` prints nothing (`rc=1`). `kit-pids.txt`. | Skip a pid with an empty lstart in `record_tree`, or require a non-empty field in `alive_recorded`. |
| R4-3-06 | LOW | A-1 control pid | The A-1 control pid still comes from `pgrep -n -f "tee-rootkit/ctlproc"`, which also matches the root `sudo` wrapper. In this run it chose the user's `ctlproc` 89998, and the control read memory, so the result holds. The `gcore` decoy got the `-u -x` fix, but A-1 did not. | `tee-rootpass.sh:156`. `lsmp-ctl.txt:1` "Process (89998) : ctlproc". `tp-ctl.txt`. | Use `pgrep -n -u "$U" -x ctlproc`, and write the pid into `tp-ctl.txt`. |
| R4-3-07 | LOW | Decoy record | `flags=` comes from `codesign -dv "$K/ctlproc"`, which is the file, not the running decoy. If the new decoy does not start, `pgrep -n -u "$U" -x ctlproc` picks the A-1 control. That is still a valid control of the same kind, but the record names it the decoy. In this run 93884 is the new decoy. | `tee-rootpass.sh:374-376`. `gcore-ctl.txt:1`. | Take the decoy pid from `pgrep -P` of the job's `sudo` child. Record `codesign -dv <pid>` and the lstart. Refuse a decoy pid that equals `CTLPID`. |
| R4-3-08 | LOW | Closure record | The closure row for R3-01 and R3-02 cites the root pass `<time>`. That run belongs to the revoked report `…20261025ThhmmssZ` (engine `<h20>`). The accepted run `<time>` shows the same facts. | `OPEN-ITEMS-CLOSURE-2026-10-24.md:91`. `logs/tee-rootpass-<date>-<time>/p10-chat.txt` "CD hash <h20>…". `…20261025ThhmmssZ/root-pass.txt:1`. | Cite `logs/tee-rootpass-<date>-<time>/gcore-ctl.txt` (decoy pid 93884, rc 0, 81,920 B, sha256 `<h90>…`). |
| R4-3-09 | LOW | Round-3 items still open | R3-03 (no lstart or CD hash for `EPID`), R3-04 (no hardened decoy, closure `:28` says fixed, stale `/cores` comment), R3-05 rest (no AMFI evidence, no `eslogger` arm, `accept.sh:429`), R3-07 (generic `rc=5` text, C1-C6 control not run), R3-08 (F-8 to F-13, F-15, F-17), R3-09, R3-10. | Section 1. | Do the round-3 actions. Priority: R4-3-01 and R4-3-02, then R3-04 and the closure text. |

No CRITICAL or HIGH finding.

## Verdict for this area

The root kit that made report `…20261025ThhmmssZ` is the kit in the source tree, byte for byte, and it pins engine `<h19>…` and model `<h83>…` (go-upstream-to-the-source). The new `stop_server` fixed the isolation failure of report `…20261025ThhmmssZ` in this run: both stops took about 2 s, the cleanup line says 0 leftovers, and the harness saw no foreign process. Its loops are bounded at about 400 s for each call, so it cannot hang without a bound. It can, in narrow cases, leave a recorded process alive or signal a foreign :8199 listener. A server that does not stop at cleanup is not reported in the report, only by the next run, which fails closed (R4-3-03, R4-3-04) (fail-loudly-not-silently).

The `gcore` decoy fix is real. `gcore-ctl.txt` now records the pid, `rc`, size and hash, and every decoy failure grades INCONCLUSIVE, so a decoy failure cannot give PASS (falsification-beats-confirmation). I confirmed live that the `gcore` and P10 targets were the accepted engine and child. Of the eleven root PASS lines, two still fail the vacuous-pass rule: A-21 (empty control file) and R4-T4 (no control). Three P10 arms pass in this run only because a shared control fired that their own rule does not require (judge-the-method-not-the-claim). These are open round-1 items, and they do not make any PASS false in this run. The closure file cites a root pass of a revoked build for the decoy fix and still calls R2-09 fixed (R4-3-08, R3-04).
