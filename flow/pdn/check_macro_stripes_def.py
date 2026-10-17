#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Re-check the macro power-column property (macro_stripes_geom.check, C1-C3) on a final DEF,
without OpenROAD. Intended for CI artifacts (runs/wokwi/final/def/*.def).

usage: check_macro_stripes_def.py <design.def> <macro.lef> [--master RM_IHPSG13_1P_64x16_c2]
exit 0 = property holds, 1 = violations, 2 = parse problem.

DEF subset handled: UNITS, COMPONENTS (+ PLACED/FIXED, orientations N and FS), SPECIALNETS
VPWR/VGND with `+ ROUTED|FIXED|COVER|SHIELD|NEW <layer> <width> ... ( x y ) ( x|* y|* )` paths and
`+ RECT <layer> ( x0 y0 ) ( x1 y1 )`. Special-wire paths are taken as flush at their end
points (no half-width extension). That is an assumption about the DEF writer; the in-flow check
in odb_macro_stripes.py reads the boxes directly and is the authoritative one.
"""
import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import macro_stripes_geom as G  # noqa: E402

PINS = {"VDD!": "P", "VDDARRAY!": "P", "VSS!": "G"}
NETS = {"VPWR": "P", "VGND": "G"}


def parse_def(text, layer, master):
    dbu = int(re.search(r"UNITS\s+DISTANCE\s+MICRONS\s+(\d+)", text).group(1))
    comps = re.search(r"\nCOMPONENTS\s+\d+\s*;(.*?)\nEND COMPONENTS", text, re.S).group(1)
    macros = []
    for m in re.finditer(r"-\s+(\S+)\s+(\S+)(.*?);", comps, re.S):
        name, mst, rest = m.groups()
        if mst != master:
            continue
        pm = re.search(r"\+\s+(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)", rest)
        macros.append((name.replace("\\", ""), int(pm.group(1)), int(pm.group(2)), pm.group(3)))
    snets = re.search(r"\nSPECIALNETS\s+\d+\s*;(.*?)\nEND SPECIALNETS", text, re.S).group(1)
    shapes = []
    for nm in re.finditer(r"-\s+(\S+)(.*?);", snets, re.S):
        net, body = nm.groups()
        if net not in NETS:
            continue
        pol = NETS[net]
        for rm in re.finditer(r"\+\s+RECT\s+(\S+)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)", body):
            lay, x0, y0, x1, y1 = rm.group(1), *map(int, rm.groups()[1:])
            if lay == layer:
                shapes.append(G.Rect(pol, net, min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)))
        stmts = re.split(r"(?=\bNEW\s)|(?=\+\s+(?:ROUTED|FIXED|COVER|SHIELD)\s)", body)
        for st in stmts:
            hm = re.match(r"\s*(?:\+\s+(?:ROUTED|FIXED|COVER|SHIELD\s+\S+)|NEW)\s+(\S+)\s+(\d+)", st)
            if not hm or hm.group(1) != layer:
                continue
            width = int(hm.group(2))
            st = st.split("+ RECT")[0]
            pts = re.findall(r"\(\s*(-?\d+|\*)\s+(-?\d+|\*)(?:\s+-?\d+)?\s*\)", st[hm.end():])
            px = py = None
            seq = []
            for xs, ys in pts:
                x = px if xs == "*" else int(xs)
                y = py if ys == "*" else int(ys)
                seq.append((x, y))
                px, py = x, y
            for (ax, ay), (bx, by) in zip(seq, seq[1:]):
                h = width // 2
                if ax == bx:  # vertical
                    shapes.append(G.Rect(pol, net, ax - h, min(ay, by), ax + h, max(ay, by)))
                elif ay == by:  # horizontal
                    shapes.append(G.Rect(pol, net, min(ax, bx), ay - h, max(ax, bx), ay + h))
    return dbu, macros, shapes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("def_file")
    ap.add_argument("lef_file")
    ap.add_argument("--master", default="RM_IHPSG13_1P_64x16_c2")
    ap.add_argument("--layer", default="Metal4")
    ap.add_argument("--allow-pin-gaps", action="store_true", help="accept crossing same-polarity pin gaps (full-span mode)")
    ap.add_argument("--lef", help="exported top-level LEF: also run C4 (TT full-height power-pin rule) on its ports")
    a = ap.parse_args()
    lef = Path(a.lef_file).read_text()
    try:
        dbu, macros, shapes = parse_def(Path(a.def_file).read_text(), a.layer, a.master)
    except Exception as e:  # noqa: BLE001
        print(f"parse error: {e}")
        return 2
    if not macros:
        print(f"no {a.master} instance in DEF")
        return 2
    size = G.lef_size(lef)
    rects = G.lef_power_rects(lef, PINS, a.layer)
    bad = 0
    for name, x, y, orient in macros:
        cols = G.place(rects, size, (x / dbu, y / dbu), orient, dbu)
        macro = (x, y, x + round(size[0] * dbu), y + round(size[1] * dbu))
        v = G.check(macro, cols, shapes, allow_pin_gaps=a.allow_pin_gaps)
        fed = {c.name for c in cols for s in shapes
               if s.pol == c.pol and c.x0 <= s.x0 and s.x1 <= c.x1 and s.y0 < c.y1 and c.y0 < s.y1}
        print(f"{name} @ ({x / dbu}, {y / dbu}) {orient}: {len(shapes)} supply shapes on {a.layer}, "
              f"pins fed: {sorted(fed)}, violations: {len(v)}")
        for line in v:
            print("  " + line)
        bad += len(v)
    if a.lef:
        lt = Path(a.lef).read_text()
        sz = re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", lt)
        die = (0, 0, round(float(sz.group(1)) * dbu), round(float(sz.group(2)) * dbu))
        pins = G.lef_port_rects(lt, "VPWR", "P", a.layer, dbu) + G.lef_port_rects(lt, "VGND", "G", a.layer, dbu)
        c4 = G.check_pins(pins, die, dbu)
        print(f"C4 on {Path(a.lef).name}: {len(pins)} power ports, {len(c4)} violations")
        for line in c4[:30]:
            print("  " + line)
        bad += len(c4)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
