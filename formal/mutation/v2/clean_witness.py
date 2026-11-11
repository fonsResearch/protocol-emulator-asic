#!/usr/bin/env python3
"""Fail witnesses whose last frame also has a blame (not clean: the environment is violated in
the same step). Reads the interpreter lines of the formal replays."""
import glob
import re

dirty = []
for f in sorted(glob.glob("formal/work/mut_v2/witness3/w2_*_F??.replay.txt")):
    t = open(f).read()
    m = re.search(r"bad first rises at frame (\d+)", t)
    if not m:
        continue
    last = m.group(1)
    hits = re.findall(r"# interp frame (\d+): (fail|blame) ([0-9A-F]{2})", t)
    b = [c for k, r, c in hits if k == last and r == "blame"]
    if b:
        dirty.append((f.split("/")[-1][:-11], last, b))
for d in dirty:
    print(*d)
print("fail witnesses with a same-frame blame:", len(dirty))
