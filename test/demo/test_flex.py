"""Held-out packages on the virtual demo board (plan step 11, log/flexibility_v2.md).

The firmware runs unmonitored (no package selected: the shipped chip has no monitor slot for these
contracts). Host code uses only the host package (host/pemu, host/pemu/onewire.py) and the
assembled program in host/assets. The device model (test/demo/peers.py) is written from the
datasheet timing, independently of the OCaml Psim peer. Each scenario records the received bytes
and every DQ edge (board cycle) to $DEMO_OUT/flex_<scenario>.json, so the RTL and gate-level runs
can be compared cycle by cycle (compare_verdicts.py style: test/demo/compare_flex.py).
"""
import json
import os
import sys
from pathlib import Path

import cocotb
from cocotb.task import bridge

import peers as pr
from host_port import SimPort
from pemu_host import Board

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "host"))
import pemu  # noqa: E402
from pemu.onewire import OneWire, crc8  # noqa: E402

LIB = pemu.load(str(ROOT / "host" / "assets"))
OUT = Path(os.environ.get("DEMO_OUT", Path(__file__).resolve().parent / "results"))


def record(name, **kw):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"flex_{name}.json").write_text(json.dumps(kw, indent=1, default=str))


async def ow_run(dut, devices, body):
    b = Board(dut)
    rec = pr.LineRecorder()
    b.peers = list(devices) + [rec]
    b.od_mask = 1 << pr.DQ
    await b.start()
    chip = pemu.Pemu(SimPort(b))

    def main():
        chip.check_id()
        ow = OneWire(chip, LIB.program("flex_onewire_ctl"))
        chip.run(1)
        try:
            r = body(ow)
        except RuntimeError as e:
            r = ("error", str(e), chip.fifo_status(0), chip.read(0x01, 1))
        return r, chip.verdict()

    r, v = await bridge(main)()
    edges = [(c - b.release, x) for c, x in rec.edges]
    return r, v, edges


def unmonitored_clean(v):
    return not v["fail"] and not v["blame"]


@cocotb.test()
async def ow_read_rom(dut):
    dev = pr.OneWireDevice()

    def body(ow):
        present = ow.reset()
        ow.write([0x33])
        return present, ow.read(8)

    (present, rom), v, edges = await ow_run(dut, [dev], body)
    record("ow_read_rom", present=present, rom=rom, device=dev.log, verdict=v, edges=edges)
    assert present and rom == dev.rom and crc8(rom[:7]) == rom[7], (present, rom)
    assert unmonitored_clean(v), v


@cocotb.test()
async def ow_scratchpad(dut):
    dev = pr.OneWireDevice()

    def body(ow):
        p1 = ow.reset()
        ow.write([0xCC, 0x4E, 0x55, 0x0A, 0x3F])
        p2 = ow.reset()
        ow.write([0xCC, 0xBE])
        return p1, p2, ow.read(9)

    r, v, edges = await ow_run(dut, [dev], body)
    if r[0] == "error":
        record("ow_scratchpad", error=r, device=dev.log, verdict=v, edges=edges)
        assert False, r
    p1, p2, sp = r
    record("ow_scratchpad", present=[p1, p2], scratch=sp, device=dev.log, verdict=v, edges=edges)
    expect = [0x91, 0x01, 0x55, 0x0A, 0x3F, 0xFF, 0x0F, 0x10]
    assert p1 and p2 and sp == expect + [crc8(expect)], (p1, p2, sp)
    assert unmonitored_clean(v), v


@cocotb.test()
async def ow_no_device(dut):
    def body(ow):
        return ow.reset()

    present, v, edges = await ow_run(dut, [], body)
    record("ow_no_device", present=present, verdict=v, edges=edges)
    assert present is False, present
