# R2-5-03: root reads prompt and reply length from the channel (2026-10-24)

**Verdict: CONFIRMED.** Root on the provider's Mac can read the exact prompt token count and the reply token count (including the end token) while a sealed chat runs. This confirms the length limit stated in `review/CLAIM-v2-2026-10-24.md`. `fs_usage` shows byte counts and times, not payloads, so this test can not show content either way.

Run: `neg/LEN/len-20261024-<time>/` (`report.txt`, `fsusage.txt`). Grader: `neg/LEN/len-grade.py`. Script: `neg/LEN/len-root.sh` (criteria written in the script before the run).
Build: engine `<h21>…` (pid 33725), child `<h23>…` (pid 33839). Mac17,7, macOS 27.2-beta, SIP on.

## Method

Root ran `fs_usage -w -f network,filesys` on the engine and the child, which only observes. The user sent two sealed chats with the kit client. The grader compared the byte counts of the write syscalls with the wire format in `SplashWire.swift`:

- request frame, engine to child: 24 + 64 + 4 × (prompt tokens)
- tokens frame, child to engine: 24 + 16 + 4 × (tokens in the frame)

## Result

| Chat | Engine write (request frame) | Prompt tokens from the size | Tokenizer count | Child writes (tokens frames) |
|---|---|---|---|---|
| A "Name the capital of France in one word." | `0xac` = 172 bytes (fd 6) | (172 − 88) / 4 = **21** | 21 | one 48-byte frame = 2 tokens ("Paris" + end marker) |
| B "List the names of the twelve months…" | `0xe8` = 232 bytes (fd 6) | (232 − 88) / 4 = **36** | 36 | three 72-byte frames = 3 × 8 = 24 tokens (23 reply tokens + end marker) |

The control is the capture itself: 187 events, 59 for the engine, 128 for the child. The two chats give different sizes, and both sizes agree with the tokenizer.

On the network, the sealed request is the plaintext plus 16 bytes (137 → 153, 206 → 222), so the network shows the prompt byte length, not the token count. The sealed reply (1 padded frame each) did not show the reply size. The local channel showed both token counts.

## What this means

- The claim covers prompt and reply **content**. It does not cover their **length**. Root reads the token counts exactly, with a standard macOS tool, with SIP on.
- The reply tokens also arrive in frames over time, so root sees the decode rate and the reply's progress.
- A fix would need fixed-size frames on the local channel and fixed-time decode steps. Root could still measure GPU activity time. This is recorded as a limit, by the operator's decision on 2026-10-24.
