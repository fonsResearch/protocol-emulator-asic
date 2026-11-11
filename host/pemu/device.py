"""Device API of the protocol emulator (doc/host.md section 3).

Register map: doc/interface_v1.md section 5, monitor registers doc/contracts/monitor_isa_v1.md
section 8 (package select, remap, option-D windows, verdict). Inputs come from the toolchain:
  program  = the JSON object written by `pemu_asm asm FILE.s -f json`
             {"words": [...], "own": n, "od": n, "cfg": n, "cfg2": n}
  package  = one entry of `pemu_cc json` ("packages"): {"index", "name", "p", "remap", "windows"}
  windows  = the list printed by `pemu_cc retune ROM VARIANT`

Host-side assumption guard (log/witness_v2.md section 3, decision 2026-11-11): the package proofs
(A2, formal/src/ag_pkg.ml rx_never_full) assume the lane's RX FIFO is never full, for every ROM
package except UART TX (which never pushes). The monitor cannot observe this. A full RX FIFO
makes the lane's PUSH block, and a contract can then report the missing push as a chip fail (F56
on the I2C target). The device records every observation of RX level 8 on a running lane, and
verdict() reports host_valid = False when any was seen: the run is outside the proved envelope and
a fail in it is not evidence of a chip fault. Since only host pops lower the level, and every pop
through this package reads the level first, the guard sees every full episode (doc/host.md 3.1).
"""

ID_VALUE = 0xA1

CTRL, STATUS, FAULT = 0x01, 0x02, 0x03
VERDICT = 0x40
FAULT_CAUSES = {0: "none", 1: "fetch_bound", 2: "blame", 3: "halt"}
RX_DEPTH = 8


def _lane_base(lane):
    return 0x10 + 16 * lane


class PemuError(Exception):
    pass


class Pemu:
    def __init__(self, port):
        self.port = port
        self.running = 0  # RUN bits last written
        self.host_faults = []  # (lane, what, poll index)
        self.rx = [[], []]  # bytes drained by wait_us(), per lane
        self._polls = 0

    # ---- port level ----
    def write(self, addr, data):
        self.port.xfer([addr & 0x7F] + list(data))

    def read(self, addr, n=1):
        return self.port.xfer([0x80 | addr] + [0] * n)[1:]

    # ---- identification and lane setup ----
    def id(self):
        return self.read(0x00)[0]

    def check_id(self):
        v = self.id()
        if v != ID_VALUE:
            raise PemuError("ID reads 0x%02X, expected 0x%02X (port wiring or clock?)" % (v, ID_VALUE))

    def lane_config(self, lane, own, od=0, p=7, cfg=0, cfg2=0):
        b = _lane_base(lane)
        self.write(b + 0, [own])
        self.write(b + 1, [od])
        self.write(b + 2, [p & 0xFF, p >> 8])
        self.write(b + 5, [cfg])
        self.write(b + 6, [cfg2])

    def load_program(self, lane, words):
        if len(words) > 256:
            raise PemuError("program has %d words; the lane memory holds 256" % len(words))
        b = _lane_base(lane)
        self.write(b + 4, [len(words)])
        self.write(b + 7, [0])
        data = []
        for w in words:
            data += [w & 0xFF, w >> 8]
        self.write(b + 8, data)

    def select_package(self, lane, index, remap):
        self.write(0x50 + 8 * lane, [0x80 | index])
        self.write(0x60 + 16 * lane, list(remap))

    def disable_package(self, lane):
        """run the lane unmonitored (PKG bit 7 clear; no RUN admission check)"""
        self.write(0x50 + 8 * lane, [0x00])

    def load_windows(self, lane, windows):
        """option-D override: windows[1..7] (12 bits each), from `pemu_cc retune`"""
        if len(windows) != 8:
            raise PemuError("window table needs 8 entries (entry 0 unused)")
        b = 0x50 + 8 * lane
        for k in range(1, 8):
            if not 0 <= windows[k] < 4096:
                raise PemuError("window %d = %d does not fit 12 bits" % (k, windows[k]))
            self.write(b + 3, [k])
            self.write(b + 6, [windows[k] & 0xFF])
            self.write(b + 7, [windows[k] >> 8])
        self.write(b + 3, [0x80])

    def setup_lane(self, lane, program, package=None, p=None):
        """program: pemu_asm JSON object; package: pemu_cc package entry or None (unmonitored).
        p defaults to the package's divisor; an unmonitored lane needs p."""
        if p is None:
            if package is None:
                raise PemuError("an unmonitored lane needs p")
            p = package["p"]
        self.lane_config(lane, program["own"], program["od"], p, program["cfg"], program["cfg2"])
        self.load_program(lane, program["words"])
        if package is None:
            self.disable_package(lane)
        else:
            self.select_package(lane, package["index"], package["remap"])

    # ---- streams ----
    def tx_push(self, lane, data):
        self.write(_lane_base(lane) + 9, list(data))

    def fifo_status(self, lane):
        v = self.read(_lane_base(lane) + 11)[0]
        return v & 0xF, (v >> 4) & 0xF  # tx level, rx level

    def rx_level(self, lane):
        return self.fifo_status(lane)[1]

    def rx_pop(self, lane):
        """all received bytes of the lane: those drained by wait_us() plus the FIFO contents"""
        n = self.rx_level(lane)
        self._guard(lane, n)
        got = self.read(_lane_base(lane) + 10, n) if n else []
        out = self.rx[lane] + got
        self.rx[lane] = []
        return out

    def _guard(self, lane, rx_level):
        if rx_level >= RX_DEPTH and (self.running >> lane) & 1:
            self.host_faults.append((lane, "rx_full", self._polls))

    def transfer(self, lane, data, chunk=RX_DEPTH - 1, timeout_us=100000, poll_us=50):
        """for packages that push one RX byte per TX byte (SPI controller): push at most [chunk]
        bytes, wait until their replies are in the RX FIFO, pop, repeat. RX never exceeds [chunk]
        < 8, so the never-full assumption holds whatever the host's speed. The lane must be
        running. Returns the received bytes (stops early on a verdict or timeout)."""
        out = []
        data = list(data)
        while data:
            part, data = data[:chunk], data[chunk:]
            self.tx_push(lane, part)
            waited = 0
            while self.rx_level(lane) < len(part) and waited < timeout_us:
                if self.read(STATUS)[0] & 0xC0:  # a verdict is pending: stop streaming
                    data = []
                    break
                self.port.sleep_us(poll_us)
                waited += poll_us
            out += self.rx_pop(lane)
        return out

    # ---- control and verdict ----
    def run(self, lanes):
        self.running = lanes & 3
        self.write(CTRL, [lanes & 3])

    def status(self):
        v = self.read(STATUS)[0]
        return {
            "running": v & 3, "loaded": (v >> 2) & 3, "faulted": (v >> 4) & 3,
            "fail": bool(v & 0x40), "blame": bool(v & 0x80), "raw": v,
        }

    def fault(self):
        v = self.read(FAULT)[0]
        return [FAULT_CAUSES.get(v & 0xF, "reserved"), FAULT_CAUSES.get(v >> 4, "reserved")]

    def verdict(self):
        # guard completeness: a full RX FIFO persists until the next host pop, and every pop
        # through this package checks the level first; this check covers a run that ends full
        for lane in (0, 1):
            if (self.running >> lane) & 1:
                self._guard(lane, self.rx_level(lane))
        v = self.read(VERDICT, 12)

        def le(a):
            return v[a] | (v[a + 1] << 8) | (v[a + 2] << 16) | (v[a + 3] << 24)

        return {
            "fail": bool(v[0] & 1), "blame": bool(v[0] & 2),
            "blame_lane": (v[0] >> 2) & 1, "fail_lane": (v[0] >> 3) & 1,
            "overrun": (v[0] >> 4) & 3, "fail_code": v[1], "blame_code": v[2],
            "fail_unit": v[3] & 7, "blame_unit": (v[3] >> 4) & 7,
            "fail_time": le(4), "blame_time": le(8),
            "host_valid": not self.host_faults, "host_faults": list(self.host_faults),
        }

    def clear_verdict(self, lanes_running=0):
        self.running = lanes_running & 3
        self.write(CTRL, [(lanes_running & 3) | 0x10])
        self.host_faults = []

    # ---- waiting with the assumption guard ----
    def wait_us(self, us, drain=(), poll_us=200):
        """wait about us microseconds; every poll_us, check the RX level of every running lane
        (guard) and pop the lanes in [drain] into self.rx[lane]"""
        left = us
        while left > 0:
            d = poll_us if left > poll_us else left
            self.port.sleep_us(d)
            left -= d
            self._polls += 1
            for lane in (0, 1):
                if (self.running >> lane) & 1:
                    n = self.rx_level(lane)
                    self._guard(lane, n)
                    if lane in drain and n:
                        self.rx[lane] += self.read(_lane_base(lane) + 10, n)
