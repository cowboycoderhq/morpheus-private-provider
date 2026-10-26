# Chunked dynamic KV cache, IOSurfaceRootUserClient still denied (2026-10-23)

Task: `scratch/TASK-chunked-kv.md`. Replace the fixed dense KV pool with a KV cache that grows on demand and releases on request end. Use only ordinary private `MTLBuffer` objects, never MTL4 sparse mapping. Keep the `IOSurfaceRootUserClient` deny and keep the suite green.
Host: M5, `Mac17,7`, macOS 27.2 beta `27.2-beta`, uid 501. No `sudo`. Nothing pushed. `child/` was not restaged. `~/projects/morpheus-pnode` was not changed (one script was copied to `scratch/` and run there).
Input: `review/DENSE-KV-2026-10-23.md` (the dense-pool production child `<h28>…8e0d`, SHA-256 `<h59>…280b0d`, kept as `scratch/ckv-backup-2026-10-23/splash-dense-<h59>`).

## Result

| Check | Result | Record |
|---|---|---|
| Build, all variants (`neg/build-all.sh`) | 79 targets, rc=0 (71 child variants, one new: `build-ckv-notes`) | `logs/build-all-ckv-2026-10-23.txt` |
| Negative suite (`neg/run-all.sh`) | **95/95 PASS, 0 failed** (the 90 old cases and 5 new cases), <time> to <time> | `neg/final-2026-10-23-ckv.txt`, console `logs/run-all-ckv-2026-10-23.out` |
| No surface (`neg/run-dkv.sh`) | 7/7 PASS, `# result: 0 failed`. The reader found no surface and no canary in both phases. `mtl4Queue=0 sharedEvent=0`. | `neg/dkv-2026-10-23-ckv.txt` |
| Chunked-KV legs (`neg/run-ckv.sh`, new) | 5/5 PASS, `# result: 0 failed` (grow, release, cap, prefix, long) | `neg/ckv-2026-10-23-final.txt` |
| Production hygiene | `strings`: `SEALED_TEST` 0, `test: ` 0, `newMTL4CommandQueue` 0, `newSharedEvent` 0, `updateBufferMappings` 0, `IOSurfaceRootUserClient` 0. `nm -u`: no IOSurface import. Suite case `CKV-production-hygiene`, with a control. | `neg/final-2026-10-23-ckv.txt` |
| Idle footprint after load | 17.47 to 17.52 GiB (dense pool: 19.49 GiB). **2.0 GiB less.** | `neg/ckv-2026-10-23-final.txt` |
| Release after a 31,940-token request | Peak 19.163 GiB, 4 s later 18.094 GiB: **1.070 GiB returned**. KV resident after: 289,669,120 bytes (17 chunks). Dense control: 0.141 GiB. | `neg/ckv-2026-10-23-final.txt` |
| Per-request limit | `min(MAX_CONTEXT, 262,144, budget tokens - 7)`. With the default 16 GiB budget: 262,144 (the model limit). A 119,957-token prompt answered with `MAX_CONTEXT` 131072. The dense pool stopped at 65,529. | `neg/ckv-2026-10-23-final.txt` |
| Speed delta | **No measurable change.** Over four dense/chunked pairs the decode change was +6 %, -14 %, +4 % and +51 %. The 63,949-token prefill time changed by -3 %, -1 % and -11 % (negative is faster). The dense child alone varied from 24 to 49 tok/s (thermal pressure "fair", one other GPU job). The answer digests were the same on both children. Details in *Speed*. | `neg/CKV/run/bench-*.txt` |
| New child CD hash (staged form) | **`<h22>`** | see *New child* |

## Design

### 1. Chunk model and the two-level index

- A chunk is 16 Page32 pages: 512 tokens, 17,039,360 bytes (16.25 MiB). One token takes 33,280 bytes. `SPLASH_KV_CHUNK_PAGES` (`splash/runtime/metal/abi/ExecutionGeometry.h:37`) sets it for the host and the shaders.
- Each chunk is one private `MTLBuffer` (`newBufferWithLength:options:MTLResourceStorageModePrivate`). It holds, for each of the 16 attention layers, four regions in this order: keys, key scales, values, value scales. A region holds the 16 pages of the chunk in the flat page layout of the dense pool. That layout is in `q8_paging.h`: keys token-major, values dimension-major, one fp32 scale per head and token.
- The page id stays one integer. Physical page `p` is page `p % 16` of chunk `p / 16`. The page tables, the prefix cache, `KvPool` and the kernel parameter structs are unchanged.
- A shared `MTLBuffer` (`q8-kv-chunk-table`) holds the base GPU address of each (layer, tensor, chunk) region. It has 8 bytes per entry, 516,096 bytes for 1,008 chunks. The host writes `MTLBuffer.gpuAddress + offset` when a chunk is allocated and 0 when it is released (`Q8PageStorage::writeChunkAddresses`, `splash/runtime/ops/Q8PageStorage.mm:208-230`).
- The four `Q8LayerStorage` bindings of a layer are views of that table (`Q8PageStorage.mm:71-98`). The dispatch code in `PagedAttention.cpp` binds them at the same buffer indices as before, so it is unchanged.

### 2. Kernels

- `q8_paging.h:43-89`: under `SPLASH_KV_CHUNKED` a Q8 tensor parameter is `device const SplashQ8DataChunk *` or `device const SplashQ8ScaleChunk *`. Each struct holds one `device` pointer (the Metal 3 GPU-address form). `splash_q8_data_page` and `splash_q8_scale_page` return the address of page `p`: the chunk base from the table, plus the flat offset of page `p % 16`. Without the define, the same helpers add the flat offset to the flat buffer, so the non-sealed build keeps its code path.
- The store kernels (`q8_store_row.h:85-96`) and the attention page loop (`q8_attention_tile.h:213-260`) address every page through the helpers. The per-page element and scale indices are the old ones with page 0.
- The four kernel files take the parameter types from macros (`SPLASH_Q8_DATA`, `SPLASH_Q8_STORE_DATA`, `SPLASH_Q8_SCALES`, `SPLASH_Q8_CONST_SCALES`). Buffer indices did not change.
- `splash/Makefile:45-50` adds `-DSPLASH_KV_CHUNKED` to the Metal flags when `SEALED_DEFS` is set. The host side keys on `SPLASH_SEALED`. Both come from the same `SEALED_DEFS`, so a sealed host never runs with flat kernels.
- Check of the index: three 512-token generations after a 46-token prompt cross token 512. Each gave the same output digest on the dense child and the chunked child in every run. That is 18 of 18 results: 3 prompts, 3 rounds, 2 children (`neg/CKV/run/bench-ab.txt`, `neg/CKV/run/bench-final.txt`). The grow leg gave equal digests for prompts inside one chunk, across one boundary and for a 700-token generation.

### 3. Residency and lifetime (`splash/runtime/metal/MetalBackend.mm`)

- `addIndirectResource` / `removeIndirectResource` (`:1058-1087`) keep the list of chunk buffers. Each command declares every listed buffer with `useResource:usage:` (read and write) on its serial compute encoder (`:1639-1644`). This makes the buffers resident and hazard-tracked. The serial encoder orders the kernels.
- Each command ticket retains the listed buffers until it completes (`:1605-1609`), the same rule as for directly bound buffers.
- Removal throws if a command is submitted (`:1072-1078`). A chunk is released only at a command-free point: `Q8PageStorage::releaseBackingForPage` returns false while `commandIdle()` is false (`Q8PageStorage.mm:315-336`), and `releaseReady()` reports the same state to `KvPool`.
- New: `MetalBuffer::gpuAddress()` (`:637-640`), `MetalBackend::commandIdle()` (`:1089-1091`).

### 4. Grow

- `KvPool::acquirePages` takes free pages from the most used resident chunk first. When none is left it calls `ensureResident`, which allocates one chunk buffer under the memory governor's admission (`Q8PageStorage.mm:258-296`).
- Runway: the control pass (below) calls `KvPool::ensureRunway` (`splash/runtime/engine/KvPool.cpp:175-184`). If no empty resident chunk exists, it allocates one. So a request that crosses a boundary normally takes pages that are already resident, and the next chunk is made between commands.
- Warmup backs pages 0 to 63 through the storage directly. `KvPool::adoptBackedExtents` (`KvPool.cpp:186-193`) records those chunks in the pool. `Cache::releaseUnusedKvBacking` calls it, so startup releases them and keeps one runway chunk. Without it, three warmup chunks (51 MB) stayed allocated and outside the pool's accounting. This was found in the first full run (see *Run history*).

### 5. Release

- At every control pass (the 500 ms timer and other control events, only with no command in flight, `splash/runtime/main.mm:405-414`), `Engine::releaseIdleKv` runs `Cache::releaseIdleKv` (`splash/runtime/engine/Cache.cpp:313-367`):
  1. Each idle leaf block (no live request uses it) that is deeper than 8,192 tokens, or that has no composite state, is evicted. A hybrid model resumes only at a composite state, so such a tail can never be restored from. The scan restarts after each eviction, so the parent of an evicted leaf is checked too.
  2. With no live request, idle KV blocks plus composite states above 1/16 of the pool bytes are evicted in LRU order. With the default budget, the bound is 1,073,479,680 bytes.
  3. Empty chunks are released (`KvPool::reclaimEmptyExtents(keepRunway=true)`). One empty chunk stays as the runway.
  4. A missing runway chunk is allocated.
- With no request left, the state pool is trimmed to one lane of warm buffers (`releaseIdle(2, 1)`, as after startup, `main.mm:410-413`). Evicted composite states park their buffers there.
- A release frees the `MTLBuffer`. The child's `ri_phys_footprint` drops in the next sample (measured below).

### 6. Budget

- One KV budget covers all live sessions and the prefix cache. Default `kSealedDefaultKvBudgetBytes` = 16 GiB (`splash/runtime/engine/MemoryPlan.hpp:20-22`).
- Transport: the child's environment is fixed to `HOME` and `TMPDIR` by the spawn module and by R2, and `MAX_MEMORY` must be `auto`. So the environment variable is read by the launcher. `SEALED_KV_BUDGET_BYTES` (decimal bytes) on `launcher/sealed-launch` sets the budget. The launcher then sends config frame version 2, with a big-endian `u64` budget after the manifest (`launcher/sealed-launch.c:110-130`, `:166-180`). Without the variable it sends version 1. `SealedEngineV2` sends version 1 (`sealed_bringup.c:77`, read only), so the engine child gets the default.
- The child accepts version 1 or 2. A version 2 budget outside [256 MiB, 1 TiB] refuses with R2 code 8 `kv budget out of range` (`splash/runtime/sealed/sealed_r2.cpp:288-313`, `sealed_r2.h:51-56`). Any other version refuses with `bad magic or version`.
- Plan (`MemoryPlan.cpp:339-353`): the logical pool is the budget, rounded down to whole chunks. The elastic part of the hard working-set ceiling also limits it. Default: 16,128 pages = 1,008 chunks = 516,096 tokens. 512 MiB: 31 chunks = 15,872 tokens. The memory governor still admits each chunk allocation against the host reserve and the hard budget.
- At the cap: a prompt that cannot fit in the whole budget is refused at the next engine tick with `capacity_exhausted`, retryable (`splash/runtime/engine/Engine.cpp:106-130`, `:192-201`). The server maps this to HTTP 503. The message names the need and the budget, for example: `KV budget exceeded: the request needs 19941 KV tokens (39 chunks of 512 tokens), but the KV budget is 31 chunks (15872 tokens) for all live sessions and the prefix cache`. A request that grows past the budget during the run gets the same message (`finishCapacity`, `Engine.cpp:1216`). A request that fits the budget but finds it held by other live sessions waits or is suspended and resumed by the existing engine rules. The child does not crash in any of these cases.

### 7. Prefix cache

- Key: the existing `KvCache` key. A block is 32 tokens. Its key is the parent block id, the exact 32 token ids and the image identity. The cache namespace (the SHA-256 of the model and build) is the root. A lookup walks the chained block hashes from the root, so a block matches only if the whole prompt prefix before it matches. Equality is checked on the full key, the hash only filters.
- Resume points: a hybrid model needs a composite state (GDN state and draft context, 196,083,712 bytes each) to resume. The engine publishes progress checkpoints every 4,096 prompt tokens. Upstream replaced each checkpoint with the next one. In the sealed build a checkpoint at or below 8,192 tokens (`kSealedPrefixWindowTokens`, `Engine.hpp:19-21`) is not retired by that replacement (`Engine.cpp:785-793`). So a repeated system prompt of 4,096 tokens or more resumes at 4,096 or 8,192.
- Eviction rule: (1) idle tails past 8,192 tokens or without a state go first (release rule 1). (2) With no live request, idle KV plus states are bounded to 1/16 of the pool bytes, in LRU order. (3) When a live request needs pages, cached blocks are evicted LRU-first before the request is refused (existing `makeLogicalPages` and `reclaimForGrowth`). The prefix cache is inside the budget because its pages are pool pages.

### 8. Limits

- Per-request limit: `min(MAX_CONTEXT, model 262,144, budget tokens - 7 speculative scratch tokens)`. The memory plan reports the budget part as `maximum_context_tokens` and `kv_budget_bytes`. With the default budget the limit is the `MAX_CONTEXT` argument, up to 262,144 (R2 allows 1,024 to 262,144).
- Bootstrap no longer refuses `MAX_CONTEXT` above the budget part (`splash/runtime/engine/Bootstrap.mm:323-333`). `MAX_CONTEXT` stays the logical limit. A longer request gets the 503 above.
- The kernels still bound one request to 262,151 physical tokens (`SPLASH_MAXIMUM_PHYSICAL_KV_TOKENS`). The pool can be larger than one request.

### 9. Security, unchanged

- R5 profile: no `IOSurfaceRootUserClient` rule. The `iosurface-open` self-test arm and the `R5-mutant-ALLOW_IOSURFACE` mutant are unchanged and pass.
- Legacy `MTLCommandQueue` only. No MTL4 queue, no `MTLSharedEvent`, no `updateBufferMappings`, no placement-sparse buffer or heap in the sealed KV path. No IOSurface import.
- New GPU objects: private `MTLBuffer` chunks and one shared `MTLBuffer` table, from `newBufferWithLength:options:`. `useResource:usage:` and `gpuAddress` do not open a new user client. The kernel log shows the same two refused `IOSurfaceRootUserClient` opens per child as before. They are the self-test probe and the open inside `MTLCreateSystemDefaultDevice`.
- The one new input is the budget in frame version 2. R2 checks its range before the sandbox, and it is only a size.

## Change list

Source backups before the edit: `scratch/ckv-backup-2026-10-23/` (`runtime.tar`, `Makefile`, `sealed-launch.c`, `build-all.sh`, `run-all.sh`, `r2neg.c`, `README.md`, the dense binary).

| File | Change |
|---|---|
| `splash/runtime/metal/abi/ExecutionGeometry.h` | `SPLASH_KV_CHUNK_PAGES 16u` |
| `splash/runtime/metal/kernels/common/q8_paging.h` | Chunk table types, parameter macros, `splash_q8_data_page`, `splash_q8_scale_page` (flat versions for other builds) |
| `splash/runtime/metal/kernels/common/q8_store_row.h`, `q8_attention_tile.h`, `prefill/attention_q8.metal`, `prefill/attention_q8_store.metal`, `decode/attention_q8.metal`, `decode/attention_q8_store.metal` | Page addressing through the helpers, parameter types from the macros |
| `splash/Makefile` | `-DSPLASH_KV_CHUNKED` in the Metal flags of sealed builds |
| `splash/runtime/metal/MetalBackend.hpp`, `.mm` | `gpuAddress`, indirect resources with `useResource`, `commandIdle` |
| `splash/runtime/ops/PagedKv.hpp` | `kChunkPages`. In sealed builds the extent and mapping unit is one chunk. |
| `splash/runtime/ops/Q8PageStorage.hpp`, `.mm` | Chunk buffers, the address table, allocate, release, residency. Test-only chunk timing notes (`SEALED_TEST_CKV_NOTES`). The dense "all extents resident" code is gone. |
| `splash/runtime/engine/MemoryPlan.hpp`, `.cpp` | KV budget in the plan and in the status JSON. The dense 65,536-token cap is gone. |
| `splash/runtime/engine/RuntimeResources.hpp`, `.mm`, `splash/runtime/main.mm` | Budget from the frame into the plan. Control pass calls the release and trims the state pool. |
| `splash/runtime/engine/KvPool.hpp`, `.cpp` | `ensureRunway`, `adoptBackedExtents` |
| `splash/runtime/engine/Cache.hpp`, `.cpp` | `releaseIdleKv`, `pageCapacity`, `hasRequest`. Test-only idle notes. |
| `splash/runtime/engine/Engine.hpp`, `.cpp` | Budget refusal at the next tick, budget message, `releaseIdleKv`, prefix checkpoints kept |
| `splash/runtime/engine/NativeRuntime.hpp` | `releaseIdleKv` |
| `splash/runtime/engine/Bootstrap.mm` | No refusal of `MAX_CONTEXT` above the budget part in sealed builds |
| `splash/runtime/sealed/sealed_r2.h`, `.cpp` | Frame version 2, budget range check, `sealed_r2_kv_budget_bytes` |
| `launcher/sealed-launch.c` | `SEALED_KV_BUDGET_BYTES`, frame version 2 |
| `neg/B/r2neg.c` | Cases `frame-kv-budget`, `frame-kv-budget-low`, `frame-version` |
| `neg/build-all.sh` | Variant `build-ckv-notes` |
| `neg/run-all.sh` | 5 cases: `frame-kv-budget`, `frame-kv-budget-low`, `frame-version`, `CKV-production-hygiene`, `CKV-hygiene-control-notes-build` |
| New: `neg/run-ckv.sh`, `neg/CKV/with-server.sh`, `neg/CKV/leg.sh`, `neg/CKV/req.py`, `neg/CKV/bench-body.sh`, `neg/CKV/bench-ab.sh`, `neg/CKV/stream.py` | Test and measurement drivers |
| `README.md` | Section *Chunked KV in production 2026-10-23*, supersession note on the dense-KV section |

Not changed: the non-sealed build paths (they compile the flat kernels and the placement-sparse code), `PagedAttention.cpp`, the protocol, the Python server, the spawn module.

> Correction 2026-10-25 (audit R4-U1): three changes also run in non-sealed builds: `adoptBackedExtents` (`Cache.cpp`), the `kv_budget_bytes` and `KV budget:` output (`MemoryPlan.cpp`), and the `indirectResources` encoder loop. The full diff against upstream 1.0.2 is in `review/SPLASH-DIFF-1.0.2-2026-10-25.diff`.

## Tests

All legs ran on the final binaries (production SHA-256 `<h58>…cb2ce`, notes build `<h60>…96dc`), `neg/run-ckv.sh` <time> to <time>. Temperature 0, `reasoning_effort` none. Footprint is `proc_pid_rusage` `ri_phys_footprint` of the child, sampled every 0.25 s, and once 4 s after the response ("settled").

### Grow (control: the dense child, same prompts)

| Request | Chunked | Dense | Chunk notes (notes build) |
|---|---|---|---|
| Kestrel prompt, 244 tokens (inside chunk 0) | `7319-KESTREL, Paris`, digest `<h61>…` | same digest | 1 allocation (the runway) |
| Kestrel prompt, 623 tokens (across token 512) | `7319-KESTREL, Paris`, digest `<h61>…` | same digest | The pages past the boundary came from the resident runway chunk. Then 1 runway allocation, 62.8 µs. |
| 700 generated tokens after a 44-token prompt (across token 512 while decoding) | digest `<h62>…` | same digest | 1 allocation, 1 release |

Verdict: `PASS [grow] 3 of 3 answers correct and equal to the dense child (digests)`.

### Release (control: the dense child)

| | Before | Peak | Settled | Returned |
|---|---|---|---|---|
| Chunked, 31,940-token prompt | 17.473 GiB | 19.163 GiB | 18.094 GiB | **1.070 GiB** |
| Dense, same prompt | 19.488 GiB | 19.812 GiB | 19.671 GiB | 0.141 GiB |

- Chunk notes: 63 allocations and 47 releases during this request and its settle time. KV resident went from 1,090,519,040 bytes (64 chunks) to 289,669,120 bytes (17 chunks): 16 chunks of the 8,192-token prefix window and one runway chunk. Two composite states stayed (392,167,424 bytes).
- The rest of the footprint above the idle value is the retained prefix (272.6 MB of KV and two states) and the warm state buffers.
- The dense control returns only state buffers. Its 2.03 GiB pool stays.

### Cap (control: a request inside the same budget)

`SEALED_KV_BUDGET_BYTES=536870912` (launcher log: `kv budget: 536870912`), `MAX_CONTEXT` 32768.

| Request | Result |
|---|---|
| 11,934-token prompt (control) | HTTP 200, `7319-KESTREL, Paris`, TTFT 35.4 s |
| 19,941-token prompt (needs 39 chunks, budget 31) | **HTTP 503** in 0.62 s, `code: capacity_exhausted`, message `KV budget exceeded: the request needs 19941 KV tokens (39 chunks of 512 tokens), but the KV budget is 31 chunks (15872 tokens) for all live sessions and the prefix cache` |
| 45-token prompt after the 503 | HTTP 200, 64 tokens, 53.1 tok/s (the child did not crash) |

Frame controls in the suite: `frame-kv-budget` (version 2, 512 MiB) loads. `frame-kv-budget-low` (1,000 bytes) refuses with `kv budget out of range`. `frame-version` (version 3) refuses with `bad magic or version`.

### Prefix reuse (controls: another system prompt, and the dense child)

One 5,9xx-token system prompt with the vault code, then a user turn. Each answer was `7319-KESTREL`.

| Request | Chunked: cached / TTFT | Dense: cached / TTFT |
|---|---|---|
| 1: system prompt A, user 1 | 0 / 15.5 s | 0 / 16.0 s |
| 2: system prompt A, user 2 | **4,096 / 3.2 s** | 0 / 14.0 s |
| 3: system prompt B, user 3 (control) | 0 / 14.1 s | 0 / 14.2 s |

The second request is 4.8 times faster on the chunked child. The dense child retired the 4,096-token checkpoint when it published the end state, so it had no resume point on the shared prefix. In the long leg the 31,940-token Kestrel prompt also resumed at 8,192 tokens. The 15,932-token prompt before it has the same start.

### Long context

`neg/DKV/long-arm.sh` with `splash/build` (the same driver and prompts as the dense report):

| `MAX_CONTEXT` | Prompt tokens | Cached | Time | Answer | Footprint before / peak / after |
|---|---|---|---|---|---|
| 32768 | 15,932 | 0 | 45.4 s | `7319-KESTREL, Paris` | 17.47 / 18.67 / 18.23 GiB |
| 32768 | 31,940 | 8,192 | 75.4 s | `7319-KESTREL, Paris` | 18.09 / 18.94 / 18.98 GiB |
| 65529 | 63,935 | 0 | 224.1 s | `7319-KESTREL, Paris` | 17.47 / 20.12 / 18.24 GiB |
| 131072 | 119,957 | 0 | 493.3 s | `7319-KESTREL, Paris` | 17.47 / 21.86 / 18.67 GiB |

The last row is above the dense pool's limit of 65,529 tokens. "After" is one sample right after the response. The release can finish later.

### No surface

`neg/run-dkv.sh` (<time> to <time>) gave `PASS` for each leg:

- load, and selftest `0xe00002e2`
- kernel: two `deny(1) iokit-open-user-client IOSurfaceRootUserClient` per child
- chat: `pin=<h22> answer=Paris left=0`
- reader-make: global and non-global make returned NULL in both phases
- reader: `ARM sweep ids=1..4096 opened=0 with_canary=0` in both phases, `mtl4Queue=0 sharedEvent=0`
- long-32k

 Note: its `MEAS [long-pool]` line is the old dense record file (`neg/DKV/run/long-pool.txt`), because `LONG_POOL_CTX` was not set. The 63,935-token row above is the chunked run.

### Full suite

`neg/run-all.sh`: 95/95 PASS. Section 6 (launcher cases) ran on the staged `child/splash` (the dense child), because `child/` was not restaged. The record before this work is `neg/final-2026-10-23-before-ckv.txt`.

## Memory

| Item | Dense pool (before) | Chunked (after) |
|---|---|---|
| KV backing at idle | 2,181,038,080 bytes, fixed | 17,039,360 bytes (one runway chunk), plus the retained prefix |
| Idle footprint after load | 19.49 GiB | 17.47 to 17.52 GiB |
| Lifetime maximum (load and warmup) | 20.61 GiB | 18.64 to 18.67 GiB |
| Peak, 31,940-token prompt | 19.81 GiB | 19.16 GiB |
| Peak, 63,935-token prompt | 19.79 GiB | 20.12 GiB |
| Returned after a 31,940-token prompt | 0.14 GiB | 1.07 GiB |
| Largest prompt | 65,529 tokens | 262,144 tokens (budget 16 GiB); 119,957 measured |

Chunk-boundary latency (notes build, 31,940-token request, 63 allocations, 47 releases):

- Allocate one chunk (buffer, table entries, resource list): median 9.5 µs, p90 51.6 µs, maximum 71.9 µs.
- Release one chunk: median 2.0 µs, p90 2.9 µs, maximum 1,124.5 µs (one release).
- During decode the crossing step takes runway pages that are already resident. The runway refill runs at a command-free control pass. A streamed 1,200-token generation after a 46-token prompt crosses tokens 512 and 1,024 (`neg/CKV/stream.py`, two runs per child). It took 35.65 and 35.55 s on the chunked child, and 34.66 and 33.80 s on the dense child. The largest gap between two streamed tokens was 96.0 and 99.5 ms (chunked) and 97.1 and 88.2 ms (dense). The tokens that crossed 512 and 1,024 came 0.4 to 0.8 ms after the token before them on both children. The server sends one event per token, and a speculative step emits up to eight. So this measure does not isolate the step that took the new chunk. The added work in that step is at most the allocation time above (72 µs). A decode step takes about 77 ms (the p90 gap between events).

## Speed

Same prompts on both children (fixed nonces, no prefix hit), `MAX_CONTEXT` 65529, one server per run. Decode: three 46-token prompts, 512 tokens each (the KV crosses token 512). Prefill: four filler prompts, 2 output tokens, TTFT from the server log.

| Run (time, GPU state) | Decode tok/s (3 prompts) | TTFT 7,957 | TTFT 15,947 | TTFT 31,954 | TTFT 63,949 |
|---|---|---|---|---|---|
| dense, <time> local (GPU otherwise idle, other nonces) | 48.2, 48.8, 41.0 | 13.4 s | 29.9 s | 98.4 s | 205.3 s |
| chunked (first build), <time> local (GPU otherwise idle, other nonces) | 50.9, 47.5, 47.4 | 10.7 s | 27.6 s | 98.1 s | not valid (builds ran) |
| dense A/B 1, <time> | 29.2, 29.4, 30.1 | 18.2 s | 41.0 s | 104.6 s | 236.4 s |
| chunked A/B 1, <time> | 23.8, 25.6, 26.6 | 20.7 s | 46.1 s | 94.0 s | 228.5 s |
| dense A/B 2, <time> | 24.2, 25.8, 26.7 | 20.5 s | 45.5 s | 99.8 s | 224.7 s |
| chunked A/B 2, <time> | 24.6, 26.9, 28.2 | 19.7 s | 42.8 s | 95.4 s | 223.5 s |
| dense, final round, <time> local | 24.1, 26.0, 27.1 | 20.0 s | 44.6 s | 98.1 s | 172.7 s |
| chunked (final build), final round, <time> local | 37.0, 39.3, 40.0 | 12.7 s | 28.9 s | 65.0 s | 154.6 s |

- Change per pair, chunked against the dense run immediately before it. A negative TTFT change is faster.

| Pair | Decode tok/s (mean of 3) | TTFT 7,957 | TTFT 15,947 | TTFT 31,954 | TTFT 63,949 |
|---|---|---|---|---|---|
| 0 (<time> / <time>, other nonces) | 46.0 to 48.6, +5.6 % | -20.1 % | -7.7 % | -0.3 % | not valid |
| 1 (A/B 1) | 29.6 to 25.3, -14.3 % | +13.7 % | +12.4 % | -10.1 % | -3.3 % |
| 2 (A/B 2) | 25.6 to 26.6, +3.9 % | -3.9 % | -5.9 % | -4.4 % | -0.5 % |
| 3 (final build) | 25.7 to 38.8, +50.7 % | -36.5 % | -35.2 % | -33.7 % | -10.5 % |

- Verdict: no measurable change. The sign of the change is not stable across pairs, and the dense child alone ran between 24.1 and 48.8 tok/s in this session. The setup cannot resolve a difference smaller than about 15 %. Pair 3 is not a speed-up of the design: the code in the request path is the same as in pairs 1 and 2.
- The decode rate fell from 48 to 25 tok/s during the session for both children. `~/Library/Logs/thermal-brake.log` shows thermal pressure "fair" from <time> to <time> local, which covers all A/B rounds. It shows "fair" again from <time> local. Another agent's `mlx-serve` used the GPU from about <time> to <time> local. The difference between the two children is smaller than the difference between two dense runs.
- Outputs: each of the 7 prompts gave one answer digest on both children in all three rounds (21 results per child, `neg/CKV/run/bench-ab.txt`, `neg/CKV/run/bench-final.txt`).
- Pairs 0 to 2 used the first chunked build (`<h63>…`). The final build (pair 3) differs only in the startup pool accounting (`adoptBackedExtents`), which no request step runs.

## New child

The staged form is `codesign -f -s - --options runtime -i sealed.splash`, the same as `stage-child.sh`. Two copies in `scratch/ckv-pin-a/` and `scratch/ckv-pin-b/` give:

```
CDHash=<h22>   (adhoc,runtime, Identifier=sealed.splash)
```

- `splash/build/splash`: SHA-256 `<h58>`. Linker ad-hoc CD hash `<h64>` (unsigned form, not the pin).
- The chat legs of `neg/run-dkv.sh` pinned the same value.
- New model hash for consumers (`scripts/model-hash.py`, run from a copy, `scratch/ckv-model-hash.py`): `<h65>`. The same script gives `<h66>…3932` for the dense child, as in the dense report.

## Rebuild sequence (operator)

CAUTION: The running `SealedEngineV2` and its child use `child/splash`. Stop the engine before you restage `child/`.

1. Stop the engine: `pkill -f "SealedEngineV2.app/Contents/MacOS/SealedEngine"`.
2. Stage the child: `cd ~/projects/sealed-backends-spike/sealed-m5 && ./stage-child.sh`. The output must be `pin=<h22>`.
3. Run the launcher cases on the staged child: `neg/run-all.sh`. The result must be 95/95 PASS.
4. Write the pin: `cd ~/projects/morpheus-pnode/sealed-engine-v2 && scripts/pin-child.sh ~/projects/sealed-backends-spike/sealed-m5/child/splash ~/projects/sealed-backends-spike/sealed-m5/tools/decoy ~/projects/sealed-backends-spike/sealed-m5/tools/reqgen`.
5. Check the child build: `scripts/child-repro-check.sh ~/projects/sealed-backends-spike/sealed-m5/splash`. Both folders must give `<h22>…9287`.
6. Build the engine: `scripts/bundle.sh /tmp/sev2-profile/engine.provisionprofile`.
7. Start the engine: `scripts/start-engine.sh`.
8. Run the evidence suite: `scripts/evidence.sh /tmp/sev2-profile/engine.provisionprofile`. It includes the verified `sealed-chat` request ("Paris").
9. Commit `ChildPin.swift` (precedent: `<h67> pin: child <h68>`). Publish the new engine CD hash and the model hash `<h65>…d210`.
10. Update `sealed-accept/matrix.json` (`child_cdhash`, `child_pin`, the engine CD hash). Raise `NEG_EXPECTED` in `sealed-accept/accept.sh` from 90 to 95 and bump `tool_version`, because the suite grew. Then run `sealed-accept/accept.sh`.

> Superseded 2026-10-24: the engine sends config frame version 2 (commit `<h69>`). The paragraph below describes the state on 2026-10-23.

Optional, for a budget other than 16 GiB: the engine sends config frame version 1. A different budget needs the engine to send version 2 (the format in `sealed_r2.h`). That is a change in `~/projects/morpheus-pnode` and was not made.

## Run history

1. First full run (production SHA-256 `<h63>…3f28`, CD hash `<h70>…9984`): build-all rc=0, suite 95/95, `run-dkv.sh` 0 failed, `run-ckv.sh` 0 failed (`neg/final-2026-10-23-ckv-run1.txt`, `neg/dkv-2026-10-23-ckv-run1.txt`, `neg/ckv-2026-10-23-run1.txt`).
2. In that run the grow leg showed no allocation note for chunks that the pool allocated. The cause: warmup backed chunks 1 to 3 through the storage, outside the pool. Fix: `adoptBackedExtents`. After the fix, startup releases chunks 0 to 2 and keeps chunk 3 as the runway (notes: `ckv release chunk=2`, `1`, `0`).
3. Final run on the fixed build: the numbers in this report.

Exploratory runs before the final code: `neg/CKV/run/try-*`, `smoke1`, `bench-dense-1`, `bench-ckv-1`. They are not records.

## Residual risk

1. **One Mac, one OS build.** As in the dense report. `MTLCreateSystemDefaultDevice` still tries the client open, and the self-test arm detects a change in the refusal, not in Metal.
2. **`useResource` per chunk per command.** A command declares every resident chunk, up to 1,008 with the default budget. At 64 chunks the decode rate did not change measurably. A batched `useResources:count:usage:` call was not tried.
3. **Composite states are outside the KV budget when requests are live.** Each is 196,083,712 bytes. The idle bound counts them, and the state pool is trimmed when idle. During live requests they follow the existing state rules and the memory governor.
4. **Prefix reuse needs 4,096 shared tokens.** A shared system prompt shorter than 4,096 tokens gets no resume point on the second request. By the code, the second request then publishes a junction state that a third request can use (upstream behavior). That case was not tested.
5. **Concurrency at the cap was not tested.** Several live sessions that together pass the budget wait or are suspended by the existing engine rules. Only the single-request 503 was tested.
6. **Speed under thermal pressure.** All A/B runs had thermal pressure "fair". The two first runs (<time> and <time> local, GPU otherwise idle) agree with the A/B result, but they used other nonces.
7. **Status JSON not read.** The server's native status refresh timed out (50 ms) in every run, as in the dense report. KV numbers come from the test-only notes build and from the footprint.
8. **CPU tests not run** (no test sources in this tree).
