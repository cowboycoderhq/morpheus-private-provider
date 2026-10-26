# Open items closure — 2026-10-22

> **SUPERSEDED 2026-10-24** by `OPEN-ITEMS-CLOSURE-2026-10-24.md`, which is written against the accepted build (child `<h22>`, engine `<h25>`). In particular the T2 row below ("OPEN, CONFIRMED CHANNEL") describes the profile before the IOSurface deny, and the P2/P3/P5c rows cite run 4 on engine `<h6>`. Kept unchanged below as the 2026-10-22 record.


Every item from the DeepSeek review, the TEE evidence list and the tracked list, with its disposition. "Closed" means evidence exists at the cited path. "Structural" means the limit comes from macOS or Apple policy and cannot be removed by this project. "Operator" means only the operator can act (Apple portal, policy, or a machine cycle).

## Closed with evidence

| Item | Disposition | Evidence |
|---|---|---|
| N1 latch under lock | closed | `neg/final-2026-10-20.txt` (53/53) |
| N2 manifest size cap | closed | same + `neg/` cases |
| N3 bytes after manifest refused | closed, claim narrowed | `frame-trailing` case; mutation shows R2 checks `FIONREAD` once after the frame read, so bytes written later in the same spawn can arrive after the check (1 FAIL in 1 of 3 full runs; 8/8 repeats refused). The claim is "bytes present at the check are refused" (see `review/TRACKED-ITEMS-CLOSURE-2026-10-22.md` finding) |
| N4 truncated profile refused | closed | run 3/4 suites, reason match |
| N5 absent data arms | closed | `no-probes` case, S7 arms |
| N6 case-collision entries refused | closed | `make-manifest.py` + manifest hash unchanged |
| N7 `SLSB`/`SLLD` order reports | closed | run 3/4, order-check mutation proof |
| N8 TMPDIR from checked env | closed | selftest arms in sandbox |
| S1c metal-cache posture | closed | `cache-mode`, `cache-symlink` cases |
| S3 second read refused | closed | `second read of a loaded path` case |
| S3 share-mode check | closed, mutation-proven | 13 new cases, `neg/final-2026-10-21.txt` (66/66); `neg/final-2026-10-22.txt` 77/77 with 11 mutation cases: each refusing case loads on its mutant and reaches its hazard |
| S3 descriptor check | closed, mutation-proven | same (5 cases) |
| S3 open-log compare | closed, mutation-proven | same (catches case-variant names) |
| S4 firmlink plants refused | closed | four planted mappings, run 2026-10-20 |
| S5 own-folder literal rules | closed | owndir probe + literal rules, 2026-10-20 |
| S6 `/usr/bin`, `/usr/libexec` removed | closed | child LOADs without them |
| S7 mach-lookup/dns posture | closed | kr=1100 arms, probes EPERM |
| R4-T4 Metal cache | closed | run 4: 578 events, 0 cache lines; PID-tree shutdown fix |
| A-21 mount-over | closed | run 4: mount refused, control rc 0 |
| P1 pinned code | closed | CD hash pin + refusal controls (consumer) |
| P2 root vs memory | closed | root kit: task ports, dtrace, mount, engine + child arms (run 4) |
| P3 output channels | closed | P10-lo0 canary 0/12,895 bytes; engine arms |
| P4 model integrity | closed | manifest hash + package hash in attestation |
| P5a swap | closed | A-3 on <host-b>: 3 files, 3.00 GiB, canary 0 |
| P5b crash reports | closed | crash report holds canary without R1; guarded child leaves none |
| P5c Metal cache | closed | run 3/4; no cache path with a write flag |
| P7 channel | closed | audit-token pin, recycled-pid canary test |
| P10 tokenizer/template in seal | closed | v2 engine does template + token IDs; canary test |
| T1 tag 3 | closed-informational | recorded in README; verifiers must know |
| T3 anonymous executable regions | closed-accepted | hardened runtime without JIT is the control; no JIT entitlement |
| T5 tokenizer outside seal | superseded | v2 engine puts it inside the attested process |
| S3 bypass-open-closed | closed-accepted | needs malicious child code to exploit; the child is pinned, and a rogue spawner cannot inject code |
| T6 sealed_spawn inspection | closed | `review/TRACKED-ITEMS-CLOSURE-2026-10-22.md`: all five checks obey the design, stored evidence for each; residual risks listed there |

## Open with a written settling test

| Item | State | Settling test (written before the run) |
|---|---|---|
| T2 IOSurface output channel | **OPEN, CONFIRMED CHANNEL** (run 2026-10-22, `review/T2-IOSURFACE-2026-10-22.md`, `neg/t2-2026-10-22.txt`). Under the production profile, after the "sandboxed" report and after the load, the test child made a global surface with a canary. A same-user unsandboxed reader got the canary by lookup (8192 hits), by ID sweep and by property read. The non-global surface was refused. The control without the sandbox fired. The release code still makes and passes no surface, so the channel needs code execution in the child. Filter follow-up: **NOT PRACTICAL** (run <date> <time>, `review/T2-FILTER-2026-10-22.md`, `neg/t2f-2026-10-22.txt`). Every `apply-message-filter` form on `IOSurfaceRootUserClient` gets `sandbox_init` `Operation not permitted`, so the child cannot start. An ad hoc probe with `com.apple.private.security.message-filter` is killed by AMFI (`-424`). The class deny refuses the global make and the reader finds no canary, but `newMTL4CommandQueue` and `newSharedEvent` return nil and no chat is served. Global and non-global makes both use selector 0, so a method-number filter cannot separate them | structural on macOS 27.2 beta `27.2-beta`: closing needs an Apple change (message filters for third-party profiles, a filter on `kIOSurfaceIsGlobal`, removal of global surfaces, or Metal objects that do not need `IOSurfaceRootUserClient`; see `review/T2-FILTER-2026-10-22.md`). Rerun `neg/run-t2.sh` and `neg/run-t2f.sh` on each new macOS. The Mach-port route and the `UNKNOWN` send rights are still not tested |
| R7-T3 framework exception ports, signal dispositions, sandbox | closed (PASS, `review/R7T3-2026-10-22.md`, `neg/r7t3-2026-10-22.txt`) | read-backs after load, around 67 requests, in the busy-poll and at the end (404,745 checks in run A); four seeded controls fired at request time (15–928 µs) and at load (24–172 µs); end self-test held; interposer reach 3/3 with Metal as the caller and zero port or fatal-signal calls after the guard. Two limits: the longest generation was 270 s (the 300 s leg is INFO), and the after-request crash with the guard shows `crashed=1, exception_seen=0, reports=0`, which is the guard absorbing the fault (its no-guard control shows the oracle seeing it) |
| decrypt-read SKIP | closed-limit | samples read zero; not part of P5a |
| 89 stale `$TMPDIR/sealed-child-*` folders | closed | removed 2026-10-22 (0 bytes each) |

## Structural limits (cannot be closed by this project)

| Item | Why | Consequence |
|---|---|---|
| A-2-dtrace-read | SIP blocks the `syscall` provider on every test Mac; the control fails the same way | stays INCONCLUSIVE while SIP is on |
| R4-T5 root control | launchd refuses a foreign pid-domain bootstrap for any name (rc=5); harness C1–C6 supplies the working control at user level | arm INCONCLUSIVE by design; property supported by the harness |
| A-4 Endpoint Security | no provisioning profile grants `com.apple.developer.endpoint-security.client`; AMFI kills an ad-hoc client | INCONCLUSIVE until a profile exists |
| No memory encryption | Apple Silicon has none for third-party code; Secure Enclave is Apple-only and too small | root with an unpatched kernel exploit can read plaintext; documented, not hidden |

## Operator actions outstanding

| Item | Action |
|---|---|
| A-5 forced standby (P5d) | closed (PASS, `build-glm/wave-2026-10-06/kits/a5-standby/RESULTS-2026-10-23.md`) | real hibernate: Sleep <time>, `Wake from Hibernate [CDNVA]` <time>, no reboot; 126.8 GiB image held the canary 0 times. Limit: the image is encrypted with a Secure Enclave key, so the result shows no plaintext on disk, not that a holder of that key cannot decrypt it |
| A-4 | create a provisioning profile with the Endpoint Security entitlement (Apple developer portal) |
| Dedicated App ID | sign in to Xcode as Account Holder; replace the borrowed `<bundle-id>` |
| Public source | push `feat/sealed-v2-splash-engine` (cloned engine repo) and the spike files; the PR reply promised public evidence |
| Vault sync | merge the 6 local commits with the server commit and push |

## Limits that remain by design

- The search and canary results prove absence in what was read. They do not prove which pages entered swap.
- The compare proves this copy, not a provider's disk at a later time.
- The engine is development-signed until the dedicated App ID exists.
