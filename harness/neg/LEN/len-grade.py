#!/usr/bin/env python3
"""Grade the R2-5-03 length run (neg/LEN/len-root.sh output folder).

Reads fsusage.txt, picks the write-type syscalls (write, sendto, sendmsg,
writev) made by the engine and by the child, and checks their byte counts
against the wire formula:
  request frame (engine -> child): 24 + 64 + 4*P   (P = prompt tokens)
  tokens frame  (child -> engine): 24 + 16 + 4*n   (n = tokens in the frame)
Verdict per the criteria in len-root.sh.
"""
import re, sys, os, collections

d = sys.argv[1]
lines = open(os.path.join(d, "fsusage.txt"), errors="replace").read().splitlines()
W = re.compile(r"\b(write|write_nocancel|sendto|sendto_nocancel|sendmsg|sendmsg_nocancel|writev|writev_nocancel)\b.*?B=0x([0-9a-f]+)")
eng, chi = [], []
for l in lines:
    m = W.search(l)
    if not m:
        continue
    n = int(m.group(2), 16)
    if "SealedEngine" in l:
        eng.append(n)
    elif "splash" in l:
        chi.append(n)

def fits(n, base):
    return n >= base and (n - base) % 4 == 0

req = [(n, (n - 88) // 4) for n in eng if fits(n, 88) and n > 88]
tok = [(n, (n - 40) // 4) for n in chi if fits(n, 40) and n > 40]
print(f"events: {len(lines)} lines; engine writes {len(eng)}, child writes {len(chi)}")
print(f"engine write sizes (count): {dict(collections.Counter(eng).most_common(12))}")
print(f"child write sizes (count):  {dict(collections.Counter(chi).most_common(12))}")
print(f"engine writes that fit a REQUEST frame (24+64+4P): {[(n, P) for n, P in req][:10]}")
print(f"child writes that fit a TOKENS frame (24+16+4n):   {[(n, k) for n, k in tok][:20]}")

if not eng and not chi:
    print("VERDICT: VOID (no write events for the engine or the child; fs_usage control failed)")
elif len({P for _, P in req}) >= 2 and tok:
    ps = sorted({P for _, P in req})
    total = sum(k for _, k in tok)
    print(f"VERDICT: CONFIRMED (root reads prompt token counts {ps} from the engine's request-frame sizes, "
          f"and per-frame reply token counts from the child's frame sizes; {len(tok)} token frames, {total} tokens total)")
elif req or tok:
    print("VERDICT: PARTLY CONFIRMED (some write sizes fit the formula; see the lists above)")
else:
    print("VERDICT: NOT SHOWN (no write size fits the wire formula)")
