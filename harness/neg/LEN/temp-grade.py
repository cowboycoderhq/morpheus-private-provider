#!/usr/bin/env python3
"""Grade neg/LEN/temp-root.sh (criteria are in that script).

A tokens frame is a child write on fd 1 of 24 + 16 + 4*n bytes (n >= 1, so
more than 40 bytes). The sequence of n values is one run's pattern.
"""
import glob
import os
import re
import statistics
import sys
from itertools import combinations

d = sys.argv[1]
W = re.compile(r"\bwrite\b.*?\bF=1\b.*?B=0x([0-9a-f]+)")
runs = {}  # (t, p) -> [sequence, ...]
for f in sorted(glob.glob(os.path.join(d, "fs-t*-p*-r*.txt"))):
    m = re.search(r"fs-t([0-9.]+)-p(\d)-r(\d)\.txt$", f)
    t, p = m.group(1), int(m.group(2))
    seq = []
    for line in open(f, errors="replace"):
        w = W.search(line)
        if w:
            b = int(w.group(1), 16)
            if b > 40 and (b - 40) % 4 == 0:
                seq.append((b - 40) // 4)
    if seq:
        runs.setdefault((t, p), []).append(seq)

prompts = sorted({p for _, p in runs})
void = [(t, p) for t in ("0", "0.6") for p in range(4) if len(runs.get((t, p), [])) < 2]
for (t, p), seqs in sorted(runs.items()):
    for s in seqs:
        print(f"t={t} p={p}: frames={len(s)} tokens={sum(s)} mean={sum(s)/len(s):.2f} seq={s}")
if void:
    print(f"VERDICT: VOID (fewer than 2 usable runs for {void})")
    sys.exit(0)

same0 = [p for p in range(4) if all(s == runs[("0", p)][0] for s in runs[("0", p)])]
print(f"temperature 0: prompts whose runs all give the same sequence: {same0} of 4")
repeats = len(same0) >= 3
firsts = [tuple(runs[("0", p)][0]) for p in range(4)]
distinct = len(set(firsts)) == 4
print(f"temperature 0: distinct sequences across the 4 prompts: {len(set(firsts))}")

same6 = [p for p in range(4) if all(s == runs[("0.6", p)][0] for s in runs[("0.6", p)])]
print(f"temperature 0.6: prompts whose runs all give the same sequence: {same6} of 4")
means = {p: [sum(s) / len(s) for s in runs[("0.6", p)]] for p in range(4)}
sd = max(max(statistics.pstdev(v) for v in means.values()), 0.01)
pairs = []
for a, b in combinations(range(4), 2):
    diff = abs(statistics.mean(means[a]) - statistics.mean(means[b]))
    pairs.append((a, b, diff))
    print(f"temperature 0.6: prompts {a},{b}: mean tokens/frame {statistics.mean(means[a]):.2f} vs {statistics.mean(means[b]):.2f}, diff {diff:.2f}")
signal6 = any(diff > 2 * sd for _, _, diff in pairs)
print(f"temperature 0.6: margin 2 x largest per-prompt sd = {2*sd:.2f}")

print(f"VERDICT REPEATS-AT-0: {'YES' if repeats else 'NO'}")
print(f"VERDICT DISTINCT-AT-0: {'YES' if distinct else 'NO'}")
print(f"VERDICT SIGNAL-AT-0.6: {'YES' if signal6 else 'NO'}")
