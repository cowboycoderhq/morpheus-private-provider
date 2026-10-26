# Gap: the child's prefix cache is shared by all consumers (2026-10-25)

Status: **open gap, documented, not fixed.** Found by audit R5-4-01
(`review/AUDIT-v2-R5-4-CODE.md`).

## What happens

The sealed child keeps one prefix cache for all requests. It stores the KV
blocks and resume states of the first `kSealedPrefixWindowTokens` (8,192)
tokens of a prompt between requests (`runtime/engine/Engine.hpp:20-21`,
`runtime/engine/Engine.cpp:785-793`, `runtime/engine/Cache.cpp`). A later
request with the same prefix resumes from the cache. The engine sends no
session field to the child (`Sources/SealedEngineV2/SplashBackend.swift:70-74`),
so the cache does not separate consumers.

## Why it matters

A cache hit makes the first token much faster. The stored measurement
(`review/CHUNKED-KV-2026-10-23.md`, "Prefix reuse"): a 5,9xx-token system
prompt took 15.5 s to the first token, and the same prefix in a second request
took 3.2 s (4,096 tokens cached). A control with another system prompt took
14.1 s.

So a consumer can send a guessed prefix and measure the time to the first
token. A fast answer shows that some consumer sent the same prefix (aligned to
the cache block size) a short time before. Root on the provider is not needed:
the time is visible to the consumer and on the network. The claim's timing
limit covered only root on the provider; this signal is wider.

## Not measured

- The test above used one consumer. No test has measured two sessions.
- How long a prefix stays in the cache under load (eviction and
  `Cache::releaseIdleKv` bound it).

## Possible fixes (none built or tested)

| Fix | What it stops | Cost |
|---|---|---|
| 1. Key the cache by a per-session secret that the engine sends to the child | Reuse across sessions | Wire change in the engine and the child; new pins. Multi-turn chats keep their speed |
| 2. Clear the cache after each request | All reuse | Each turn of a long chat recomputes its prefix |
| 3. Turn the prefix cache off in the sealed build | All reuse | Same as 2 |

Test for a fix: two sessions, session A sends a long system prompt, session B
sends the same prompt; the time to the first token for B must equal the time
for a prompt that no one sent before, with a same-session control that still
hits the cache (fix 1).
