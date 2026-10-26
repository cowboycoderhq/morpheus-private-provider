#!/usr/bin/env python3
"""Grade neg/LEN/spec-root.sh: mean tokens per child tokens-frame, by reply kind.

A tokens frame is a child write of 24 + 16 + 4*n bytes (n >= 1). The child's
other writes (1-byte wakeups, 45/69-byte control frames) are not of that form
with n >= 1 and a size > 40, except 44 (n=1), which is counted.
"""
import re, sys, os, glob, statistics

d = sys.argv[1]
W = re.compile(r"\bwrite\b.*?\bF=1\b.*?B=0x([0-9a-f]+)")
res = {"pred": [], "unp": []}
for f in sorted(glob.glob(os.path.join(d, "fs-*.txt"))):
    kind = os.path.basename(f).split("-")[1]
    ns = []
    for l in open(f, errors="replace"):
        m = W.search(l)
        if not m:
            continue
        b = int(m.group(1), 16)
        if b > 40 and (b - 40) % 4 == 0:
            ns.append((b - 40) // 4)
    if ns:
        res[kind].append((sum(ns) / len(ns), len(ns), sum(ns), ns))
for kind in ("pred", "unp"):
    for mean, frames, toks, ns in res[kind]:
        print(f"{kind}: frames={frames} tokens={toks} mean tokens/frame={mean:.2f} sizes={ns}")
p = [r[0] for r in res["pred"]]; u = [r[0] for r in res["unp"]]
if len(p) < 3 or len(u) < 3:
    print(f"VERDICT: VOID ({len(p)} predictable and {len(u)} unpredictable usable runs; need 3 each)")
    sys.exit(0)
mp, mu = statistics.mean(p), statistics.mean(u)
sd = max(statistics.pstdev(p), statistics.pstdev(u), 0.01)
print(f"mean tokens/frame: predictable {mp:.2f}, unpredictable {mu:.2f}, margin 2*sd = {2*sd:.2f}")
if abs(mp - mu) > 2 * sd:
    print(f"VERDICT: SIGNAL (frame sizes separate predictable from unpredictable replies by {abs(mp-mu):.2f} tokens/frame)")
else:
    print("VERDICT: NO SIGNAL (the means overlap within 2 standard deviations)")
