"""1-Wire controller on a lane (held-out package, doc/protocols/onewire_v1.md).

Firmware flex_onewire_ctl (flex_v2/firmware/onewire_ctl.s), unmonitored: the shipped chip has no
monitor slot for this contract. Host TX framing: 0 = reset (the lane pushes the presence sample,
bit 7 = 0 when a device answered), 1 b = write byte b, 2 = read a byte (pushed).
P = 29 at 30 MHz (one step = 1 us). Reads go through Pemu.transfer in chunks of 7, so the RX FIFO
never fills. Every push first waits for TX room: a write to a full TX FIFO is dropped.
"""

P_30MHZ = 29
TX_DEPTH = 8


class OneWire:
    def __init__(self, chip, program, lane=0, p=P_30MHZ):
        self.chip, self.lane = chip, lane
        chip.setup_lane(lane, program, None, p=p)

    def _wait_room(self, n):
        """wait until the TX FIFO has room for n bytes: a write to a full TX FIFO is dropped"""
        while TX_DEPTH - self.chip.fifo_status(self.lane)[0] < n:
            self.chip.port.sleep_us(100)

    def _push(self, data):
        """push into TX without overflowing it (the lane pops as it goes)"""
        data = list(data)
        while data:
            tx, _ = self.chip.fifo_status(self.lane)
            room = TX_DEPTH - tx
            if room <= 0:
                self.chip.port.sleep_us(100)
                continue
            part, data = data[:room], data[room:]
            self.chip.tx_push(self.lane, part)

    def reset(self, timeout_us=50000):
        """reset pulse; True when a device answered with a presence pulse. The timeout covers
        writes still queued in TX (about 1 ms per byte)."""
        self._wait_room(1)
        r = self.chip.transfer(self.lane, [0], chunk=1, timeout_us=timeout_us)
        if not r:
            raise RuntimeError("1-Wire reset: no presence sample from the lane")
        return (r[0] & 0x80) == 0

    def write(self, data):
        out = []
        for b in data:
            out += [1, b & 0xFF]
        self._push(out)

    def read(self, n, timeout_us=50000):
        self._wait_room(min(n, 7))
        return self.chip.transfer(self.lane, [2] * n, chunk=7, timeout_us=timeout_us)


def crc8(data):
    """Maxim/Dallas CRC8 (x^8 + x^5 + x^4 + 1, reflected)"""
    crc = 0
    for b in data:
        for _ in range(8):
            mix = (crc ^ b) & 1
            crc >>= 1
            if mix:
                crc ^= 0x8C
            b >>= 1
    return crc
