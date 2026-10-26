#!/usr/bin/env python3
"""Engine-path KV budget test: write kestrel-shaped prompts of a target token count.

Uses the same filler and the same chat template counting as neg/CKV/req.py, so a
prompt of N tokens here matches N tokens in the child's cap test.
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from transformers import AutoTokenizer

TOK = os.path.expanduser("~/projects/sealed-backends-spike/sealed-m5/pkg/qwen38-27b/tokenizer")
tok = AutoTokenizer.from_pretrained(TOK)
colors = ["red", "amber", "green", "blue", "violet", "white", "black", "grey"]
CODE = "7319-KESTREL"


def filler(n):
    return "\n".join(
        f"Log line {i:05d}: sensor {i % 97} in bay {i % 13} reported {colors[i % 8]} "
        f"status at {(i * 7) % 24:02d}:{(i * 11) % 60:02d}." for i in range(n))


def count(text):
    msgs = [{"role": "user", "content": text}]
    t = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
    return len(tok(t, add_special_tokens=False)["input_ids"])


head = f"Remember this code word exactly: {CODE}. You will be asked for it at the end.\n\n"
tail = ("\n\nQuestion: What is the code word given at the very start of this message? "
        "Then name the capital of France in one word. Answer in the form: CODE, CITY.")
make = lambda n: head + filler(n) + tail
target = int(sys.argv[1])
per = count(make(200)) - count(make(100))
n = max(1, (target - count(make(0))) * 100 // per)
while n > 1 and count(make(n)) > target:
    n -= max(1, (count(make(n)) - target) * 100 // per + 1)
sys.stdout.write(make(n))
sys.stderr.write(f"tokens={count(make(n))}\n")
