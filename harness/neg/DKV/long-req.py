"""Dense-KV long-context request (review/DENSE-KV-2026-10-23.md).

Builds a prompt of about TARGET tokens (chat template included): a code word
at the start, numbered filler lines, then a question about the code word and
the capital of France. Sends it at temperature 0 with reasoning_effort none
and samples the child's physical footprint (proc_pid_rusage) once a second
during the request.
Prints two lines: PASS/FAIL with tokens and answer, then footprint numbers.
usage: long-req.py PORT TOKENIZER_DIR TARGET CHILD_PID
"""
import ctypes
import json
import sys
import threading
import time
import urllib.request

from transformers import AutoTokenizer

port, tok_dir, target, pid = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
MODEL = "audreyt/Qwen3.8-27B-Splash-abliterated"
CODE = "7319-KESTREL"
lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")


def footprint():
    buf = (ctypes.c_uint64 * 64)()
    if lib.proc_pid_rusage(pid, 4, ctypes.byref(buf)) != 0:
        return None
    u = list(buf)[2:]   # after the 16-byte UUID
    return u[7], u[28]  # ri_phys_footprint, ri_lifetime_max_phys_footprint


tok = AutoTokenizer.from_pretrained(tok_dir)
head = f"Remember this code word exactly: {CODE}. You will be asked for it at the end.\n\n"
tail = ("\n\nQuestion: What is the code word given at the very start of this message? "
        "Then name the capital of France in one word. Answer in the form: CODE, CITY.")
colors = ["amber", "cobalt", "crimson", "jade", "ochre", "slate", "teal", "violet"]


def filler(n):
    return "\n".join(
        f"Log line {i:05d}: sensor {i % 97} in bay {i % 13} reported {colors[i % 8]} "
        f"status at {(i * 7) % 24:02d}:{(i * 11) % 60:02d}." for i in range(n))


def count(n):
    msgs = [{"role": "user", "content": head + filler(n) + tail}]
    text = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
    return len(tok(text, add_special_tokens=False)["input_ids"])


per = count(200) - count(100)
n = max(1, (target - count(0)) * 100 // per)
while count(n) > target:
    n -= max(1, (count(n) - target) * 100 // per + 1)
expected = count(n)
body = json.dumps({"model": MODEL, "max_tokens": 256, "temperature": 0, "reasoning_effort": "none",
                   "messages": [{"role": "user", "content": head + filler(n) + tail}]}).encode()

start_fp = footprint()
peak = [start_fp[0] if start_fp else 0]
done = threading.Event()


def sample():
    while not done.is_set():
        f = footprint()
        if f:
            peak[0] = max(peak[0], f[0])
        time.sleep(1)


th = threading.Thread(target=sample, daemon=True)
th.start()
t0 = time.time()
try:
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=1800) as r:
        resp = json.load(r)
    msg = resp["choices"][0]["message"]
    answer = (msg.get("content") or "").strip().replace("\n", " ")
    usage = resp.get("usage", {})
    err = (f"finish={resp['choices'][0].get('finish_reason')} "
           f"reasoning_chars={len(msg.get('reasoning_content') or '')}")
except urllib.error.HTTPError as e:
    answer, usage, err = "", {}, f"http={e.code} {e.read()[:300]!r}"
except Exception as e:  # noqa: BLE001
    answer, usage, err = "", {}, f"error={e!r}"
secs = time.time() - t0
done.set()
th.join()
end_fp = footprint()
ok = CODE.lower() in answer.lower() and "paris" in answer.lower()
gib = lambda b: f"{b / 2**30:.2f}GiB" if b else "na"
print(f"{'PASS' if ok else 'FAIL'} long target={target} expected_prompt_tokens={expected} "
      f"prompt_tokens={usage.get('prompt_tokens', 'na')} completion_tokens={usage.get('completion_tokens', 'na')} "
      f"seconds={secs:.1f} answer={answer!r} {err}".rstrip())
print(f"MEM footprint_before={start_fp[0] if start_fp else 'na'} ({gib(start_fp[0] if start_fp else 0)}) "
      f"footprint_peak_sampled={peak[0]} ({gib(peak[0])}) "
      f"footprint_after={end_fp[0] if end_fp else 'na'} ({gib(end_fp[0] if end_fp else 0)}) "
      f"lifetime_max={end_fp[1] if end_fp else 'na'} ({gib(end_fp[1] if end_fp else 0)})")
