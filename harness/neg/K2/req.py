"""K-2 canary request (review/K2-FREED-KV-2026-10-23.md).

One chat request with a prompt that repeats CANARY on every line and asks
for it back, so the prompt KV and the reply KV both derive from it.
usage: req.py PORT TOKENIZER CANARY LINES
"""
import json
import sys
import time
import urllib.request

from transformers import AutoTokenizer

port, tok_dir, canary, lines = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
MODEL = "audreyt/Qwen3.8-27B-Splash-abliterated"
body_text = "\n".join(f"Entry {i:05d}: the canary word is {canary}. Keep the canary word {canary} safe."
                      for i in range(lines))
msgs = [{"role": "user", "content": body_text + "\n\nQuestion: what is the canary word? "
         "Answer with the canary word only, three times, separated by spaces."}]
tok = AutoTokenizer.from_pretrained(tok_dir)
text = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
expected = len(tok(text, add_special_tokens=False)["input_ids"])
body = json.dumps({"model": MODEL, "max_tokens": 96, "temperature": 0,
                   "reasoning_effort": "none", "messages": msgs}).encode()
t0 = time.time()
status, answer, usage = 0, "", {}
try:
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=1800) as r:
        status = r.status
        resp = json.load(r)
    answer = (resp["choices"][0]["message"].get("content") or "").strip().replace("\n", " ")
    usage = resp.get("usage", {})
except Exception as e:  # noqa: BLE001
    answer = f"error={e!r}"
ok = status == 200 and canary in answer
print(f"RESULT {'PASS' if ok else 'FAIL'} http={status} expected_prompt_tokens={expected} "
      f"prompt_tokens={usage.get('prompt_tokens', 'na')} completion_tokens={usage.get('completion_tokens', 'na')} "
      f"seconds={time.time() - t0:.2f} end={time.strftime('%T')} canary_in_answer={canary in answer} "
      f"answer={answer[:160]!r}")
