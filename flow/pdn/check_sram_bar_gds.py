#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Verify on the SRAM GDS that full-height VPWR stripes may cross the Metal4 OBS bar between
VDD! and VDDARRAY! (the gaps the LibreLane step crosses with PEMU_STRIPE_CROSS_PIN_GAPS).

For each stripe footprint (macro x-interval, master coordinates) and each gap between two
same-polarity Metal4 pin rectangles of the column containing it, require:
  - no Metal4 drawing polygon and no Via3 polygon intersecting footprint x gap;
  - report the nearest Metal4 polygon edge in the gap band (spacing margin).
Layer numbers (IHP SG13): Metal4 50/0, Via3 49/0. They were checked against the LEF on 2026-10-17:
the 50/0 polygon at the first VDD! column equals the LEF VDD! rectangle.

usage: check_sram_bar_gds.py <macro.gds> <macro.lef> <x0:x1> [<x0:x1> ...]   (requires gdstk)
exit 0 = all gaps clear, 1 = metal or via found.
"""
import sys
from pathlib import Path

import gdstk

sys.path.insert(0, str(Path(__file__).resolve().parent))
import macro_stripes_geom as G  # noqa: E402

M4, V3 = (50, 0), (49, 0)


def main():
    gds, lef, *spans = sys.argv[1:]
    lef_text = Path(lef).read_text()
    cell_name = Path(gds).stem
    lib = gdstk.read_gds(gds)
    top = [c for c in lib.top_level() if c.name == cell_name][0].copy("flat")
    top.flatten()
    boxes = {M4: [], V3: []}
    for p in top.polygons:
        k = (p.layer, p.datatype)
        if k in boxes:
            (a0, b0), (a1, b1) = p.bounding_box()
            boxes[k].append((a0, b0, a1, b1))
    rects = G.lef_power_rects(lef_text, {"VDD!": "P", "VDDARRAY!": "P"})
    cols = [G.Rect(pol, pin, round(x0 * 1000), round(y0 * 1000), round(x1 * 1000), round(y1 * 1000))
            for pol, pin, x0, y0, x1, y1 in rects]
    bad = 0
    for span in spans:
        x0, x1 = (float(v) for v in span.split(":"))
        gaps = G._pin_gaps(cols, "P", round(x0 * 1000), round(x1 * 1000))
        if not gaps:
            print(f"x[{x0},{x1}]: no same-polarity pin gap under this footprint")
            continue
        for g0, g1 in gaps:
            y0, y1 = g0 / 1000, g1 / 1000
            hit = {k: [b for b in v if b[0] < x1 and x0 < b[2] and b[1] < y1 and y0 < b[3]] for k, v in boxes.items()}
            band = [b for b in boxes[M4] if b[1] < y1 and y0 < b[3]]
            near = min((max(b[0] - x1, x0 - b[2], 0.0) for b in band), default=float("inf"))
            ok = not hit[M4] and not hit[V3]
            bad += not ok
            print(f"x[{x0},{x1}] gap y[{y0},{y1}]: Metal4 {len(hit[M4])}, Via3 {len(hit[V3])}, "
                  f"nearest Metal4 {near:.3f} um -> {'CLEAR' if ok else 'BLOCKED'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
