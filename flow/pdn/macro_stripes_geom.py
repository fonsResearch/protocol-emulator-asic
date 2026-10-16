# SPDX-License-Identifier: MIT
"""Pure geometry for powering an IHP SRAM macro from the Tiny Tapeout single-layer Metal4 PDN.

No OpenROAD dependency: used by the LibreLane step (odb_macro_stripes.py), by the
standalone DEF checker (check_macro_stripes_def.py) and by the unit tests.
All coordinates are integers in database units (DBU), die coordinates.

Model
- A *column* is one Metal4 power-pin rectangle of the macro, tagged with a polarity
  ('P' for VDD!/VDDARRAY!, 'G' for VSS!) and its pin name.
- A *segment* is one Metal4 rectangle of a tile PDN stripe (net polarity 'P' = VPWR,
  'G' = VGND). pdngen carves stripes around macros, so a stripe crossing the macro's
  x-range normally appears as a segment below and a segment above it.

plan(): for every tile stripe whose x-interval overlaps the macro, bridge it into the
macro only if the stripe lies entirely inside a column of the same polarity and touches
no column of the other polarity. Inside the macro the bridge covers only the y-intervals
of those same-polarity pin rectangles (so it never crosses the Metal4 OBS bar between
VDD! and VDDARRAY!). Every drawn piece must touch an existing segment of the stripe.

check(): the property the flow must satisfy afterwards, on any set of shapes (also the
final DEF):
  (C1) every P/G Metal4 shape that intersects the macro interior has that intersection
       contained in the union of same-polarity pin rectangles with the shape's x-interval
       inside each covering rectangle (no metal over OBS, no partial column overlap);
  (C2) no P shape overlaps a G column and no G shape overlaps a P column;
  (C3) every power pin name of the macro is touched by at least one same-polarity shape.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Sequence, Tuple


@dataclass(frozen=True)
class Rect:
    pol: str  # 'P' or 'G'
    name: str  # pin name for columns, net name for shapes
    x0: int
    y0: int
    x1: int
    y1: int

    def __post_init__(self):
        if not (self.x0 < self.x1 and self.y0 < self.y1):
            raise ValueError(f"degenerate rect {self}")


@dataclass
class Plan:
    rects: List[Rect] = field(default_factory=list)  # new shapes to draw
    bridged: List[Tuple[str, int, int]] = field(default_factory=list)  # (pol, x0, x1)
    skipped: List[Tuple[str, int, int, str]] = field(default_factory=list)  # (pol, x0, x1, reason)


def _x_overlap(a0: int, a1: int, b0: int, b1: int) -> bool:
    return a0 < b1 and b0 < a1


def _merge(intervals: Iterable[Tuple[int, int]]) -> List[Tuple[int, int]]:
    out: List[Tuple[int, int]] = []
    for lo, hi in sorted(intervals):
        if out and lo <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], hi))
        else:
            out.append((lo, hi))
    return out


def plan(
    macro: Tuple[int, int, int, int],
    columns: Sequence[Rect],
    segments: Sequence[Rect],
    names: Dict[str, str],
) -> Plan:
    """macro = (x0, y0, x1, y1) placed bbox; names = {'P': 'VPWR', 'G': 'VGND'}."""
    mx0, my0, mx1, my1 = macro
    p = Plan()
    stripes = sorted({(s.pol, s.x0, s.x1) for s in segments if _x_overlap(s.x0, s.x1, mx0, mx1)})
    for pol, sx0, sx1 in stripes:
        same = [c for c in columns if c.pol == pol and c.x0 <= sx0 and sx1 <= c.x1]
        other = [c for c in columns if c.pol != pol and _x_overlap(c.x0, c.x1, sx0, sx1)]
        partial = [
            c for c in columns
            if c.pol == pol and _x_overlap(c.x0, c.x1, sx0, sx1) and not (c.x0 <= sx0 and sx1 <= c.x1)
        ]
        if other:
            p.skipped.append((pol, sx0, sx1, "overlaps opposite-polarity column"))
            continue
        if partial:
            p.skipped.append((pol, sx0, sx1, "partially overlaps a same-polarity column"))
            continue
        if not same:
            p.skipped.append((pol, sx0, sx1, "not inside any same-polarity column"))
            continue
        segs = [s for s in segments if (s.pol, s.x0, s.x1) == (pol, sx0, sx1)]
        if any(s.y0 < my1 and s.y1 > my0 for s in segs):
            p.skipped.append((pol, sx0, sx1, "tile stripe already crosses the macro (not carved)"))
            continue
        below_top = max((s.y1 for s in segs if s.y1 <= my0), default=None)
        above_bot = min((s.y0 for s in segs if s.y0 >= my1), default=None)
        ivals = [(c.y0, c.y1) for c in same]
        if below_top is not None:
            ivals.append((below_top, my0))
        if above_bot is not None:
            ivals.append((my1, above_bot))
        drawn = 0
        for lo, hi in _merge(i for i in ivals if i[0] < i[1]):
            touches = (below_top is not None and lo <= below_top) or (above_bot is not None and hi >= above_bot)
            if touches:
                p.rects.append(Rect(pol, names[pol], sx0, lo, sx1, hi))
                drawn += 1
        if drawn:
            p.bridged.append((pol, sx0, sx1))
        else:
            p.skipped.append((pol, sx0, sx1, "no tile segment to connect to"))
    return p


def check(
    macro: Tuple[int, int, int, int],
    columns: Sequence[Rect],
    shapes: Sequence[Rect],
) -> List[str]:
    mx0, my0, mx1, my1 = macro
    v: List[str] = []
    for s in shapes:
        ix0, iy0, ix1, iy1 = max(s.x0, mx0), max(s.y0, my0), min(s.x1, mx1), min(s.y1, my1)
        if not (ix0 < ix1 and iy0 < iy1):
            continue
        for c in columns:
            if c.pol != s.pol and _x_overlap(c.x0, c.x1, s.x0, s.x1) and c.y0 < iy1 and iy0 < c.y1:
                v.append(f"C2 {s.name} shape x[{s.x0},{s.x1}] y[{iy0},{iy1}] overlaps {c.name} column x[{c.x0},{c.x1}]")
        cover = _merge(
            (max(c.y0, iy0), min(c.y1, iy1))
            for c in columns
            if c.pol == s.pol and c.x0 <= ix0 and ix1 <= c.x1 and c.y0 < iy1 and iy0 < c.y1
        )
        if cover != [(iy0, iy1)]:
            v.append(
                f"C1 {s.name} shape x[{s.x0},{s.x1}] y[{iy0},{iy1}] inside the macro is not covered by "
                f"same-polarity pin rectangles (covered: {cover})"
            )
    for pin in sorted({c.name for c in columns}):
        cols = [c for c in columns if c.name == pin]
        fed = any(
            s.pol == c.pol and c.x0 <= s.x0 and s.x1 <= c.x1 and s.y0 < c.y1 and c.y0 < s.y1
            for c in cols
            for s in shapes
        )
        if not fed:
            v.append(f"C3 pin {pin} has no same-polarity stripe on any of its {len(cols)} rectangles")
    return v


# --- LEF / placement helpers (pure Python; used by tests and the DEF checker) -----------

def lef_power_rects(lef_text: str, pins: Dict[str, str], layer: str = "Metal4"):
    """[(pol, pin, x0, y0, x1, y1)] in microns, master coordinates. pins = {'VDD!': 'P', ...}."""
    import re

    out = []
    for pin, pol in pins.items():
        m = re.search(r"PIN %s\s*\n(.*?)\n\s*END %s\s" % (re.escape(pin), re.escape(pin)), lef_text, re.S)
        if not m:
            raise KeyError(pin)
        cur = None
        for line in m.group(1).splitlines():
            lm = re.match(r"\s*LAYER\s+(\S+)", line)
            if lm:
                cur = lm.group(1)
            rm = re.match(r"\s*RECT\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)", line)
            if rm and cur == layer:
                out.append((pol, pin, *map(float, rm.groups())))
    return out


def lef_size(lef_text: str) -> Tuple[float, float]:
    import re

    m = re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", lef_text)
    return float(m.group(1)), float(m.group(2))


def place(rects_um, size_um: Tuple[float, float], loc_um: Tuple[float, float], orient: str, dbu: int) -> List[Rect]:
    """Master-coordinate rects -> die-coordinate DBU rects for orientations N and FS
    (DEF semantics: the placed bbox lower-left is at loc)."""
    w, h = size_um
    lx, ly = loc_um
    out = []
    for pol, pin, x0, y0, x1, y1 in rects_um:
        if orient == "N":
            a = (x0, y0, x1, y1)
        elif orient == "FS":  # mirror about the x axis
            a = (x0, h - y1, x1, h - y0)
        else:
            raise ValueError(orient)
        out.append(Rect(pol, pin, *(round((v + o) * dbu) for v, o in zip(a, (lx, ly, lx, ly)))))
    return out


def tile_stripes(core_x0_um, core_x1_um, y0_um, y1_um, vwidth, vspacing, vpitch, voffset, dbu) -> List[Rect]:
    """Model of pdngen stripe placement. Assumption, inferred from Ken Pettit's published numbers
    (offset 6.15 with a 2.88 um left core margin gives VPWR centres at 9.03 + pitch*k) and not
    from pdngen source: VPWR centre at core_x0 + voffset + k*pitch, VGND centre vwidth + vspacing
    to its right. The LibreLane step reads the real stripes, so only the tests depend on this."""
    out = []
    k = 0
    hw = vwidth / 2
    while True:
        pc = core_x0_um + voffset + k * vpitch
        gc = pc + vwidth + vspacing
        if gc + hw > core_x1_um:
            break
        out.append(Rect("P", "VPWR", round((pc - hw) * dbu), round(y0_um * dbu), round((pc + hw) * dbu), round(y1_um * dbu)))
        out.append(Rect("G", "VGND", round((gc - hw) * dbu), round(y0_um * dbu), round((gc + hw) * dbu), round(y1_um * dbu)))
        k += 1
    return out


def carve(stripes: Sequence[Rect], macro: Tuple[int, int, int, int], halo_x: int, halo_y: int) -> List[Rect]:
    """Model of pdngen carving stripes around a macro with a halo (tests only)."""
    mx0, my0, mx1, my1 = macro
    bx0, by0, bx1, by1 = mx0 - halo_x, my0 - halo_y, mx1 + halo_x, my1 + halo_y
    out = []
    for s in stripes:
        if not _x_overlap(s.x0, s.x1, bx0, bx1):
            out.append(s)
            continue
        if s.y0 < by0:
            out.append(Rect(s.pol, s.name, s.x0, s.y0, s.x1, min(s.y1, by0)))
        if s.y1 > by1:
            out.append(Rect(s.pol, s.name, s.x0, max(s.y0, by1), s.x1, s.y1))
    return out
