"""Device models for the virtual demo board, written from the protocol documents (doc/protocols/)
and not from the OCaml peers (protocols_v1/src/peers.ml), so the demo board is a second, independent
environment. Each model has step(cycle, out, oe, pad) -> (drive_oe, drive_val), called once per
cycle with the chip's current drive and the pads of the previous cycle. Open-drain models only pull
low (drive_oe bit set, drive_val bit 0) or release.

Pins (doc/protocols): UART TX uio0, UART RX uio1; I2C SCL uio2, SDA uio3; SPI CS uio4, SCLK uio5,
MOSI uio6, MISO uio7; USB-LS D+ uio0, D- uio1.
"""

UART_TX, UART_RX = 0, 1
SCL, SDA = 2, 3
CS, SCLK, MOSI, MISO = 4, 5, 6, 7
DP, DM = 0, 1


def bit(v, b):
    return (v >> b) & 1


class UartSender:
    """8N1 frames on [pin] with [bit_cycles] per bit (float allowed: a fast or slow peer)."""

    def __init__(self, pin, bit_cycles, data, t0=2000, gap=300):
        self.pin, self.fault_window = pin, None
        self.edges = []  # (cycle, level)
        t = float(t0)
        for b in data:
            bits = [0] + [(b >> k) & 1 for k in range(8)] + [1]
            for v in bits:
                self.edges.append((int(t), v))
                t += bit_cycles
            t += gap
        self.end = int(t)
        self.first = t0

    def step(self, cyc, out, oe, pad):
        lvl = 1
        for c, v in self.edges:
            if c <= cyc:
                lvl = v
            else:
                break
        return (1 << self.pin, lvl << self.pin)


class UartReceiver:
    """Decodes 8N1 frames on [pin] (the chip's TX) by mid-bit sampling."""

    def __init__(self, pin, bit_cycles):
        self.pin, self.bc = pin, bit_cycles
        self.bytes, self.framing_errors = [], 0
        self._start = None
        self._prev = 1

    def step(self, cyc, out, oe, pad):
        v = bit(pad, self.pin)
        if self._start is None and self._prev == 1 and v == 0:
            self._start = cyc
            self._bits = []
        elif self._start is not None:
            k = len(self._bits)
            if cyc - self._start == int((k + 1.5) * self.bc):
                self._bits.append(v)
                if len(self._bits) == 9:
                    if self._bits[8] != 1:
                        self.framing_errors += 1
                    self.bytes.append(sum(b << i for i, b in enumerate(self._bits[:8])))
                    self._start = None
        self._prev = v
        return (0, 0)


class SpiTarget:
    """SPI mode 0 target answering the chip as controller. MISO changes [tco] cycles after CS falls
    (first bit of a byte) and after each SCLK fall; MOSI is sampled on SCLK rise. Bytes from [send]
    are consumed one per 8 SCLK edges, across CS frames or within one."""

    def __init__(self, send, tco=3):
        self.send, self.tco = list(send), tco
        self.received = []
        self._pcs, self._psck = 1, 0
        self._miso = 1
        self._pending = None  # (cycle, value)
        self._tx = None  # byte being shifted out; None = next byte not loaded yet
        self._n = 0
        self._rx = 0

    def _msb(self, cyc):
        if self._tx is None:
            self._tx = self.send.pop(0) if self.send else 0xFF
        self._pending = (cyc + self.tco, (self._tx >> 7) & 1)

    def step(self, cyc, out, oe, pad):
        cs, sck, mosi = bit(pad, CS), bit(pad, SCLK), bit(pad, MOSI)
        if self._pcs == 1 and cs == 0:
            self._n, self._rx = 0, 0
            self._msb(cyc)
        if cs == 0 and self._psck == 0 and sck == 1:
            self._rx = (self._rx << 1) | mosi
            self._n += 1
            if self._n == 8:
                self.received.append(self._rx)
                self._rx, self._n, self._tx = 0, 0, None
        if cs == 0 and self._psck == 1 and sck == 0:
            if self._n == 0:
                self._msb(cyc)
            else:
                self._pending = (cyc + self.tco, (self._tx >> (7 - self._n)) & 1)
        if self._pending and cyc >= self._pending[0]:
            self._miso = self._pending[1]
            self._pending = None
        self._pcs, self._psck = cs, sck
        if cs == 0:
            return (1 << MISO, self._miso << MISO)
        return (0, 0)


class SpiController:
    """SPI mode 0 controller driving the chip as target: one byte per CS frame, SCLK half period
    [hp], CS set-up/hold [setup]/[hold], [gap] between frames. Fault injection: [early_cs] =
    (frame, edges) raises CS after that many SCLK edges of that frame."""

    def __init__(self, data, hp=40, setup=40, hold=40, gap=144, t0=400, early_cs=None):
        self.received = []
        self.events = []  # (cycle, cs, sclk, mosi)
        self.samples = []  # cycles at which MISO is sampled
        self.fault_cycle = None
        t = t0
        for f, b in enumerate(data):
            edges = 0
            self.events.append((t, 0, 0, (b >> 7) & 1))
            t += setup
            cut = early_cs[1] if early_cs and early_cs[0] == f else None
            for k in range(8):
                mo = (b >> (7 - k)) & 1
                if cut is not None and edges >= cut:
                    break
                self.events.append((t, 0, 1, mo))
                self.samples.append(t)
                edges += 1
                t += hp
                if cut is not None and edges >= cut:
                    break
                nxt = (b >> (6 - k)) & 1 if k < 7 else mo
                self.events.append((t, 0, 0, nxt))
                edges += 1
                t += hp
            if cut is not None:
                self.fault_cycle = t
                self.events.append((t, 1, 0, 0))
            else:
                t += hold
                self.events.append((t, 1, 0, 0))
            t += gap
        self.end = t
        self._i = 0
        self._state = (1, 0, 0)
        self._rx, self._n = 0, 0

    def step(self, cyc, out, oe, pad):
        while self._i < len(self.events) and self.events[self._i][0] <= cyc:
            _, cs, sck, mo = self.events[self._i]
            if self._state[1] == 0 and sck == 1:
                self._rx = (self._rx << 1) | bit(pad, MISO)
                self._n += 1
                if self._n == 8:
                    self.received.append(self._rx)
                    self._rx, self._n = 0, 0
            if cs == 1:
                self._rx, self._n = 0, 0
            self._state = (cs, sck, mo)
            self._i += 1
        cs, sck, mo = self._state
        m = (1 << CS) | (1 << SCLK) | (1 << MOSI)
        return (m, (cs << CS) | (sck << SCLK) | (mo << MOSI))


class I2cTarget:
    """I2C target at [addr] for the chip as controller. ACKs its address and written bytes,
    returns [read_data]. SDA changes [dd] cycles after each SCL fall (fault injection: a dd longer
    than the controller's low phase moves the change into the high phase)."""

    def __init__(self, addr, read_data, dd=8, ack_dd=None):
        self.addr, self.read_data, self.dd = addr, list(read_data), dd
        self.ack_dd = dd if ack_dd is None else ack_dd
        self.high_changes = []
        self._own_cyc = -10
        self.log = []
        self._pscl, self._psda = 1, 1
        self._state = "idle"
        self._n, self._sh = 0, 0
        self._sda_out = 1  # 1 = released
        self._pending = None
        self._tx = 0

    def _set(self, cyc, v, ack=False):
        self._pending = (cyc + (self.ack_dd if ack else self.dd), v)

    def step(self, cyc, out, oe, pad):
        scl, sda = bit(pad, SCL), bit(pad, SDA)
        own = cyc - self._own_cyc <= 1  # an SDA edge caused by this target's own drive change
        if own:
            pass
        elif scl and self._pscl and self._psda == 1 and sda == 0:
            self._state, self._n, self._sh = "addr", 0, 0
            self._sda_out, self._pending = 1, None
            self.log.append("S")
        elif scl and self._pscl and self._psda == 0 and sda == 1:
            self._state, self._sda_out, self._pending = "idle", 1, None
            self.log.append("P")
        elif self._pscl == 0 and scl == 1:  # rising: sample
            if self._state in ("addr", "wdata"):
                self._sh = (self._sh << 1) | sda
                self._n += 1
            elif self._state == "rack":
                self._state = "rnext" if sda == 0 else "idle"
        elif self._pscl == 1 and scl == 0:  # falling: act
            if self._state == "addr" and self._n == 8:
                if (self._sh >> 1) == self.addr:
                    self._rw = self._sh & 1
                    self.log.append("A%02X%s" % (self._sh >> 1, "R" if self._rw else "W"))
                    self._state = "ack_a"
                    self._set(cyc, 0, ack=True)
                else:
                    self._state = "idle"
            elif self._state == "ack_a":
                if self._rw:
                    self._tx = self.read_data.pop(0) if self.read_data else 0xFF
                    self._n = 0
                    self._state = "rdata"
                    self._set(cyc, (self._tx >> 7) & 1)
                else:
                    self._state, self._n, self._sh = "wdata", 0, 0
                    self._set(cyc, 1, ack=True)
            elif self._state == "wdata" and self._n == 8:
                self.log.append("W%02X" % (self._sh & 0xFF))
                self._state = "ack_w"
                self._set(cyc, 0, ack=True)
            elif self._state == "ack_w":
                self._state, self._n, self._sh = "wdata", 0, 0
                self._set(cyc, 1, ack=True)
            elif self._state == "rnext":
                self._tx = self.read_data.pop(0) if self.read_data else 0xFF
                self._n, self._state = 0, "rdata"
                self._set(cyc, (self._tx >> 7) & 1)
            elif self._state == "rdata":
                self._n += 1
                if self._n < 8:
                    self._set(cyc, (self._tx >> (7 - self._n)) & 1)
                else:
                    self.log.append("R%02X" % self._tx)
                    self._state = "rack"
                    self._set(cyc, 1)
        if self._pending and cyc >= self._pending[0]:
            if self._pending[1] != self._sda_out:
                self._own_cyc = cyc
                if scl == 1:
                    self.high_changes.append(cyc)  # ground truth: this target moved SDA with SCL high
            self._sda_out = self._pending[1]
            self._pending = None
        self._pscl, self._psda = scl, sda
        return ((1 << SDA), 0) if self._sda_out == 0 else (0, 0)


class I2cController:
    """I2C controller (cycle timing per UM10204 parameter names) driving the chip as target.
    txs: list of ("W", addr, [bytes]) / ("R", addr, n), each followed by Sr (True) or STOP.
    Waits for SCL high after each release (clock stretching)."""

    def __init__(self, txs, tlow, thigh, thd_sta, tsu_sta, tsu_sto, tbuf, dh=1, su=8, t0=400):
        self.log = []
        self.done = False
        self.start_cycles = []
        ops = [("wait", t0), ("mark",), ("sda", 0), ("wait", thd_sta), ("scl", 0)]

        def cell(v, sample=None):
            return [("wait", dh), ("sda", v), ("wait", max(1, tlow - dh)), ("scl", 1), ("high",),
                    ("wait", thigh), ("sample", sample), ("scl", 0)]

        for i, (tx, more) in enumerate(txs):
            kind, addr = tx[0], tx[1]
            if i > 0:
                pass
            ops += [("note", "S" if i == 0 or not txs[i - 1][1] else "Sr")]
            a = (addr << 1) | (1 if kind == "R" else 0)
            for k in range(8):
                ops += cell((a >> (7 - k)) & 1)
            ops += cell(1, ("ack", "A%02X%s" % (addr, kind)))
            if kind == "W":
                for b in tx[2]:
                    for k in range(8):
                        ops += cell((b >> (7 - k)) & 1)
                    ops += cell(1, ("ack", "W%02X" % b))
            else:
                n = tx[2]
                for j in range(n):
                    for k in range(8):
                        ops += cell(1, ("bit", None))
                    ops += [("byte",)]
                    ops += cell(0 if j < n - 1 else 1)
            if more:  # repeated START
                ops += [("wait", dh), ("sda", 1), ("wait", max(1, tlow - dh)), ("scl", 1), ("high",),
                        ("wait", tsu_sta), ("mark",), ("sda", 0), ("wait", thd_sta), ("scl", 0)]
            else:  # STOP
                ops += [("wait", dh), ("sda", 0), ("wait", max(1, tlow - dh)), ("scl", 1), ("high",),
                        ("wait", tsu_sto), ("sda", 1), ("note", "P"), ("wait", tbuf)]
                if i + 1 < len(txs):
                    ops += [("mark",), ("sda", 0), ("wait", thd_sta), ("scl", 0)]
        ops += [("done",)]
        self.ops, self._i, self._w = ops, 0, 0
        self._scl, self._sda = 1, 1
        self._bits = []

    def step(self, cyc, out, oe, pad):
        while self._i < len(self.ops):
            op = self.ops[self._i]
            if op[0] == "wait":
                if self._w == 0:
                    self._w = op[1]
                self._w -= 1
                if self._w > 0:
                    break
                self._i += 1
                break
            if op[0] == "high":
                if bit(pad, SCL) == 0:
                    break
            elif op[0] == "scl":
                self._scl = op[1]
            elif op[0] == "sda":
                self._sda = op[1]
            elif op[0] == "mark":
                self.start_cycles.append(cyc)
            elif op[0] == "note":
                self.log.append(op[1])
            elif op[0] == "sample" and op[1]:
                kind, name = op[1]
                v = bit(pad, SDA)
                if kind == "ack":
                    self.log.append(name + ("+" if v == 0 else "-"))
                else:
                    self._bits.append(v)
            elif op[0] == "byte":
                self.log.append("R%02X" % sum(b << (7 - i) for i, b in enumerate(self._bits[-8:])))
            elif op[0] == "done":
                self.done = True
            self._i += 1
        m = 0
        if self._scl == 0:
            m |= 1 << SCL
        if self._sda == 0:
            m |= 1 << SDA
        return (m, 0)


def crc16_usb(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc ^ 0xFFFF


class UsbLsReceiver:
    """USB low-speed receiver on D+ (uio0), D- (uio1): records the chip-driven line per cycle and
    decodes packets afterwards: bit times of [bit_cycles], NRZI, bit unstuffing, SYNC, PID check
    nibble, CRC16, EOP (SE0 SE0 J). LS: J = D- high, D+ low."""

    def __init__(self, bit_cycles=20):
        self.bc = bit_cycles
        self.runs = []  # [state, length]; state J/K/SE0/None (undriven)

    def step(self, cyc, out, oe, pad):
        if oe & 3 != 3:
            s = None
        else:
            s = {0b10: "J", 0b01: "K", 0b00: "SE0"}.get(out & 3, "SE1")
        if self.runs and self.runs[-1][0] == s:
            self.runs[-1][1] += 1
        else:
            self.runs.append([s, 1])
        return (0, 0)

    def packets(self):
        syms, bad_runs = [], 0
        for s, n in self.runs:
            k = round(n / self.bc)
            in_packet = s in ("K", "SE0") or (s == "J" and k <= 7)  # idle J between packets is not bit-aligned
            if s is not None and in_packet and abs(n - k * self.bc) > 1:
                bad_runs += 1
                self.bad = getattr(self, "bad", []) + [(s, n)]
            syms += [s or "J"] * k
        out, cur = [], None
        prev = "J"
        for s in syms:
            if cur is None:
                if s == "K" and prev == "J":
                    cur = ["K"]
            else:
                cur.append(s)
                if cur[-2:] == ["SE0", "SE0"]:
                    out.append(cur)
                    cur = None
            prev = s
        return [self._decode(p) for p in out], bad_runs

    def _decode(self, syms):
        body = syms[:-2]
        bits, prev, ones, stuff_err = [], "J", 0, False
        for s in body:
            b = 1 if s == prev else 0
            prev = s
            if ones == 6:
                if b != 0:
                    stuff_err = True
                ones = 0
                continue
            bits.append(b)
            ones = ones + 1 if b else 0
        sync_ok = bits[:8] == [0, 0, 0, 0, 0, 0, 0, 1]
        data = bits[8:]
        nbytes = len(data) // 8
        by = [sum(data[8 * i + k] << k for k in range(8)) for i in range(nbytes)]
        pid = by[0] if by else None
        pid_ok = pid is not None and (pid >> 4) == (~pid & 0xF)
        payload = by[1:-2]
        crc_ok = len(by) >= 3 and crc16_usb(payload) == (by[-2] | (by[-1] << 8))
        return {"pid": pid, "payload": payload, "sync_ok": sync_ok, "pid_ok": pid_ok, "crc_ok": crc_ok,
                "stuff_err": stuff_err, "whole_bytes": len(data) % 8 == 0}


# ---------------------------------------------------------------- 1-Wire (held-out, plan step 11)

DQ = 2


def crc8_maxim(data):
    crc = 0
    for b in data:
        for _ in range(8):
            mix = (crc ^ b) & 1
            crc >>= 1
            if mix:
                crc ^= 0x8C
            b >>= 1
    return crc


class OneWireDevice:
    """A DS18B20-like device at standard speed on DQ (doc/protocols/onewire_v1.md section 0):
    a low of 480 us or more is a reset, answered after [wait_us] by a presence low of [presence_us];
    every other low that the device did not cause starts a slot. In a write slot the device samples
    DQ [sample_us] after the fall; in a read slot it answers a 0 by holding DQ low [read0_us] from
    the fall. Commands: READ ROM 0x33, SKIP ROM 0xCC, then READ SCRATCHPAD 0xBE or WRITE SCRATCHPAD
    0x4E (TH, TL, config)."""

    def __init__(self, cpu=30, rom=None, scratch=None, wait_us=30, presence_us=120, sample_us=30, read0_us=30):
        body = rom or [0x28, 0x5A, 0x3C, 0x11, 0x07, 0x00, 0x00]
        self.rom = body + [crc8_maxim(body)]
        self.scratch = list(scratch or [0x91, 0x01, 0x4B, 0x46, 0x7F, 0xFF, 0x0F, 0x10])
        self.cpu, self.wait, self.presence, self.sample, self.read0 = cpu, wait_us, presence_us, sample_us, read0_us
        self.log = []
        self._low_until = []  # (from, to) cycles of the device's own pulls
        self._prev = 1
        self._own_prev = False
        self._fall = None
        self._sample_at = None
        self._rx = []  # received bits of the current byte
        self._tx = []  # bits to send
        self._expect = None  # "rom", "fn", ("data", k) or None

    def _pulling(self, cyc):
        return any(a <= cyc < b for a, b in self._low_until)

    def _byte(self, b):
        if self._expect == "rom":
            self.log.append("rom %02X" % b)
            if b == 0x33:
                self._tx = [(x >> i) & 1 for x in self.rom for i in range(8)]
                self._expect = "fn"
            elif b == 0xCC:
                self._expect = "fn"
            else:
                self._expect = None
        elif self._expect == "fn":
            self.log.append("fn %02X" % b)
            if b == 0xBE:
                sp = self.scratch + [crc8_maxim(self.scratch)]
                self._tx = [(x >> i) & 1 for x in sp for i in range(8)]
                self._expect = None
            elif b == 0x4E:
                self._expect = ("data", [])
            else:
                self._expect = None
        elif isinstance(self._expect, tuple):
            got = self._expect[1] + [b]
            self.log.append("data %02X" % b)
            if len(got) == 3:
                self.scratch[2:5] = got
                self.log.append("scratch written")
                self._expect = None
            else:
                self._expect = ("data", got)

    def step(self, cyc, out, oe, pad):
        us = self.cpu
        dq = bit(pad, DQ)
        if dq == 0 and self._prev == 1 and not self._own_prev:
            self._fall = cyc
            if self._tx:
                if self._tx.pop(0) == 0:
                    self._low_until.append((cyc, cyc + self.read0 * us))
            elif self._expect is not None:
                self._sample_at = cyc + self.sample * us
        if self._sample_at == cyc:
            self._sample_at = None
            self._rx.append(dq)
            if len(self._rx) == 8:
                b = sum(v << i for i, v in enumerate(self._rx))
                self._rx = []
                self._byte(b)
        if dq == 1 and self._prev == 0 and self._fall is not None and not self._own_prev:
            if cyc - self._fall >= 480 * us:
                self.log.append("reset")
                self._rx, self._tx, self._sample_at, self._expect = [], [], None, "rom"
                if self.presence > 0:
                    self._low_until.append((cyc + self.wait * us, cyc + (self.wait + self.presence) * us))
            self._fall = None
        self._prev = dq
        own = self._pulling(cyc)
        self._own_prev = own
        return (1 << DQ, 0) if own else (0, 0)


class LineRecorder:
    """passive: records the cycles of every DQ edge (for RTL vs gate-level comparison)"""

    def __init__(self, pin=DQ):
        self.pin, self.prev, self.edges = pin, 1, []

    def step(self, cyc, out, oe, pad):
        v = bit(pad, self.pin)
        if v != self.prev:
            self.edges.append((cyc, v))
        self.prev = v
        return (0, 0)
