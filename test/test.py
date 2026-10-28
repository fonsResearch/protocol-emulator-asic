# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0
#
# Pin-level trace replay through the tt_um_* wrapper, shared by RTL and gate-level runs
# (make / make GATES=yes). Vectors come from the spec interpreter via
# rtl/bin/dump_tt_vectors.exe (see test/vectors/README.md); this file holds no reference
# model of its own.
#
# Timing convention (matches doc/isa/isa_v0.md section 1 and the exporter):
#   cycle c runs from rising edge e_c to e_{c+1}. At the falling edge inside cycle c the
#   outputs (registered, Moore) are sampled and compared with row c, then the inputs of
#   row c are driven; they are sampled by the core at e_{c+1}.
#   Cycle 0 is exempt: the core uses a synchronous clear, so before the first edge with
#   reset asserted its registers (and pins) are undefined, as in rtl/macro_sim/tb_vectors.v.
#   Every later cycle must match exactly; X/Z on any output pin is a mismatch.

from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

VEC_DIR = Path(__file__).resolve().parent / "vectors"
SCENARIOS = sorted(p.stem for p in [*VEC_DIR.glob("v1_*.vec"), *VEC_DIR.glob("v2_*.vec")])  # core v1/v2 (rtl_v1/bin/dump_tt_vectors_v1.ml)
CLOCK_NS = 20  # functional replay is period-independent (no timing in RTL/GL sim); config CLOCK_PERIOD is 16.67


def load(name):
    rows = []
    for line in (VEC_DIR / f"{name}.vec").read_text().splitlines():
        f = [int(x, 16) for x in line.split()]
        rows.append((f[0], f[1], f[2], (f[3], f[4], f[5])))
    return rows


def sample(dut):
    vals = (dut.uio_oe.value, dut.uio_out.value, dut.uo_out.value)
    if not all(v.is_resolvable for v in vals):
        return tuple(str(v) for v in vals)  # keeps X/Z visible in the report
    return tuple(v.to_unsigned() for v in vals)


def mismatches(observed, rows):
    """Cycles (excluding 0) where the observed (uio_oe, uio_out, uo_out) differs from expected."""
    return [
        (c, got, rows[c][3])
        for c, got in enumerate(observed)
        if c > 0 and got != rows[c][3]
    ]


async def replay(dut, rows):
    dut.ena.value = 1
    rst_n, ui, uio, _ = rows[0]
    dut.rst_n.value, dut.ui_in.value, dut.uio_in.value = rst_n, ui, uio
    Clock(dut.clk, CLOCK_NS, unit="ns").start(start_high=False)
    await RisingEdge(dut.clk)  # e_0
    observed = []
    for rst_n, ui, uio, _ in rows:
        await FallingEdge(dut.clk)
        observed.append(sample(dut))
        dut.rst_n.value, dut.ui_in.value, dut.uio_in.value = rst_n, ui, uio
    await RisingEdge(dut.clk)
    return observed


def report(dut, name, bad, n):
    for c, got, exp in bad[:5]:
        dut._log.error(f"{name}: cycle {c}: got (oe,uio,uo)={got} expected {exp}")
    dut._log.info(f"{name}: cycles={n} mismatches={len(bad)}")


@cocotb.test()
@cocotb.parametrize(scenario=SCENARIOS)
async def replay_spec_trace(dut, scenario):
    rows = load(scenario)
    observed = await replay(dut, rows)
    bad = mismatches(observed, rows)
    report(dut, scenario, bad, len(rows))
    assert not bad, f"{scenario}: {len(bad)} mismatching cycles, first at {bad[0][0]}"


@cocotb.test()
async def comparator_negative_control(dut):
    """Replays v1_rom_uart, then checks the comparator flags exactly one injected bit flip.

    Guards against a harness that cannot fail (e.g. sampling the wrong signals or
    comparing a list with itself). It does not replace a mutated-DUT check."""
    rows = load("v1_rom_uart")
    observed = await replay(dut, rows)
    assert not mismatches(observed, rows), "clean replay must match before the control"
    c = max(i for i, r in enumerate(rows) if r[3][2] & 1)  # last cycle with uo_out[0] = 1
    oe, uio, uo = rows[c][3]
    corrupted = rows[:c] + [rows[c][:3] + ((oe, uio, uo ^ 1),)] + rows[c + 1 :]
    bad = mismatches(observed, corrupted)
    assert [b[0] for b in bad] == [c], f"expected exactly one mismatch at cycle {c}, got {bad[:3]}"
    dut._log.info(f"negative control: injected flip at cycle {c} detected, no other mismatch")
