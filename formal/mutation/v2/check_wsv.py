#!/usr/bin/env python3
"""Sanity of the W oracle runs: on every witness trace the witnessed check fires in the golden
contract's first verdict frame; summary of W results."""
import collections
import glob
import re

bad, seen = 0, set()
for f in sorted(glob.glob("formal/work/mut_v2/wsv/*.txt")):
    for l in open(f):
        m = re.match(r"(?:directed )?(\S+_[FB][0-9A-F]{2}) golden \[([^\]]*)\]", l)
        if not m or m.group(1) in seen:
            continue
        name, g = m.group(1), m.group(2)
        seen.add(name)
        fs = [x.split("@") for x in g.split(",")] if g else []
        # the witnessed check is part of the first verdict: it fires in the first firing frame
        # (firings are shown up to 3, so a frame with more firings is reported, not assumed)
        if not fs or not any(c == name[-3:] and t == fs[0][1] for c, t in fs):
            bad += 1
            print("golden first != target:", name, g)
print("witness traces checked", len(seen), "target not in first verdict", bad)
res = collections.Counter(open(f).read().strip().splitlines()[-1].split()[1] for f in glob.glob("formal/work/mut_v2/wsv/*.txt"))
print(dict(res))
