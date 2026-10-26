"""Chunked-KV request tool (review/CHUNKED-KV-2026-10-23.md).

One chat request per call, temperature 0, reasoning_effort none. Samples the
child's physical footprint (proc_pid_rusage ri_phys_footprint) once every
0.25 s during the request and once SETTLE seconds after it, so a release at
the end of the request is visible.

usage: req.py PORT TOKENIZER CHILD_PID MODE ARGS...
  MODE kestrel TARGET            code word at the start, filler, question
  MODE filler TARGET NONCE MAXTOK  NONCE first (no prefix hit), filler, "OK"
  MODE decode NONCE MAXTOK       short prompt, long answer (decode speed)
  MODE prefix SYSTEM_TOKENS SYSNONCE USERNONCE   system prompt that starts
                                 with SYSNONCE (same SYSNONCE = same system
                                 prompt), then a user turn with USERNONCE
                                 that asks for the vault code
Prints one RESULT line (key=value) and one MEM line.
"""
import ctypes
import json
import sys
import threading
import time
import urllib.error
import urllib.request

from transformers import AutoTokenizer

port, tok_dir, pid, mode = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
args = sys.argv[5:]
SETTLE = 4.0
MODEL = "audreyt/Qwen3.8-27B-Splash-abliterated"
CODE = "7319-KESTREL"
lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
tok = AutoTokenizer.from_pretrained(tok_dir)
colors = ["amber", "cobalt", "crimson", "jade", "ochre", "slate", "teal", "violet"]


def footprint():
    buf = (ctypes.c_uint64 * 64)()
    if lib.proc_pid_rusage(pid, 4, ctypes.byref(buf)) != 0:
        return None
    u = list(buf)[2:]
    return u[7], u[28]


def filler(n, offset=0):
    return "\n".join(
        f"Log line {i:05d}: sensor {i % 97} in bay {i % 13} reported {colors[i % 8]} "
        f"status at {(i * 7) % 24:02d}:{(i * 11) % 60:02d}." for i in range(offset, offset + n))


def count(msgs):
    text = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
    return len(tok(text, add_special_tokens=False)["input_ids"])


def fit(target, make):
    per = count(make(200)) - count(make(100))
    n = max(1, (target - count(make(0))) * 100 // per)
    while n > 1 and count(make(n)) > target:
        n -= max(1, (count(make(n)) - target) * 100 // per + 1)
    return make(n), count(make(n))


max_tokens = 256
check = None
if mode == "kestrel":
    head = f"Remember this code word exactly: {CODE}. You will be asked for it at the end.\n\n"
    tail = ("\n\nQuestion: What is the code word given at the very start of this message? "
            "Then name the capital of France in one word. Answer in the form: CODE, CITY.")
    msgs, expected = fit(int(args[0]), lambda n: [{"role": "user", "content": head + filler(n) + tail}])
    check = lambda a: CODE.lower() in a.lower() and "paris" in a.lower()
elif mode == "filler":
    nonce, max_tokens = args[1], int(args[2])
    msgs, expected = fit(int(args[0]), lambda n: [{"role": "user", "content":
        f"Session {nonce}.\n" + filler(n) + "\n\nReply with the single word OK."}])
    check = lambda a: "ok" in a.lower()
elif mode == "decode":
    nonce, max_tokens = args[0], int(args[1])
    msgs = [{"role": "user", "content": f"Session {nonce}. Write a long, detailed story about a "
             "lighthouse keeper who finds a map in a bottle. Use at least 800 words."}]
    expected = count(msgs)
    check = lambda a: len(a) > 200
elif mode == "prefix":
    sys_tokens, sys_nonce, user_nonce = int(args[0]), args[1], args[2]
    rules = (f"Archive {sys_nonce}. You are the archive assistant. The vault code is {CODE}. "
             "The archive log follows; answer questions about it briefly.\n\n")
    def make(n):
        return [{"role": "system", "content": rules + filler(n)},
                {"role": "user", "content": f"Ticket {user_nonce}: what is the vault code? "
                 "Answer with the code only."}]
    msgs, expected = fit(sys_tokens, make)
    check = lambda a: CODE.lower() in a.lower()
else:
    sys.exit(f"unknown mode {mode}")

body = json.dumps({"model": MODEL, "max_tokens": max_tokens, "temperature": 0,
                   "reasoning_effort": "none", "messages": msgs}).encode()
start = footprint()
peak = [start[0] if start else 0]
done = threading.Event()


def sample():
    while not done.is_set():
        f = footprint()
        if f:
            peak[0] = max(peak[0], f[0])
        time.sleep(0.25)


th = threading.Thread(target=sample, daemon=True)
th.start()
t0 = time.time()
status, answer, usage, extra = 0, "", {}, ""
try:
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=1800) as r:
        status = r.status
        resp = json.load(r)
    answer = (resp["choices"][0]["message"].get("content") or "").strip().replace("\n", " ")
    usage = resp.get("usage", {})
    lat = (resp.get("metrics") or {}).get("latency", {}) if isinstance(resp.get("metrics"), dict) else {}
    extra = (f"finish={resp['choices'][0].get('finish_reason')} "
             f"ttft_ms={lat.get('ttft_ms', 'na')} stream_tps={lat.get('stream_tokens_per_second', 'na')}")
except urllib.error.HTTPError as e:
    status = e.code
    extra = f"error_body={e.read()[:600].decode('utf-8', 'replace')!r}"
except Exception as e:  # noqa: BLE001
    extra = f"error={e!r}"
secs = time.time() - t0
done.set()
th.join()
end = footprint()
time.sleep(SETTLE)
settled = footprint()
ok = status == 200 and check(answer)
cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens", "na")
gib = lambda b: f"{b / 2**30:.3f}GiB" if b else "na"
short = answer if len(answer) <= 80 else answer[:77] + "..."
import hashlib  # noqa: E402
digest = hashlib.sha256(answer.encode()).hexdigest()[:16]
print(f"RESULT {'PASS' if ok else 'FAIL'} mode={mode} args={'/'.join(args)} http={status} "
      f"expected_prompt_tokens={expected} prompt_tokens={usage.get('prompt_tokens', 'na')} "
      f"cached_tokens={cached} completion_tokens={usage.get('completion_tokens', 'na')} "
      f"seconds={secs:.2f} {extra} answer_sha={digest} answer={short!r}")
print(f"MEM before={start[0] if start else 'na'} ({gib(start[0] if start else 0)}) "
      f"peak={peak[0]} ({gib(peak[0])}) end={end[0] if end else 'na'} ({gib(end[0] if end else 0)}) "
      f"settled={settled[0] if settled else 'na'} ({gib(settled[0] if settled else 0)}) "
      f"lifetime_max={settled[1] if settled else 'na'} ({gib(settled[1] if settled else 0)})")
