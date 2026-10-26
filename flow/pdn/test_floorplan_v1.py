# SPDX-License-Identifier: MIT
"""Floorplan C of core v1 (user decision 2026-10-19) against macro_stripes_geom, on the real
RM_IHPSG13_1P_256x16_c2_bm_bist LEF: three macros on the 8x4 tile, the PDN_OBSTRUCTIONS and
placements of src/config.json, and the per-instance loop of odb_macro_stripes.main emulated
(plan, replace carved segments by one full-height stripe, check), in every processing order.
The stripe model (tile_stripes, carve) is an assumption about pdngen; the step re-checks the
real shapes in the flow.

Run: python -m pytest flow/pdn/test_floorplan_v1.py
"""
import itertools
import json
import os
import re
from pathlib import Path

import pytest

import macro_stripes_geom as G

ROOT = Path(__file__).resolve().parents[2]
LEF = Path(os.environ.get(
    "PEMU_SRAM256_LEF",
    ROOT / ".toolchain/pdk/ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram/lef/RM_IHPSG13_1P_256x16_c2_bm_bist.lef",
))
PINS = {"VDD!": "P", "VDDARRAY!": "P", "VSS!": "G"}
NAMES = {"P": "VPWR", "G": "VGND"}
DBU = 1000
DIE_UM = tuple(float(v) for v in os.environ.get("PEMU_DIE_UM", "1724.16,710.64").split(","))
CORE_X0, CORE_X1 = 2.88, DIE_UM[0] - 2.88
CORE_Y0, CORE_Y1 = 3.78, DIE_UM[1] - 3.78
DIE = (0, 0, round(DIE_UM[0] * DBU), round(DIE_UM[1] * DBU))


def config():
    text = Path(os.environ.get("PEMU_FP_CONFIG", ROOT / "src/config.json")).read_text()
    return json.loads(text)


def obstructions(cfg):
    out = []
    for o in cfg["PDN_OBSTRUCTIONS"]:
        _, x0, _, x1, _ = o.split()
        out.append((float(x0), float(x1)))
    return out


def grid(cfg):
    return dict(vwidth=cfg["FP_PDN_VWIDTH"], vspacing=cfg["FP_PDN_VSPACING"],
                vpitch=cfg["FP_PDN_VPITCH"], voffset=cfg["FP_PDN_VOFFSET"])


def placements(cfg):
    m = cfg["MACROS"]["RM_IHPSG13_1P_256x16_c2_bm_bist"]["instances"]
    return {k: (tuple(v["location"]), v["orientation"]) for k, v in m.items()}


def halo(cfg):
    return round(cfg["FP_MACRO_HORIZONTAL_HALO"] * DBU), round(cfg["FP_MACRO_VERTICAL_HALO"] * DBU)


def macros(cfg, shift=None):
    text = LEF.read_text()
    size = G.lef_size(text)
    out = {}
    for name, (loc, orient) in placements(cfg).items():
        if shift and name == shift[0]:
            loc = (loc[0] + shift[1], loc[1])
        cols = G.place(G.lef_power_rects(text, PINS), size, loc, orient, DBU)
        bb = tuple(round(v * DBU) for v in (loc[0], loc[1], loc[0] + size[0], loc[1] + size[1]))
        out[name] = (bb, cols)
    return out


def tile(cfg, use_obstructions=True):
    s = G.tile_stripes(CORE_X0, CORE_X1, CORE_Y0, CORE_Y1, dbu=DBU, **grid(cfg))
    if use_obstructions:
        obs = obstructions(cfg)
        s = [r for r in s if not any(a * DBU <= r.x0 and r.x1 <= b * DBU for a, b in obs)]
    return s


def carve_all(stripes, ms, hx, hy):
    segs = stripes
    for bb, _ in ms.values():
        segs = G.carve(segs, bb, hx, hy)
    return segs


def run_flow(ms, segs, order):
    """odb_macro_stripes.main: per instance plan -> replace -> check; then C4 on the pin boxes."""
    segs = list(segs)
    report = {}
    for name in order:
        bb, cols = ms[name]
        p = G.plan(bb, cols, segs, NAMES, full_span=True, cross_gaps=True)
        for pol, x0, x1, y0, y1 in p.replace:
            segs = [s for s in segs if (s.pol, s.x0, s.x1) != (pol, x0, x1)]
            segs.append(G.Rect(pol, NAMES[pol], x0, y0, x1, y1))
        report[name] = (p, G.check(bb, cols, segs, allow_pin_gaps=True))
    c4 = G.check_pins(segs, DIE, DBU)
    return report, segs, c4


needs_lef = pytest.mark.skipif(not LEF.exists(), reason="256x16 LEF not fetched (tools/fetch_pdk.sh)")

# Instance names come from the config under test (PEMU_FP_CONFIG), so the same checks cover the
# v1 8x4 floorplan C and the v2 6x4 probes.
INSTANCES = sorted(placements(config()))


@needs_lef
@pytest.mark.parametrize("order", list(itertools.permutations(INSTANCES)))
def test_floorplan_c_passes_c1_c4_in_any_order(order):
    cfg = config()
    ms = macros(cfg)
    hx, hy = halo(cfg)
    report, segs, c4 = run_flow(ms, carve_all(tile(cfg), ms, hx, hy), order)
    for name, (p, viol) in report.items():
        assert viol == [], (name, viol)
    assert c4 == []
    # every macro is fed by exactly 2 VPWR and 2 VGND full-height stripes crossing it
    for name, (bb, cols) in ms.items():
        over = [s for s in segs if s.x0 < bb[2] and bb[0] < s.x1 and s.y0 < bb[3] and bb[1] < s.y1]
        assert sorted(s.pol for s in over) == ["G", "G", "P", "P"], name
        assert all((s.y0, s.y1) == (round(CORE_Y0 * DBU), round(CORE_Y1 * DBU)) for s in over)


@needs_lef
def test_obstructions_are_exactly_the_misaligned_pairs():
    cfg = config()
    ms = macros(cfg)
    for name, (bb, cols) in ms.items():
        over = [s for s in tile(cfg) if s.x0 < bb[2] and bb[0] < s.x1]
        assert len(over) == 4, (name, [(s.pol, s.x0) for s in over])
    # no obstruction removes a stripe that crosses no macro
    full = G.tile_stripes(CORE_X0, CORE_X1, CORE_Y0, CORE_Y1, dbu=DBU, **grid(cfg))
    removed = [s for s in full if s not in tile(cfg)]
    assert all(any(s.x0 < bb[2] and bb[0] < s.x1 for bb, _ in ms.values()) for s in removed)
    assert len(removed) == 2 * len(obstructions(cfg))  # one pair per obstruction


@needs_lef
def test_neg_macro_shifted_one_site_fails():
    cfg = config()
    ms = macros(cfg, shift=("core.u_imem_l1", 0.48))
    hx, hy = halo(cfg)
    report, _, c4 = run_flow(ms, carve_all(tile(cfg), ms, hx, hy), INSTANCES)
    bad = [v for _, (_, v) in report.items() if v]
    assert bad or c4


@needs_lef
def test_neg_without_obstructions_fails_c4():
    cfg = config()
    ms = macros(cfg)
    hx, hy = halo(cfg)
    _, _, c4 = run_flow(ms, carve_all(tile(cfg, use_obstructions=False), ms, hx, hy),
                        INSTANCES)
    assert len(c4) > 0


@needs_lef
def test_no_narrow_channel_to_core_edge():
    """CI run 1 (v1-tt 177fdd0): with an 8.5 um gap between the lane-0 macro and the right core
    edge, pdngen drew a 1.05 um VGND strap there that failed C4. Every macro-to-core-edge gap must
    be at most one site (0.48 um) or at least one stripe pitch, so that a full pair fits."""
    cfg = config()
    pitch = cfg["FP_PDN_VPITCH"] * DBU
    for name, (bb, _) in macros(cfg).items():
        for g in (bb[0] - round(CORE_X0 * DBU), round(CORE_X1 * DBU) - bb[2]):
            assert g <= 480 or g >= pitch, (name, g)
