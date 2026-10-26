# P6: can root read the prompt or the reply from GPU memory? (2026-10-23)

Host: M5, Mac17,7, macOS 27.2 beta `27.2-beta`, SIP enabled (`csrutil status`), `kern.bootargs` empty. Production child pin `<h21>`. Running engine: `SealedEngineV2` pid 75296. Its production child: pid 75418 (`child/splash`, CD hash = pin). Rules: `scratch/TASK-gpu-tests.md`. Task: `scratch/TASK-P6.md`.

Status: done. User-level arms (section 5.1), root arms (section 5.2 and "Root result"), suite 95/95 (section 8). Corrected 2026-10-24 after audit round 2: see "Corrections" at the end.

## 1. What "GPU memory" is in the child

Apple Silicon has unified memory. A Metal buffer is one of two kinds:

1. **Shared or managed storage.** The pages are mapped into the process's CPU address space as `IOAccelerator (graphics)` regions (VM tag 100). Any holder of a task port with read access can read them.
2. **Private storage.** The pages have a GPU address only. They are not in the process's VM map. `footprint` shows them as `Owned physical footprint (unmapped) (graphics)`.

The serving production child (pid 75418, 13 minutes after a request) has 1.5 GiB of mapped `IOAccelerator (graphics)` memory in 36 regions, and 34 MiB of unmapped GPU memory (`vmmap -summary`, `footprint`, run as the user). The chunked KV cache uses private `MTLBuffer` chunks (`review/CHUNKED-KV-2026-10-23.md:27`). Token and activation buffers that the CPU reads are in the mapped kind.

## 2. Path list

| # | Path (root-reachable) | Reaches | Evidence |
|---|---|---|---|
| P6-1 | `task_for_pid` / `task_read_for_pid` + `mach_vm_read` on the mapped range of a Metal buffer | Contents of shared buffers only. Private buffers: nothing, even with a full control port. | Control (section 4, arm A1): the scanner gets the `S-` canary 1024 times from the shared buffer of a `get-task-allow` victim, in region tag 100, and 0 times the `P-` canary that exists only in the private buffer, after a walk of 7.58 GB of the victim's address space. Root kit `logs/tee-rootpass-<date>-<time>/tp-child.txt` and `tp-engine.txt`: `task_for_pid kr=5`, `task_read_for_pid kr=-1`, with the control `tp-ctl.txt` `kr=0`, `read kr=0`. |
| P6-2 | Apple tools that hold task-port entitlements, run as root: `gcore` (`com.apple.security.cs.debugger.read.root`), `vmmap`, `heap`, `leaks`, `stringdups`, `malloc_history`, `sample`, `lsmp`, `symbols`, `spindump` (`com.apple.system-task-ports.read`), `footprint` (`com.apple.system-task-ports.read.safe`, `com.apple.private.ioaccelmemoryinfo`) | Unknown for root. Contents if the kernel gives these tools a read port to the hardened child. As the user: metadata only. | `codesign -d --entitlements -` on each tool (section 3). Root kit: `lsmp` as root listed the child's port space (`lsmp-child.txt`), so a platform tool with `system-task-ports.read` gets at least an inspect-level view of the child as root. `stringdups` as the user: "Process … is not debuggable. Due to security restrictions, stringdups can only show contents of readonly memory of restricted processes." `gcore` as the user on the child: `insufficient privilege`. Root test: section 5, arms A2 and A3. |
| P6-3 | IOKit GPU user clients (`AGXDeviceUserClient`, the `IOGPUDeviceUserClient` class, `IOAccelerator*`) opened by a root process | Nothing found through the public path. Private selectors: not tested. | The child holds one `IOKIT-CONNECT AGXDeviceUserClient` right (`lsmp-child.txt`). Each client records its creator (`ioreg -c AGXDeviceUserClient`: `"IOUserClientCreator" = "pid 433, WindowServer"`). The `AGXAcceleratorG17X` service shows only totals (`PerformanceStatistics`: `"Alloc system memory"`, `"In use system memory"`, utilization). Arm A4: a process that opens the GPU client through Metal and scans its whole address space finds 0 bytes of a live victim's canaries. Root form of A4: section 5. |
| P6-4 | Kernel memory: `/dev/kmem`, `/dev/mem`, `kern.*` sysctl, kernel debugger | Nothing | `ls /dev/kmem /dev/mem`: `No such file or directory`. No `kern.kmem*` sysctl. `kern.bootargs` is empty. Boot arguments and kernel debugging need SIP off (Reduced Security), and the claim assumes Full Security. Third-party kexts also need Reduced Security. `kern.kdp_corefile: /System/Volumes/VM/kernelcore` is a panic-dump path (P5e, not measured). |
| P6-5 | GPU capture and debug layers: `MTLCaptureManager`, Xcode frame capture, `MTL_CAPTURE_ENABLED` / `METAL_CAPTURE_ENABLED`, `MetalCaptureEnabled`, `MTL_DEBUG_LAYER`, `MTL_SHADER_VALIDATION*`, `MTL_HUD_ENABLED` | Nothing without the child's cooperation | Switch names found in the dyld shared cache (section 3). Each switch is read from the environment, the app's `Info.plist`, or a preference file. (a) Environment: R2 refuses any extra environment variable at exec (`neg/run-all.sh` R2 case "extra environment variable"). (b) `Info.plist`: the child is a bare Mach-O with no bundle. (c) Preference files: Metal opens `/Library/Preferences/com.apple.Metal.plist` and two `Managed Preferences` paths in the child (`fsusage.txt`, `[  2]` ENOENT). Arm A5: under the child's read rules, an existing root-owned file in `/Library/Preferences` gives `errno=1 (Operation not permitted)`, and the unsandboxed control reads it. (d) A capture must also be started inside the process: the child has 0 `MTLCaptureManager` / `startCapture` strings. Xcode capture attaches through a debugger port, which is P6-1. (e) Debug output goes to fd 2 (`/dev/null`) or the unified log. A capture file needs a write rule, and the profile has none. |
| P6-6 | `powermetrics`, IOReport, `ktrace` / Instruments GPU traces, `footprint`, `vmmap` | Metadata only | `powermetrics -h`: the GPU sampler is "gpu power and frequency info", plus `--show-process-gpu` "per-process gpu time". As the user, `vmmap` and `footprint` give the sizes of the child's GPU regions (section 1) and no bytes. Root form with a canary grep: section 5, arm A6. |
| P6-7 | Freed GPU pages given to a second process (residue) | Owned by the K-2 test | `neg/k2-2026-10-23.txt` and `review/K2-FREED-KV-2026-10-23.md` (separate task). Its first lines show fresh private and shared buffers in a second process read as zero (`nonzero=0`). A root process gets the same allocator as a user process, so the K-2 result applies to root. |
| P6-8 | Swap, compressor, hibernation image | Covered by P5a and P5d | Private GPU buffers are wired while in use. These paths are not GPU-specific. See `review/AUDIT-v2-5-CLAIMS.md` C5-05, C5-06. |
| P6-9 | DMA from a peripheral (Thunderbolt, PCIe) | Not a root-software path | Apple Silicon puts each DMA agent behind a DART (IOMMU). Not tested here. |

## 3. Commands for the path list

```
codesign -d --entitlements - --xml <tool> | plutil -p -     # P6-2, each tool in the table
ls -l /dev/kmem /dev/mem; sysctl kern.bootargs; csrutil status   # P6-4
grep -a -o -E "(MTL_CAPTURE[A-Z_]*|METAL_CAPTURE[A-Z_]*|MetalCapture[A-Za-z]*|MTL_DEBUG_LAYER|MTL_HUD[A-Z_]*|MTL_SHADER_VALIDATION[A-Z_]*)" \
  /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e.*   # P6-5
strings -a child/splash | grep -ciE "MTLCaptureManager|startCapture|captureManager"     # P6-5: 0
ioreg -r -c AGXAccelerator -d 1 -w0; ioreg -c AGXDeviceUserClient -w0 -r                  # P6-3
powermetrics -h                                                                           # P6-6
```

## 4. Tests (criteria written before each run)

Programs (all in `neg/P6/`):

- `p6-victim.m`: an ordinary Metal program. It puts `P-<canary>` into a 4 MiB private buffer by a GPU blit, then clears the shared buffer and writes `S-<canary>` into it. So `S-` exists only in shared (CPU-mapped) memory, and `P-` exists only in private GPU memory. Three signatures: `p6-victim` (ad hoc), `p6-victim-hr` (ad hoc, hardened runtime, no entitlements: the same signature class as `child/splash`, `flags=0x10002(adhoc,runtime)`), `p6-victim-gta` (ad hoc with `com.apple.security.get-task-allow`).
- `p6-scan.c`: asks for `task_for_pid`, then `task_read_for_pid`, walks every region with `mach_vm_region_recurse`, reads each readable region with `mach_vm_read`, and counts `S-` and `P-`.
- `p6-gpuclient.m`: opens the GPU client through Metal, writes its own control canary `C-` by a GPU blit, then scans its own address space for `C-`, `S-` and `P-`.
- `p6-prefs.c`: opens a file, optionally after `sandbox_init` with the child's file-read rule classes.
- `p6-user.sh` (no root) and `p6-root.sh` (operator, `sudo`).

Criteria, fixed before the runs:

| Arm | PASS (root cannot read) | FAIL (OPEN) | VOID |
|---|---|---|---|
| A1 task port | The child and the hardened victim give no task port with read access, and the scanner reads 0 bytes. | The scanner reads any region of the child, or finds `S-` in the hardened victim. | The control (the `get-task-allow` victim as the user, or the ordinary victim as root) does not give `S-` > 0. |
| A2 `gcore` | `gcore` on the child and the hardened victim stops with a privilege error and writes no core. | `gcore` writes a core of the child or of the hardened victim. | `gcore` on the control victim does not write a core with `S-` > 0. |
| A3 entitled tools | `stringdups` and `vmmap` give no writable-memory contents of the child (restriction line, 0 canary hits). | Any canary hit in a hardened target. | `stringdups` gives no restriction line and no hit for any target (the tool did not run). |
| A4 GPU client | `S-` = 1 and `P-` = 1 (the pattern strings in the scanner itself, measured with no victim) while the victim runs. `C-` > 1. | `S-` > 1 or `P-` > 1 while the victim runs. | `C-` ≤ 1: the scan does not see GPU-written memory. |
| A5 preference file | The sandboxed read of an existing root-owned file in `/Library/Preferences` is refused with `EPERM`, the unsandboxed read succeeds, and the sandboxed read of `/usr/share/dict/words` succeeds. | The sandboxed read succeeds. | The unsandboxed control fails, or the allowed path fails. |
| A6 counters | `powermetrics` output has 0 canary hits and only numbers. | A canary hit. | `powermetrics` does not run. |

## 5. Results

### 5.1 User-level run (stored)

Run: `neg/P6/p6-user.sh 75418`, <date> <time> to <time> local, uid 501. Output: `neg/P6/user-20261023-<time>.txt`. Targets: `p6-victim-gta` pid 20001, `p6-victim` pid 20182, `p6-victim-hr` pid 20326, production child pid 75418 (pin `<h21>…`). The child was alive after the run.

| Arm | `get-task-allow` victim (control) | ordinary victim | hardened victim | production child | Grade |
|---|---|---|---|---|---|
| A1 task port | `task_for_pid kr=0`, hit in region tag 100, `S=1024 P=0`, 7,580,631,040 bytes read | `kr=5`, `task_read_for_pid kr=-1`, 0 bytes | `kr=5`, `kr=-1`, 0 bytes | `kr=5`, `kr=-1`, 0 bytes | PASS (user). The control fired. |
| A2 `gcore` | `rc=0`, core 7,565,033,472 bytes, `S=1024 P=0` | `rc=77 insufficient privilege` | `rc=77 insufficient privilege` | `rc=77 insufficient privilege` (`-x stack`) | PASS (user). The control fired. |
| A3 entitled tools | `stringdups` 0 hits, no restriction line. `vmmap` and `footprint`: sizes only | restriction line, 0 hits | restriction line, 0 hits | restriction line ("not debuggable … only … readonly memory of restricted processes"), 0 hits. Sizes: 1.5G mapped graphics, 34 MB unmapped | PASS (user), metadata only. Note: `stringdups` reads only malloc memory, so it is not a content tool for Metal buffers. `gcore` (A2) is the content tool. |
| A4 GPU client | — | — | — | — | `C=257 S=1 P=1` with the victims running, and `C=257 S=1 P=1` with another canary (baseline). PASS (user): 0 cross-process bytes. The control `C=257` (256 GPU-written copies + 1 pattern string) fired. |
| A5 preference file | — | — | — | — | Unsandboxed `ok read=16`. Sandboxed existing root file `errno=1 (Operation not permitted)`. Sandboxed `/usr/share/dict/words` `ok read=16`. PASS. |

Two facts from A1 and A2 carry the GPU question:

1. A task port with read access reaches the shared Metal buffers. In the control, both the scanner and `gcore` read the `S-` canary 1024 times out of 1024 pages.
2. A task port, even a full control port, does not reach private Metal buffers. In the control, the scanner read 7.58 GB and `gcore` wrote 7.57 GB, and each found the `P-` canary 0 times. The `P-` canary is in the private buffer (the victim wrote it there by a GPU blit, then cleared the CPU copy). Thus the KV chunks (private) are outside every task-port path. The child's shared buffers (1.5 GiB mapped) are inside it.

Caveat on fact 2: the scan proves that the private buffer is not in the CPU address space. It does not prove that no kernel path reads it. Private pages are reachable only through the GPU driver (P6-3) or the kernel (P6-4).

### 5.2 Root run (operator)

The sudo grant runs only `/usr/local/libexec/tee-rootkit/tee-rootpass.sh --yes`. That script has no P6 arm. So the root arms stop here and wait for the operator.

Operator command (one line, while a sealed child serves; the running engine's child is fine, because every arm on the child only asks for a port or writes a stack-only core that the script deletes):

```
cd ~/projects/sealed-backends-spike/sealed-m5 && sudo neg/P6/p6-root.sh "$(pgrep -f 'sealed-m5/child/splash serve-native' | head -1)"
```

The script writes `neg/P6/root-<time>.txt`. It runs, as root:

- A1: `p6-scan` against the ordinary victim (control: root kit `ctlproc` shows that root gets a port to an unhardened process), the hardened victim, and the child.
- A2: `gcore` against the ordinary and hardened victims (full core, canary grep, then deleted), and `gcore -x stack` against the child (the privilege check only; core deleted).
- A3: `stringdups` and `vmmap` against the three targets.
- A4: `p6-gpuclient` as root with the victims running.
- A6: `powermetrics --samplers gpu_power --show-process-gpu -n 1`, with a canary grep.

The victims run as the operator's user (`sudo -u "#$SUDO_UID"`), so root attacks another user's process, as with the child.

How to grade the root file with the section 4 criteria:

- A1: `ARM A1 pid=<child>` must show `task_for_pid kr=5` and `RESULT no-port`. The ordinary victim must show `S=1024`, or the arm is VOID.
- A2: the child line must show `insufficient privilege` and `size=none`. If it shows `rc=0` and a size, P6-2 is OPEN: root can dump the child's shared Metal buffers (and all other writable memory) with `gcore`. The ordinary victim line must show `S=1024`, or the arm is VOID.
- A3: the child lines must keep the restriction line and 0 hits.
- A4: `S=1 P=1` and `C=257`.
- A6: `canary_in_powermetrics=0`.

## 6. Verdict per path

| # | Path | Reaches | Verdict |
|---|---|---|---|
| P6-1 | task port + `mach_vm_read` | Shared buffers if a port is granted. Private buffers never (A1 control: `P=0` in 7.58 GB). | CLOSED for the child: root `task_for_pid kr=5`, `task_read_for_pid kr=-1` with a fired control (root kit, `tp-child.txt` / `tp-ctl.txt`). User arm A1 agrees. Root arm A1 in `p6-root.sh` repeats it with the GPU canary. |
| P6-2 | Apple entitled tools as root (`gcore` with `cs.debugger.read.root`; `system-task-ports.read` tools) | Shared buffers, if the kernel honors the entitlement for a hardened process without `get-task-allow` | NOT SETTLED. User: refused (A2 `insufficient privilege`, A3 restriction line), controls fired. Root: needs `p6-root.sh` A2 and A3. This is the one path that can still be OPEN. The root kit shows that `lsmp` (`system-task-ports.read`) already gets the child's port space as root. |
| P6-3 | IOKit GPU user clients | Nothing through the public client (A4) | CLOSED for the public client path as the user. Root form pending (`p6-root.sh` A4). Private selectors that could name another client's resources: NOT TESTED. A blind selector sweep on the GPU driver can panic the kernel, so I did not run one on the operator's Mac. |
| P6-4 | `/dev/kmem`, `kern.*` sysctl, kernel debugger | Nothing | CLOSED at Full Security (node absent, no sysctl, empty boot-args, SIP on). A kernel defect breaks this, as the claim already states. |
| P6-5 | GPU capture and debug layers | Nothing without the child's cooperation | CLOSED: environment refused by R2, no `Info.plist`, preference file refused by the read rules (A5), no capture call in the child, debugger attach is P6-1, no write rule for a capture file. |
| P6-6 | `powermetrics`, IOReport, `vmmap`, `footprint`, traces | Metadata: sizes, utilization, per-process GPU time | VOID as a content path (metadata only, A3 sizes). Root canary grep pending (`p6-root.sh` A6). The sizes can leak the KV size, which follows the prompt length. That is a length side channel, like the reply-length limit in the claim. |
| P6-7 | Freed GPU pages (residue) | — | Owned by K-2 (`review/K2-FREED-KV-2026-10-23.md`). |
| P6-8 | Swap, compressor, hibernation | — | Covered by P5a and P5d (not GPU-specific). |
| P6-9 | Peripheral DMA | — | Out of scope (not root software). |

## 7. Overall verdict

**NOT SETTLED, with no path OPEN so far.** Root cannot read the child's private GPU memory (the KV chunks) through any tested path. Root cannot get a task port to the child with a plain root binary, and the control fired. The user-level and non-root arms all PASS with fired controls. One path decides the verdict: Apple's entitled tools as root (P6-2), above all `gcore`, which holds `com.apple.security.cs.debugger.read.root`. If root `gcore` dumps the child, P6 is OPEN for the 1.5 GiB of shared Metal buffers (and for all other writable child memory, which also breaks claim parts 1 and 2 outside the GPU). If it is refused, P6 is CLOSED for the tested paths, with the private-selector residue of P6-3 as a stated limit. The operator command is in section 5.2.

Production hygiene: `strings -a splash/build/splash | grep -c SEALED_TEST` = 0, and `strings -a child/splash | grep -c SEALED_TEST` = 0. This task made no test build of the child: the user arms refuse at the port, so a GPU canary inside the child would not change any grade. The root arms grade on the port grant too (section 5.2). No file under `splash/` or `child/` changed.

## 8. Suite after the work

`neg/run-all.sh` passes 95/95 (`# result: 0 failed`), run <date> <time> to <time> local. Copy: `neg/P6/final-2026-10-23-p6-run2.txt`. The record of the earlier run by another process (95/95, <time>) is kept as `neg/final-2026-10-23-before-p6.txt`.

My first run (<time> to <time>) gave 94/95. `R6-plant-snmp` refused with the correct `exit=113`, but its reason line was empty. During that run, the S-1 test (`neg/run-s1.sh`) ran its own sealed test children, which share `/tmp/sealed-reason.log`. After the run, the file did not exist. That run is kept as `neg/P6/final-2026-10-23-p6-run1-concurrent-s1.txt`. I waited for a two-minute window with no sealed test process, then ran the suite again. That is the 95/95 run above. This task changed no file under `splash/` or `child/`.


## Root result (2026-10-24, operator run)

Files: `neg/P6/root-20261023-<time>.txt`, `neg/P6/gcore-retry-20261024-<time>.txt`.

| Arm | Sealed child 75418 (CD hash <h21>, pin matches) | Control | Verdict |
|---|---|---|---|
| A1 root task port + mach_vm_read | `task_for_pid kr=5`, `task_read_for_pid kr=-1`, 0 bytes | Ordinary decoy: port granted, 7,429,144,576 bytes read, canary 1024 times | CLOSED |
| A2 root `gcore` (`cs.debugger.read.root`) | `rc=77 insufficient privilege`, no core (3 runs) | Ordinary decoy: `rc=0`, core 7,414,104,064 bytes, canary 1024 times | CLOSED |
| A3 root `stringdups` / `vmmap` | "not debuggable ... only readonly memory"; vmmap shows sizes only (graphics_virtual=1.5G) | Same message on the decoys | CLOSED for contents; sizes visible |
| A4 root GPU client | Root's own client sees only its own pattern | Pattern baseline S=1 P=1 | CLOSED |
| A5 `powermetrics` | Canary 0 times; GPU frequency, residency, power only | n/a | Metadata only |

Notes on the A2 control. The first two control attempts failed with `open: Permission denied`: `gcore` opens the core file as the target's uid, so root-owned output folders (`/tmp/p6root.*`, `/cores`) refused the write. The third attempt wrote into a folder owned by the decoy's uid and succeeded. The child's refusal (`insufficient privilege`) is identical in all three runs and comes from the kernel before any file is opened.

Child stayed alive through every arm.

## Final verdict

**P6: CLOSED** for every root path tested: task ports, Apple's root-entitled `gcore`, the `system-task-ports.read` tools, the root GPU client, kernel memory paths (absent at Full Security), and GPU capture or debug switches. Each content-reaching arm has a control that read an ordinary process.

Stated limits:
- Private GPU driver calls (`AGXDeviceUserClient` selectors beyond the normal Metal set) are not tested: a blind selector sweep can panic the kernel.
- `vmmap` shows the child's graphics region sizes (1.5 GiB here). Sizes can follow the prompt length; this is metadata, not contents.
- A kernel or GPU-driver defect would break this, as it would break every other part of the claim.


## Corrections (2026-10-24, audit round 2)

- **A3 (`stringdups`, `vmmap`) is INFO, not CLOSED.** As root, `stringdups` refused the ordinary decoy too, so its control did not fire (audit R2-06). The P6 verdict does not change: `gcore` is the content-reaching root tool, and its control fired.
- **A4 (root GPU client) is INFO, not CLOSED.** It scans only its own address space (`mach_task_self()`), so it had no control on a different process (audit R2-07). The sentence "Each content-reaching arm has a control that read an ordinary process" is true for A1 and A2 only.
- **Build.** All root arms ran on child `<h21>`. The accepted child is `<h22>`, with the same release code (build-ID recompute and byte compare, audit R2-1). `gcore` has not run on `<h22>` or on the engine (audit R2-08, R2-5-12); a root-kit `gcore` arm is planned.
- **A2 control.** The successful control (`gcore-retry-20261024-<time>.txt`) is valid: same run, same uid 0, folder owned by the decoy uid; child error `rc=77` is different from the earlier control errors `rc=73 open` (audit R2-09). Small gap: the control used a full core and the child arm `-x stack`.
