# SPDX-License-Identifier: MIT
"""Unit tests for macro_stripes_geom on the real RM_IHPSG13_1P_64x16_c2 LEF.

Run: PEMU_SRAM_LEF=<path to LEF> python -m pytest flow/pdn/test_macro_stripes.py
(default path: .toolchain/pdk/... from tools/fetch_pdk.sh). The stripe model (tile_stripes,
carve) is an assumption about pdngen; the real check runs in the flow on real shapes.
"""
import os
from pathlib import Path

import pytest

import macro_stripes_geom as G

ROOT = Path(__file__).resolve().parents[2]
LEF = Path(os.environ.get(
    "PEMU_SRAM_LEF",
    ROOT / ".toolchain/pdk/ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram/lef/RM_IHPSG13_1P_64x16_c2.lef",
))
PINS = {"VDD!": "P", "VDDARRAY!": "P", "VSS!": "G"}
NAMES = {"P": "VPWR", "G": "VGND"}
DBU = 1000
# src/config.json values on branch core-macro (6x4 tile)
CORE_X0, CORE_X1 = 2.88, 1289.28 - 2.88
CORE_Y0, CORE_Y1 = 3.78, 710.64 - 3.78
GRID = dict(vwidth=2.1, vspacing=3.52, vpitch=44.96, voffset=6.15)
LOC, ORIENT = (3.36, 321.30), "N"
HALO = (2.0, 0.48)


def setup(loc=LOC, orient=ORIENT):
    text = LEF.read_text()
    size = G.lef_size(text)
    cols = G.place(G.lef_power_rects(text, PINS), size, loc, orient, DBU)
    macro = tuple(round(v * DBU) for v in (loc[0], loc[1], loc[0] + size[0], loc[1] + size[1]))
    stripes = G.tile_stripes(CORE_X0, CORE_X1, CORE_Y0, CORE_Y1, dbu=DBU, **GRID)
    return cols, macro, stripes


def carved(stripes, macro):
    return G.carve(stripes, macro, round(HALO[0] * DBU), round(HALO[1] * DBU))


@pytest.mark.skipif(not LEF.exists(), reason="PDK LEF not fetched (tools/fetch_pdk.sh)")
class TestReal64x16:
    def test_lef_columns(self):
        cols, _, _ = setup()
        n = {p: sum(c.name == p for c in cols) for p in PINS}
        assert n == {"VDD!": 20, "VDDARRAY!": 16, "VSS!": 20}

    def test_plan_bridges_exactly_the_aligned_left_array_pairs(self):
        cols, macro, stripes = setup()
        p = G.plan(macro, cols, carved(stripes, macro), NAMES)
        # VPWR centres 9.03 and 53.99, VGND 14.65 and 59.61 (left array); all others skipped
        assert sorted(((x0 + x1) / 2 / DBU, pol) for pol, x0, x1 in p.bridged) == [
            (9.03, "P"), (14.65, "G"), (53.99, "P"), (59.61, "G")]
        assert len(p.skipped) == 2 * 6 - 4  # 6 pairs cross the 236.8 um macro; 4 stripes bridged

    def test_vdd_bridge_avoids_obs_bar(self):
        cols, macro, stripes = setup()
        p = G.plan(macro, cols, carved(stripes, macro), NAMES)
        ys = sorted((r.y0 - macro[1], r.y1 - macro[1]) for r in p.rects if r.pol == "P" and r.x0 < 11000)
        # two pieces: up to the top of VDD! (38.825) and from the bottom of VDDARRAY! (45.465)
        assert len(ys) == 2 and ys[0][1] == 38825 and ys[1][0] == 45465

    def test_check_passes_after_plan(self):
        cols, macro, stripes = setup()
        segs = carved(stripes, macro)
        p = G.plan(macro, cols, segs, NAMES)
        assert G.check(macro, cols, segs + p.rects) == []

    # --- negative controls: each must produce a violation ---------------------------

    def test_neg_unpowered_macro_fails_c3(self):
        cols, macro, stripes = setup()
        v = G.check(macro, cols, carved(stripes, macro))
        assert {x.split()[2] for x in v if x.startswith("C3")} == set(PINS)

    def test_neg_misplaced_macro_gets_no_bridge(self):
        cols, macro, stripes = setup(loc=(LOC[0] + 0.48, LOC[1]))  # one site to the right
        segs = carved(stripes, macro)
        p = G.plan(macro, cols, segs, NAMES)
        # one VGND stripe happens to fall inside a middle-band VSS column; no VPWR stripe fits
        assert [b for b in p.bridged if b[0] == "P"] == []
        c3 = {x.split()[2] for x in G.check(macro, cols, segs + p.rects) if x.startswith("C3")}
        assert c3 == {"VDD!", "VDDARRAY!"}

    def test_neg_full_height_stripe_over_bar_fails_c1(self):
        cols, macro, stripes = setup()
        segs = carved(stripes, macro)
        p = G.plan(macro, cols, segs, NAMES)
        vdd = next(r for r in p.rects if r.pol == "P")
        bad = G.Rect("P", "VPWR", vdd.x0, macro[1], vdd.x1, macro[3])
        assert any(x.startswith("C1") for x in G.check(macro, cols, segs + p.rects + [bad]))

    def test_neg_wrong_polarity_fails_c2(self):
        cols, macro, stripes = setup()
        segs = carved(stripes, macro)
        p = G.plan(macro, cols, segs, NAMES)
        vss = next(r for r in p.rects if r.pol == "G")
        bad = G.Rect("P", "VPWR", vss.x0, vss.y0, vss.x1, vss.y1)
        assert any(x.startswith("C2") for x in G.check(macro, cols, segs + p.rects + [bad]))

    def test_neg_uncarved_grid_is_flagged(self):
        cols, macro, stripes = setup()
        p = G.plan(macro, cols, stripes, NAMES)
        assert p.rects == [] and all("already crosses" in s[3] or "column" in s[3] for s in p.skipped)
        v = G.check(macro, cols, stripes)
        assert any(x.startswith("C1") for x in v) or any(x.startswith("C2") for x in v)


def test_fs_orientation_mirrors_rows():
    rects = [("P", "VDD!", 0.0, 0.0, 1.0, 2.0)]
    (r,) = G.place(rects, (10.0, 5.0), (1.0, 1.0), "FS", 1000)
    assert (r.y0, r.y1) == (4000, 6000)


# --- DEF round trip for check_macro_stripes_def.py ------------------------------------------

def _def_text(macro, shapes, master="RM_IHPSG13_1P_64x16_c2", orient="N"):
    def path(s):
        cx, w = (s.x0 + s.x1) // 2, s.x1 - s.x0
        return f"NEW Metal4 {w} + SHAPE STRIPE ( {cx} {s.y0} ) ( * {s.y1} )"
    nets = []
    for net in ("VPWR", "VGND"):
        ws = [path(s) for s in shapes if s.name == net]
        ws[0] = ws[0].replace("NEW", "+ ROUTED", 1)
        nets.append(f"- {net} ( * VPWR ) + USE POWER\n  " + "\n  ".join(ws) + " ;")
    return (f"VERSION 5.8 ;\nUNITS DISTANCE MICRONS {DBU} ;\nCOMPONENTS 1 ;\n"
            f"- core.u_imem {master} + FIXED ( {macro[0]} {macro[1]} ) {orient} ;\nEND COMPONENTS\n"
            f"SPECIALNETS 2 ;\n" + "\n".join(nets) + "\nEND SPECIALNETS\nEND DESIGN\n")


@pytest.mark.skipif(not LEF.exists(), reason="PDK LEF not fetched (tools/fetch_pdk.sh)")
class TestDefChecker:
    def run(self, tmp_path, shapes, macro):
        import subprocess, sys
        d = tmp_path / "t.def"
        d.write_text(_def_text(macro, shapes))
        r = subprocess.run([sys.executable, str(Path(__file__).with_name("check_macro_stripes_def.py")), str(d), str(LEF)],
                           capture_output=True, text=True)
        return r.returncode, r.stdout

    def test_def_pass(self, tmp_path):
        cols, macro, stripes = setup()
        segs = carved(stripes, macro)
        p = G.plan(macro, cols, segs, NAMES)
        rc, out = self.run(tmp_path, segs + p.rects, macro)
        assert rc == 0, out
        assert "pins fed: ['VDD!', 'VDDARRAY!', 'VSS!']" in out

    def test_def_neg_unpowered(self, tmp_path):
        cols, macro, stripes = setup()
        rc, out = self.run(tmp_path, carved(stripes, macro), macro)
        assert rc == 1 and "C3" in out

    def test_def_neg_stripe_over_bar(self, tmp_path):
        cols, macro, stripes = setup()
        segs = carved(stripes, macro)
        p = G.plan(macro, cols, segs, NAMES)
        vdd = next(r for r in p.rects if r.pol == "P")
        bad = G.Rect("P", "VPWR", vdd.x0, macro[1], vdd.x1, macro[3])
        rc, out = self.run(tmp_path, segs + p.rects + [bad], macro)
        assert rc == 1 and "C1" in out
