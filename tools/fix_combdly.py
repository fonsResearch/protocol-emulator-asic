#!/usr/bin/env python3
"""Post-process Hardcaml Verilog (decision V7): inside combinational `always @*` blocks,
turn non-blocking assignments (`x <= e;`) into blocking ones (`x = e;`), which removes
Verilator COMBDLY warnings. Refuses to run (exit 1) on any `always @*` block line that is an
assignment it does not recognise, or on a `<=` outside the recognised form, so the transform
stays purely syntactic. Equivalence of input and output is checked separately
(tools/check_combdly_equiv.sh).
Usage: fix_combdly.py in.v out.v"""
import re
import sys

ASSIGN = re.compile(r"^(\s*)([A-Za-z_][A-Za-z0-9_$]*(?:\[[^\]]*\])?)\s*<=\s*(.*);\s*$")
src, dst = sys.argv[1], sys.argv[2]
out, in_comb, depth, changed = [], False, 0, 0
for n, line in enumerate(open(src), 1):
    s = line.rstrip("\n")
    if not in_comb and re.match(r"^\s*always @\*\s*begin\s*$", s):
        in_comb, depth = True, 1
        out.append(s)
        continue
    if in_comb:
        depth += len(re.findall(r"\bbegin\b", s)) + len(re.findall(r"\bcase\b|\bcasez\b", s))
        depth -= len(re.findall(r"\bend\b", s)) + len(re.findall(r"\bendcase\b", s))
        if "<=" in s:
            m = ASSIGN.match(s)
            if not m:
                sys.exit(f"{src}:{n}: unrecognised assignment in always @*: {s.strip()}")
            s = f"{m.group(1)}{m.group(2)} = {m.group(3)};"
            changed += 1
        if depth <= 0:
            in_comb = False
    out.append(s)
open(dst, "w").write("\n".join(out) + "\n")
print(f"fix_combdly: {changed} assignments rewritten in {src} -> {dst}")
