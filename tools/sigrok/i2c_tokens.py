#!/usr/bin/env python3
"""Turn srd_run i2c annotations into bus tokens (S, Sr, P, A<addr><R|W><+|->, W<b><+|->,
R<b><+|->) and the RX push stream implied by the bus for the controller package
(doc/protocols/i2c_v1.md 2.2: read bytes in order; one status per transaction at its P or
Sr: 1 address NACK, 2 data NACK, else 0).
Usage: i2c_tokens.py <ann> <tokens out> <pushes out>"""
import sys

ann, tok_out, push_out = sys.argv[1:4]
rows = []
for line in open(ann):
    f = line.rstrip("\n").split(" ", 4)
    if f[0] != "i2c":
        continue
    rows.append((int(f[1]), int(f[3]), f[4]))
rows.sort(key=lambda r: r[0])
toks, pushes = [], []
status = None
for _, cls, text in rows:
    if cls in (0, 1):
        if cls == 1 and status is not None:
            pushes.append(status)
        toks.append("S" if cls == 0 else "Sr")
        status = 0
    elif cls == 2:
        toks.append("P")
        if status is not None:
            pushes.append(status)
        status = None
    elif cls in (6, 7) and ":" in text:
        toks.append("A%s%s" % (text.split(":")[1].strip().upper(), "R" if cls == 6 else "W"))
    elif cls in (8, 9):
        b = text.split(":")[1].strip().upper()
        toks.append(("R" if cls == 8 else "W") + b)
        if cls == 8:
            pushes.append(int(b, 16))
    elif cls in (3, 4):
        ack = cls == 3
        toks[-1] += "+" if ack else "-"
        if not ack and toks[-1][0] == "A":
            status = 1
        elif not ack and toks[-1][0] == "W":
            status = 2
open(tok_out, "w").write("".join(t + "\n" for t in toks))
open(push_out, "w").write("".join("%02X\n" % b for b in pushes))
