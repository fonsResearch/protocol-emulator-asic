"""Simulator port for the host package (host/pemu): the package's blocking calls drive the
virtual demo board through cocotb.task.resume, so the package code runs unchanged (it is only
given this port instead of pemu.BitBangPort).

xfer: the same SPI mode-0 waveform as test/demo/pemu_host.py (SCK half period HP = 6 cycles,
CS setup 6, hold 6, gap 8). sleep_us: 30 cycles per microsecond (30 MHz chip clock).
"""
from cocotb.task import resume

CYCLES_PER_US = 30


class SimPort:
    HP = 6

    def __init__(self, board):
        self.b = board
        self.xfer = resume(self._xfer)
        self._sleep = resume(self._wait)

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

    async def _wait(self, n):
        if n > 0:
            await self.b.wait(n)

    def sleep_us(self, us):
        self._sleep(int(round(us * CYCLES_PER_US)))
