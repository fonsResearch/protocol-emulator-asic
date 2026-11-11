# MicroPython check of the host package (doc/host.md section 5.2). Run with the unix port:
#   micropython host/tools/upy_check.py            (from the repository root)
# Imports pemu under MicroPython and drives BitBangPort through fake Pin objects wired to a small
# SPI target model: a register file with the chip's framing (first byte = address, bit 7 = read;
# MISO valid before each rising SCK edge). This checks that the package parses and runs on
# MicroPython and that the bit-bang framing is right. It is not a model of the chip: the chip is
# exercised by test/demo/test_host_pkg.py.
import sys

sys.path.insert(0, "host")
import pemu  # noqa: E402


class Target:
    def __init__(self):
        self.regs = bytearray(256)
        self.regs[0x00] = 0xA1
        self.writes = []
        self.cs = 1
        self.miso = 0

    def cs_edge(self, v):
        self.cs = v
        if v == 0:
            self.nbit, self.shift, self.nbyte, self.addr, self.read, self.out = 0, 0, 0, 0, False, 0
            self.miso = 0

    def rise(self, mosi):
        if self.cs:
            return
        self.shift = ((self.shift << 1) | mosi) & 0xFF
        self.nbit += 1
        if self.nbit == 8:
            b, self.nbit = self.shift, 0
            if self.nbyte == 0:
                self.read, self.addr = bool(b & 0x80), b & 0x7F
            elif not self.read:
                self.writes.append((self.addr, b))
            self.nbyte += 1
            # next byte out: register value for reads (address auto-advance not modelled)
            self.out = self.regs[self.addr] if self.read else 0

    def fall(self):
        if self.cs:
            return
        self.miso = (self.out >> (7 - self.nbit)) & 1


class Pin:
    def __init__(self, t, role):
        self.t, self.role, self.v = t, role, 0

    def value(self, v=None):
        if v is None:
            return self.t.miso if self.role == "miso" else self.v
        old, self.v = self.v, v
        if self.role == "cs" and old != v:
            self.t.cs_edge(v)
        if self.role == "sck" and not old and v:
            self.t.rise(self.t.mosi_pin.v)
        if self.role == "sck" and old and not v:
            self.t.fall()


t = Target()
cs, sck, mosi, miso = Pin(t, "cs"), Pin(t, "sck"), Pin(t, "mosi"), Pin(t, "miso")
t.mosi_pin = mosi
chip = pemu.Pemu(pemu.BitBangPort(cs, sck, mosi, miso))
chip.check_id()
t.regs[0x1B] = 0x30  # FIFO_ST of lane 0: rx level 3
prog = {"words": [0x2001, 0x3001, 0xB004, 0x0002], "own": 1, "od": 0, "cfg": 0, "cfg2": 0}
pkg = {"index": 0, "name": "x", "p": 64, "remap": [16] * 16, "windows": [0] * 8}
chip.setup_lane(0, prog, pkg)
chip.tx_push(0, [0x48, 0x69])
chip.run(1)
level = chip.rx_level(0)
t.regs[0x1B] = 0x80  # rx level 8 on a running lane: the guard must flag it
chip.wait_us(10, poll_us=5)
v = chip.verdict()
ok = (
    level == 3
    and (0x10, 1) in t.writes  # own
    and (0x19, 0x48) in t.writes and (0x19, 0x69) in t.writes  # TX FIFO bytes
    and (0x50, 0x80) in t.writes  # package select, enable bit
    and (0x01, 1) in t.writes  # RUN lane 0
    and not v["host_valid"] and v["host_faults"][0][1] == "rx_full"
)
print("micropython", sys.implementation.name, sys.version, "pemu check:", "ok" if ok else "FAILED")
print("writes", len(t.writes), "rx level", level, "host_valid", v["host_valid"])
sys.exit(0 if ok else 1)
