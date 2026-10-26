"""Chunk-boundary latency probe (review/CHUNKED-KV-2026-10-23.md).

One streamed chat request (temperature 0, reasoning_effort none). Records the
arrival time of every SSE content event, counts the generated tokens with the
tokenizer, and reports the gap before each event whose KV length (prompt +
generated) crosses a multiple of 512 tokens, against the median gap.
usage: stream.py PORT TOKENIZER MAX_TOKENS
"""
import json
import statistics
import sys
import time
import urllib.request

from transformers import AutoTokenizer

port, tok_dir, max_tokens = sys.argv[1], sys.argv[2], int(sys.argv[3])
tok = AutoTokenizer.from_pretrained(tok_dir)
msgs = [{"role": "user", "content": "Session boundary-probe. Write a long, detailed story about a "
         "lighthouse keeper who finds a map in a bottle. Use at least 1500 words."}]
body = json.dumps({"model": "audreyt/Qwen3.8-27B-Splash-abliterated", "max_tokens": max_tokens,
                   "temperature": 0, "reasoning_effort": "none", "stream": True,
                   "stream_options": {"include_usage": True}, "messages": msgs}).encode()
req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", data=body,
                             headers={"Content-Type": "application/json"})
events, text, prompt_tokens = [], "", None
t0 = time.time()
with urllib.request.urlopen(req, timeout=600) as r:
    for raw in r:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:") or line == "data: [DONE]":
            continue
        d = json.loads(line[5:])
        if d.get("usage"):
            prompt_tokens = d["usage"].get("prompt_tokens")
        for c in d.get("choices", []):
            piece = (c.get("delta") or {}).get("content") or ""
            if piece:
                text += piece
                events.append((time.time(), len(tok(text, add_special_tokens=False)["input_ids"])))
if prompt_tokens is None or len(events) < 3:
    sys.exit(f"FAIL stream: prompt_tokens={prompt_tokens} events={len(events)}")
gaps = [(events[i][0] - events[i - 1][0], events[i - 1][1], events[i][1]) for i in range(1, len(events))]
med = statistics.median(g for g, _, _ in gaps)
cross = [(g, a, b) for g, a, b in gaps if (prompt_tokens + a) // 512 != (prompt_tokens + b) // 512]
out = " ".join(f"kv{(prompt_tokens + b) // 512 * 512}:{g * 1000:.1f}ms" for g, a, b in cross)
print(f"STREAM prompt_tokens={prompt_tokens} generated~{events[-1][1]} events={len(events)} "
      f"seconds={events[-1][0] - t0:.2f} median_gap_ms={med * 1000:.1f} "
      f"p90_gap_ms={statistics.quantiles([g for g, _, _ in gaps], n=10)[-1] * 1000:.1f} "
      f"max_gap_ms={max(g for g, _, _ in gaps) * 1000:.1f} boundary_gaps=[{out}]")
