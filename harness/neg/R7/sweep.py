#!/usr/bin/env python3
"""R7-T3 workload against the test server (review/R7T3-2026-10-22.md).

usage: sweep.py <base url> sweep|nomask|mask|one|long|end

sweep  one request per field value: max_tokens, temperature, top_p, top_k,
       seed, reasoning_effort, prompt length, streaming, stop, structured
       output, tools, image input, multi-turn, and two concurrent requests
nomask the sweep without the two requests that use token masks (structured
       output, tools): the R6 share-mode check refuses those on this pair
       with or without the R7-T3 code (review/R7T3-2026-10-22.md)
mask   only the token-mask requests, plus one longer structured output
one    one short request
long   generations of up to 30000 tokens until one lasts at least 300 s
       (three attempts at most)
end    one short request (the child runs its end check before it)

Prints one line per request: REQ <name> http=<code> finish=<reason>
prompt=<n> completion=<n> secs=<s>.
"""
import base64
import json
import struct
import sys
import threading
import time
import urllib.error
import urllib.request
import zlib

MODEL = "audreyt/Qwen3.8-27B-Splash-abliterated"
BASE = sys.argv[1].rstrip("/")
MODE = sys.argv[2]

PARA = (
    "The lighthouse keeper wrote the tide tables by hand every evening, checking each "
    "entry against the almanac and the barometer, and noting the wind, the swell and "
    "the colour of the sky before the lamp was lit. "
)


def png_data_url(w=64, h=64):
    raw = b"".join(b"\x00" + bytes(v for x in range(w) for v in (x * 4 % 256, y * 4 % 256, 128)) for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    return "data:image/png;base64," + base64.b64encode(png).decode()


def post(name, body, timeout=900):
    body = {"model": MODEL, **body}
    t0 = time.time()
    req = urllib.request.Request(BASE + "/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    code, finish, ptok, ctok, note = 0, "-", -1, -1, ""
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            code = r.status
            if body.get("stream"):
                chunks = 0
                for line in r:
                    line = line.decode(errors="replace").strip()
                    if not line.startswith("data:") or line == "data: [DONE]":
                        continue
                    ev = json.loads(line[5:])
                    chunks += 1
                    for ch in ev.get("choices", []):
                        if ch.get("finish_reason"):
                            finish = ch["finish_reason"]
                    if ev.get("usage"):
                        ptok = ev["usage"].get("prompt_tokens", -1)
                        ctok = ev["usage"].get("completion_tokens", -1)
                note = f"chunks={chunks}"
            else:
                j = json.load(r)
                ch = j["choices"][0]
                finish = ch.get("finish_reason")
                ptok = j.get("usage", {}).get("prompt_tokens", -1)
                ctok = j.get("usage", {}).get("completion_tokens", -1)
                if ch["message"].get("tool_calls"):
                    note = "tool_calls=%d" % len(ch["message"]["tool_calls"])
    except urllib.error.HTTPError as e:
        code = e.code
        note = e.read()[:160].decode(errors="replace").replace("\n", " ")
    except Exception as e:  # noqa: BLE001 - recorded, not raised
        note = f"{type(e).__name__}: {e}"[:160]
    secs = time.time() - t0
    print(f"REQ {name} http={code} finish={finish} prompt={ptok} completion={ctok} secs={secs:.1f} {note}", flush=True)
    return code, secs, ctok


def user(text):
    return [{"role": "user", "content": text}]


SHORT = user("Name three colours of the sea in one line.")


MASKED = ("structured-json", "tools")


def sweep(only=None, skip=()):
    base = {"messages": SHORT, "max_tokens": 32, "temperature": 0, "reasoning_effort": "none"}
    cases = [
        ("base", {}),
        ("max_tokens-1", {"max_tokens": 1}),
        ("max_tokens-512-t0.7-p0.9-k32", {"max_tokens": 512, "temperature": 0.7, "top_p": 0.9, "top_k": 32}),
        ("t1.5-p0.5-k1", {"max_tokens": 64, "temperature": 1.5, "top_p": 0.5, "top_k": 1}),
        ("t2.0-p1.0-k32-seed7", {"max_tokens": 64, "temperature": 2.0, "top_p": 1.0, "top_k": 32, "seed": 7}),
        ("reasoning-low", {"max_tokens": 256, "reasoning_effort": "low"}),
        ("reasoning-high", {"max_tokens": 512, "reasoning_effort": "high"}),
        ("reasoning-default", {"max_tokens": 256, "reasoning_effort": None}),
        ("prompt-medium", {"messages": user(PARA * 40 + "Summarise this in one sentence."), "max_tokens": 64}),
        ("prompt-long", {"messages": user(PARA * 300 + "Summarise this in one sentence."), "max_tokens": 64}),
        ("stream-t0.7", {"stream": True, "max_tokens": 128, "temperature": 0.7,
                         "stream_options": {"include_usage": True}}),
        ("stop", {"max_tokens": 256, "temperature": 0.7, "stop": ["\n\n", "blue"],
                  "messages": user("Write two short paragraphs about the sea.")}),
        ("structured-json", {"max_tokens": 256, "response_format": {"type": "json_schema", "json_schema": {
            "name": "c", "schema": {"type": "object", "properties": {"colours": {"type": "array", "items": {"type": "string"}}},
                                    "required": ["colours"], "additionalProperties": False}}}}),
        ("tools", {"max_tokens": 256, "messages": user("What is the weather in Lisbon? Use the tool."),
                   "tools": [{"type": "function", "function": {"name": "get_weather", "description": "Weather for a city",
                              "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}],
                   "tool_choice": "auto"}),
        ("image", {"max_tokens": 32, "messages": [{"role": "user", "content": [
            {"type": "text", "text": "Describe this image in five words."},
            {"type": "image_url", "image_url": {"url": png_data_url()}}]}]}),
        ("multi-turn", {"max_tokens": 64, "temperature": 0.3, "messages": [
            {"role": "system", "content": "You answer briefly."},
            {"role": "user", "content": "Pick a number."},
            {"role": "assistant", "content": "Seven."},
            {"role": "user", "content": "Double it and explain in one line."}]}),
    ]
    if only == "mask":
        cases = [c for c in cases if c[0] in MASKED]
        cases.append(("structured-json-long", {"max_tokens": 2048, "temperature": 0.7, "messages": user(
            "List 60 invented island names with a short description of each, as JSON."),
            "response_format": {"type": "json_schema", "json_schema": {"name": "isl", "schema": {
                "type": "array", "minItems": 60, "items": {"type": "object", "properties": {
                    "name": {"type": "string"}, "description": {"type": "string"}},
                    "required": ["name", "description"], "additionalProperties": False}}}}}))
    cases = [c for c in cases if c[0] not in skip]
    for name, over in cases:
        body = {**base, **over}
        body = {k: v for k, v in body.items() if v is not None}
        post(name, body)
    # Two requests at the same time (batched decode in the engine).
    ts = [threading.Thread(target=post, args=(f"concurrent-{i}", {**base, "max_tokens": 256, "temperature": 0.8,
                                                                  "messages": user(f"Tell a two-line story number {i}.")}))
          for i in (1, 2)]
    if only == "mask":
        return
    for t in ts:
        t.start()
    for t in ts:
        t.join()


def long_run():
    attempts = [
        ("long-list-t0.9", {"temperature": 0.9, "top_p": 0.95, "messages": user(
            "Write a numbered list of 3000 invented island names, numbered 1 to 3000, each followed by a one-sentence "
            "description of its harbour. Do not stop before item 3000 and do not summarise.")}),
        ("long-story-t1.0", {"temperature": 1.0, "top_p": 0.95, "messages": user(
            "Write the full text of a 30-chapter novel about a lighthouse keeper. Write every chapter in full, at least "
            "1500 words each. Do not summarise and do not stop early.")}),
        ("long-count-t0", {"temperature": 0, "messages": user(
            "Write the integers from 1 to 50000 in English words, one per line, with no other text.")}),
    ]
    for name, over in attempts:
        body = {"max_tokens": 30000, "reasoning_effort": "none", "stream": True,
                "stream_options": {"include_usage": True}, **over}
        code, secs, _ = post(name, body, timeout=1800)
        if code == 200 and secs >= 300:
            print(f"LONG ok name={name} secs={secs:.1f}", flush=True)
            return
    print("LONG short: no generation reached 300 s", flush=True)


if MODE == "sweep":
    sweep()
elif MODE == "nomask":
    sweep(skip=MASKED)
elif MODE == "mask":
    sweep(only="mask")
elif MODE == "one":
    post("one", {"messages": SHORT, "max_tokens": 16, "temperature": 0, "reasoning_effort": "none"})
elif MODE == "long":
    long_run()
elif MODE == "end":
    post("end", {"messages": SHORT, "max_tokens": 8, "temperature": 0, "reasoning_effort": "none"})
else:
    sys.exit("unknown mode")
