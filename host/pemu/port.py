"""Host port transports (doc/host.md section 2).

A port has two methods:
  xfer(data)    one SPI transaction (CS low for its duration), data = list of byte ints, returns
                the bytes read back (same length);
  sleep_us(us)  wait.
The chip's host port is SPI mode 0 on ui_in[2:0] (CS_n, SCK, MOSI) with MISO on uo_out[0]
(doc/interface_v1.md section 4): MSB first, MISO sampled before each rising SCK edge, SCK half
period at least 4 chip clock cycles.

BitBangPort runs on MicroPython (RP2350 or any board) with machine.Pin objects for the four
signals. Which RP2350 GPIOs reach ui_in[2:0] / uo_out[0] depends on the demo board; the pin
numbers are the caller's (doc/host.md section 2.1).
"""

import time

try:
    _sleep_us = time.sleep_us  # MicroPython
except AttributeError:  # CPython (tests, tools)

    def _sleep_us(us):
        time.sleep(us / 1e6)


class BitBangPort:
    """SPI mode 0 by GPIO. half_period_us = 0 runs as fast as the interpreter allows (a few
    microseconds per edge on an RP2350 under MicroPython, far above the 4-cycle minimum)."""

    def __init__(self, cs_n, sck, mosi, miso, half_period_us=0):
        self.cs_n, self.sck, self.mosi, self.miso = cs_n, sck, mosi, miso
        self.hp = half_period_us
        cs_n.value(1)
        sck.value(0)
        mosi.value(0)

    def _byte(self, v):
        r = 0
        for k in range(7, -1, -1):
            self.mosi.value((v >> k) & 1)
            if self.hp:
                _sleep_us(self.hp)
            r = (r << 1) | (self.miso.value() & 1)
            self.sck.value(1)
            if self.hp:
                _sleep_us(self.hp)
            self.sck.value(0)
        return r

    def xfer(self, data):
        self.cs_n.value(0)
        out = [self._byte(v) for v in data]
        self.cs_n.value(1)
        return out

    def sleep_us(self, us):
        _sleep_us(us)
