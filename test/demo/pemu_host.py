"""Virtual demo board (plan step 8): the chip (RTL or gate-level netlist) on a simulated board.

Board: a per-cycle loop that resolves the uio pads from the chip's drive and the attached device
models (open-drain pins are wired-AND, undriven pins are pulled up) and bit-bangs the host SPI port
on ui_in[2:0] (CS_n, SCK, MOSI; MISO on uo_out[0]).

Pemu: the host API. Method names and arguments are the ones the RP2350 MicroPython host package
(plan step 10) uses; here they are coroutines driving the simulated SPI port. Register map:
doc/interface_v1.md section 5 and doc/contracts/monitor_isa_v1.md section 8. Firmware images and
package tables come from the toolchain (test/demo/assets.json, rtl_v1/bin/export_demo_assets.ml).
"""
import json
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

ASSETS = json.loads((Path(__file__).resolve().parent / "assets.json").read_text())
CLOCK_NS = 33  # 30 MHz nominal; functional simulation is period-independent


class Board:
    def __init__(self, dut, od_mask=0x0C):
        self.dut = dut
        self.peers = []
        self.od_mask = od_mask  # I2C pins (uio2, uio3) are open drain on the board
        self.cycle = 0
        self.release = None  # cycle at which rst_n was released
        self.cs_n, self.sck, self.mosi = 1, 0, 0
        self.out = self.oe = self.uo = 0
        self.pad = 0xFF
        self.trace = []  # optional (cycle, pad) log for decoders

    async def start(self):
        d = self.dut
        d.ena.value = 1
        d.rst_n.value = 0
        d.ui_in.value = 1
        d.uio_in.value = 0xFF
        Clock(d.clk, CLOCK_NS, unit="ns").start(start_high=False)
        cocotb.start_soon(self._loop())
        await ClockCycles(d.clk, 10)
        d.rst_n.value = 1
        self.release = self.cycle
        await ClockCycles(d.clk, 10)

    def _resolve(self, drives):
        pad = 0
        for b in range(8):
            m = 1 << b
            chip_low = (self.oe & m) and not (self.out & m)
            chip_high = (self.oe & m) and (self.out & m)
            peer_low = any((oe & m) and not (val & m) for oe, val in drives)
            peer_high = any((oe & m) and (val & m) for oe, val in drives)
            if self.od_mask & m:
                v = 0 if (chip_low or peer_low) else 1
            elif self.oe & m:
                v = 1 if chip_high else 0
            elif peer_low or peer_high:
                v = 1 if peer_high and not peer_low else 0
            else:
                v = 1
            pad |= v << b
        return pad

    async def _loop(self):
        d = self.dut
        while True:
            await FallingEdge(d.clk)
            try:
                self.out = d.uio_out.value.to_unsigned()
                self.oe = d.uio_oe.value.to_unsigned()
                self.uo = d.uo_out.value.to_unsigned()
            except ValueError:  # X before the first reset edge
                self.out = self.oe = self.uo = 0
            drives = [p.step(self.cycle, self.out, self.oe, self.pad) for p in self.peers]
            self.pad = self._resolve(drives)
            d.uio_in.value = self.pad
            d.ui_in.value = self.cs_n | (self.sck << 1) | (self.mosi << 2)
            self.cycle += 1

    async def wait(self, n):
        await ClockCycles(self.dut.clk, n, rising=False)

    def now(self):
        """cycles since reset release (board time)"""
        return self.cycle - self.release


class Pemu:
    """Host API (SPI mode 0, SCK half period HP cycles >= 4 as interface_v1.md section 4 requires)."""

    HP = 6

    def __init__(self, board):
        self.b = board

    # ---- port level ----
    async def _byte(self, v):
        r = 0
        for k in range(7, -1, -1):
            self.b.mosi = (v >> k) & 1
            await self.b.wait(self.HP)
            r = (r << 1) | (self.b.uo & 1)
            self.b.sck = 1
            await self.b.wait(self.HP)
            self.b.sck = 0
        return r

    async def _xfer(self, data):
        self.b.cs_n = 0
        await self.b.wait(6)
        out = [await self._byte(v) for v in data]
        await self.b.wait(6)
        self.b.cs_n = 1
        await self.b.wait(8)
        return out

    async def write(self, addr, data):
        await self._xfer([addr & 0x7F] + list(data))

    async def read(self, addr, n=1):
        return (await self._xfer([0x80 | addr] + [0] * n))[1:]

    # ---- device level ----
    async def id(self):
        return (await self.read(0x00))[0]

    async def lane_config(self, lane, own, od=0, p=7, cfg=0, cfg2=0):
        b = 0x10 + 16 * lane
        await self.write(b + 0, [own])
        await self.write(b + 1, [od])
        await self.write(b + 2, [p & 0xFF, p >> 8])
        await self.write(b + 5, [cfg])
        await self.write(b + 6, [cfg2])

    async def load_program(self, lane, words):
        b = 0x10 + 16 * lane
        await self.write(b + 4, [len(words)])
        await self.write(b + 7, [0])
        data = []
        for w in words:
            data += [w & 0xFF, w >> 8]
        await self.write(b + 8, data)

    async def setup_lane(self, lane, program, package, p=None):
        """configure a lane from toolchain assets: firmware image + ROM package (index or name)"""
        prog = ASSETS["programs"][program]
        pkg = package_by(package)
        await self.lane_config(lane, prog["own"], prog["od"], pkg["p"] if p is None else p, prog["cfg"], prog["cfg2"])
        await self.load_program(lane, prog["words"])
        await self.select_package(lane, pkg["index"], pkg["remap"])

    async def select_package(self, lane, index, remap):
        await self.write(0x50 + 8 * lane, [0x80 | index])
        await self.write(0x60 + 16 * lane, list(remap))

    async def load_windows(self, lane, windows):
        b = 0x50 + 8 * lane
        for k in range(1, 8):
            await self.write(b + 3, [k])
            await self.write(b + 6, [windows[k] & 0xFF])
            await self.write(b + 7, [windows[k] >> 8])
        await self.write(b + 3, [0x80])

    async def tx_push(self, lane, data):
        await self.write(0x10 + 16 * lane + 9, list(data))

    async def rx_level(self, lane):
        return ((await self.read(0x10 + 16 * lane + 11))[0] >> 4) & 0xF

    async def rx_pop(self, lane):
        n = await self.rx_level(lane)
        return await self.read(0x10 + 16 * lane + 10, n) if n else []

    async def run(self, lanes):
        await self.write(0x01, [lanes & 3])

    async def status(self):
        return (await self.read(0x02))[0]

    async def fault(self):
        return (await self.read(0x03))[0]

    async def verdict(self):
        v = await self.read(0x40, 12)
        le = lambda a: v[a] | (v[a + 1] << 8) | (v[a + 2] << 16) | (v[a + 3] << 24)
        return {
            "fail": bool(v[0] & 1), "blame": bool(v[0] & 2),
            "blame_lane": (v[0] >> 2) & 1, "fail_lane": (v[0] >> 3) & 1,
            "overrun": (v[0] >> 4) & 3, "fail_code": v[1], "blame_code": v[2],
            "fail_unit": v[3] & 7, "blame_unit": (v[3] >> 4) & 7,
            "fail_time": le(4), "blame_time": le(8), "raw": v,
        }

    async def clear_verdict(self, lanes_running=0):
        await self.write(0x01, [(lanes_running & 3) | 0x10])


def package_by(key):
    for p in ASSETS["packages"]:
        if p["index"] == key or p["name"] == key:
            return p
    raise KeyError(key)
