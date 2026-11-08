"""Virtual demo board scenarios (plan step 8, log/demo_v2.md).

Each scenario configures the chip through the host API exactly as the RP2350 host would (firmware
images and ROM package tables from test/demo/assets.json), attaches device models from peers.py,
and checks
  - clean runs: the data the peer received / the chip pushed, and an empty verdict;
  - injected peer faults: blame (assumption violation), the expected cause code and lane, no fail,
    and a blame time stamp within a window after the instant the peer misbehaved;
  - injected chip faults (firmware mutants): fail with the expected code.
Stamps are chip step cycles; board time = stamp + STAMP_OFFSET (cycles from rst_n release to the
monitor's cycle 0), measured by the `calibrate` scenario and fixed here.

One scenario per simulator run (COCOTB_TEST_FILTER) so each gets its own waveform (run_demo.sh).
Results go to $DEMO_OUT/<scenario>.json.
"""
import json
import os
from pathlib import Path

import cocotb

import peers as pr
from pemu_host import ASSETS, Board, Pemu, package_by

OUT = Path(os.environ.get("DEMO_OUT", Path(__file__).resolve().parent / "results"))
STAMP_OFFSET = int(os.environ.get("DEMO_STAMP_OFFSET", "4"))
UART_BIT = 30e6 / 115200  # 260.4 cycles


def record(name, **kw):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{name}.json").write_text(json.dumps(kw, indent=1, default=str))


async def bring_up(dut, peers):
    b = Board(dut)
    b.peers = peers
    await b.start()
    h = Pemu(b)
    ident = await h.id()
    assert ident == 0xA1, hex(ident)
    return b, h


def step_cycles(pkg):
    return package_by(pkg)["p"] + 1


def check_blame(v, b, code, lane, t_fault, window, name):
    assert v["blame"] and not v["fail"], f"{name}: verdict {v}"
    assert v["blame_code"] == code, f"{name}: blame code {v['blame_code']:#x}, expected {code:#x}"
    assert v["blame_lane"] == lane, f"{name}: lane {v['blame_lane']}"
    t = b.release + v["blame_time"] + STAMP_OFFSET
    assert t_fault <= t <= t_fault + window, f"{name}: blame at board cycle {t}, fault {t_fault}, window {window}"
    return t


async def finish(b, h, n):
    await b.wait(n)
    return await h.verdict()


def summary(v):
    return {k: v[k] for k in v if k != "raw"}


@cocotb.test()
async def calibrate(dut):
    """uart_tx bad start (chip fault): the first start bit is driven wrong, fail 0x13 is stamped at
    the step that drives it. STAMP_OFFSET = (board cycle of that step) - release - stamp."""
    rx = pr.UartReceiver(pr.UART_TX, UART_BIT)
    edges = []

    class Edge:
        def __init__(self):
            self.prev_oe = 0

            self.prev_pad = 1

        def step(self, cyc, out, oe, pad):
            if (oe & 1) and not (self.prev_oe & 1):
                edges.append(("oe", cyc))
            if (pad & 1) != self.prev_pad and len(edges) < 8:
                edges.append(("fall" if self.prev_pad else "rise", cyc))
            self.prev_oe, self.prev_pad = oe, pad & 1
            return (0, 0)

    b, h = await bring_up(dut, [rx, Edge()])
    await h.setup_lane(0, "uart_tx_bad_start_d4", 0)
    await h.tx_push(0, [0xA5, 0x3C])
    t_run = b.cycle
    await h.run(1)
    v = await finish(b, h, 3000)
    assert v["fail"] and v["fail_code"] == 0x13, summary(v)
    record("calibrate", verdict=summary(v), t_run=t_run, release=b.release, edges=edges,
           fail_board=b.release + v["fail_time"])


@cocotb.test()
async def uart_tx_clean(dut):
    rx = pr.UartReceiver(pr.UART_TX, UART_BIT)
    b, h = await bring_up(dut, [rx])
    data = [0xA5, 0x3C, 0x00, 0xFF, 0x55]
    await h.setup_lane(0, "uart_tx_d4", 0)
    await h.tx_push(0, data)
    await h.run(1)
    v = await finish(b, h, int(len(data) * 10.5 * UART_BIT) + 500)
    record("uart_tx_clean", verdict=summary(v), received=rx.bytes, framing_errors=rx.framing_errors)
    assert rx.bytes == data and rx.framing_errors == 0, rx.bytes
    assert not v["fail"] and not v["blame"], summary(v)


@cocotb.test()
async def uart_tx_bad_start(dut):
    """chip fault: firmware mutant drives a short start bit, the monitor raises fail (guarantee)"""
    rx = pr.UartReceiver(pr.UART_TX, UART_BIT)
    b, h = await bring_up(dut, [rx])
    await h.setup_lane(0, "uart_tx_bad_start_d4", 0)
    await h.tx_push(0, [0xA5, 0x3C])
    await h.run(1)
    v = await finish(b, h, 3000)
    record("uart_tx_bad_start", verdict=summary(v), received=rx.bytes)
    assert v["fail"] and v["fail_code"] == 0x13 and v["fail_lane"] == 0 and not v["blame"], summary(v)


@cocotb.test()
async def uart_rx_clean(dut):
    data = [0x55, 0xA5, 0x00, 0xFF, 0x3C, 0x81]
    tx = pr.UartSender(pr.UART_RX, UART_BIT, data, t0=0, gap=300)
    b, h = await bring_up(dut, [])
    await h.setup_lane(0, "uart_rx_d8_pin1", 1)
    await h.run(1)
    tx.edges = [(c + b.cycle + 500, v) for c, v in tx.edges]
    b.peers.append(tx)
    await b.wait(tx.end + 1000)
    got = await h.rx_pop(0)
    v = await h.verdict()
    record("uart_rx_clean", verdict=summary(v), pushed=got)
    assert got == data, got
    assert not v["fail"] and not v["blame"], summary(v)


@cocotb.test()
async def uart_rx_fast_peer(dut):
    """peer fault: the attached UART sends 8 % fast; the RX package's bit-time assumption blames it
    within the first frame"""
    data = [0x55, 0xA5, 0x00, 0xFF, 0x3C, 0x81]
    bit = UART_BIT / 1.08
    tx = pr.UartSender(pr.UART_RX, bit, data, t0=0, gap=300)
    b, h = await bring_up(dut, [])
    await h.setup_lane(0, "uart_rx_d8_pin1", 1)
    await h.run(1)
    base = b.cycle + 500
    tx.edges = [(c + base, v) for c, v in tx.edges]
    b.peers.append(tx)
    await b.wait(tx.end + 1000)
    got = await h.rx_pop(0)
    v = await h.verdict()
    t0, t1 = base, base + int(10 * bit)
    rec = dict(verdict=summary(v), pushed=got, frame0=(t0, t1))
    record("uart_rx_fast_peer", **rec)
    check_blame(v, b, 0x32, 0, t0, t1 - t0, "uart_rx_fast_peer")


async def spi_ctl(dut, name, tco, expect):
    host = [0xA5, 0x3C, 0x00, 0xFF, 0x81, 0x7E, 0x55, 0x0F]
    peer = [0x96, 0x01, 0x80, 0xC3, 0x5A, 0xF0, 0x33, 0xE7]
    tgt = pr.SpiTarget(peer, tco=tco)
    first_miso = []

    class Probe:
        def __init__(self):
            self.prev = None

        def step(self, cyc, out, oe, pad):
            m = pr.bit(pad, pr.MISO)
            if self.prev is not None and m != self.prev and pr.bit(pad, pr.CS) == 0:
                first_miso.append(cyc)
            self.prev = m
            return (0, 0)

    b, h = await bring_up(dut, [tgt, Probe()])
    await h.setup_lane(1, "spi_ctl_m0", 2)
    await h.tx_push(1, host)
    await h.run(2)
    await b.wait(8 * 600)
    got = await h.rx_pop(1)
    v = await h.verdict()
    record(name, verdict=summary(v), target_received=tgt.received, pushed=got, miso_changes=first_miso[:4])
    assert tgt.received == host, tgt.received
    if expect is None:
        assert got == peer, got
        assert not v["fail"] and not v["blame"], summary(v)
    else:
        check_blame(v, b, expect, 1, first_miso[0] - 2 * step_cycles(2), 6 * step_cycles(2), name)


@cocotb.test()
async def spi_ctl_clean(dut):
    await spi_ctl(dut, "spi_ctl_clean", 3, None)


@cocotb.test()
async def spi_ctl_slow_target(dut):
    """peer fault: the SPI target's clock-to-out is 14 cycles, MISO is not settled one half period
    before the sampling edge"""
    await spi_ctl(dut, "spi_ctl_slow_target", 14, 0x91)


async def spi_tgt(dut, name, early):
    host = [0xA5, 0x3C, 0x00, 0xFF, 0x81, 0x7E, 0x55, 0x0F]
    peer = [0x96, 0x01, 0x80, 0xC3, 0x5A, 0xF0, 0x33, 0xE7]
    b, h = await bring_up(dut, [])
    await h.setup_lane(1, "spi_tgt_m0", 3)
    await h.tx_push(1, host)
    await h.run(2)
    ctl = pr.SpiController(peer, t0=b.cycle + 300, early_cs=early)
    b.peers.append(ctl)
    await b.wait(ctl.end - b.cycle + 400)
    got = await h.rx_pop(1)
    v = await h.verdict()
    record(name, verdict=summary(v), controller_received=ctl.received, pushed=got, fault_cycle=ctl.fault_cycle)
    if early is None:
        assert got == peer and ctl.received == host, (got, ctl.received)
        assert not v["fail"] and not v["blame"], summary(v)
    else:
        check_blame(v, b, 0x52, 1, ctl.fault_cycle, 4 * step_cycles(3) + 8, name)


@cocotb.test()
async def spi_tgt_clean(dut):
    await spi_tgt(dut, "spi_tgt_clean", None)


@cocotb.test()
async def spi_tgt_early_cs(dut):
    """peer fault: the SPI controller raises CS in frame 2 after 9 SCLK edges (mid-byte)"""
    await spi_tgt(dut, "spi_tgt_early_cs", (2, 9))


async def i2c_ctl(dut, name, dd, expect):
    host = [0xA0, 0x03, 0x11, 0x22, 0x33, 0xA1, 0x02]
    tgt = pr.I2cTarget(0x50, [0xC3, 0x5A], dd=dd, ack_dd=8)  # read data delayed by dd, ACK timely
    b, h = await bring_up(dut, [tgt])
    await h.setup_lane(0, "i2c_ctl_fm", 4)
    await h.tx_push(0, host)
    await h.run(1)
    await b.wait(14000)
    got = await h.rx_pop(0)
    v = await h.verdict()
    record(name, verdict=summary(v), target_log=tgt.log, pushed=got, target_high_changes=tgt.high_changes[:4])
    assert tgt.log == ["S", "A50W", "W11", "W22", "W33", "P", "S", "A50R", "RC3", "R5A", "P"], tgt.log
    if expect is None:
        assert got == [0x00, 0xC3, 0x5A, 0x00], got
        assert not v["fail"] and not v["blame"] and not tgt.high_changes, summary(v)
    else:
        check_blame(v, b, expect, 0, tgt.high_changes[0], 3 * step_cycles(4), name)


@cocotb.test()
async def i2c_ctl_clean(dut):
    await i2c_ctl(dut, "i2c_ctl_clean", 8, None)


@cocotb.test()
async def i2c_ctl_slow_target(dut):
    """peer fault: the I2C target changes SDA 70 cycles after SCL falls, i.e. inside the high phase"""
    await i2c_ctl(dut, "i2c_ctl_slow_target", int(os.environ.get("DEMO_I2C_DD", "70")), 0x77)


@cocotb.test()
async def i2c_ctl_late_ack(dut):
    """peer fault: the target's ACK arrives 70 cycles after SCL falls, inside the high phase (an
    SDA fall with SCL high). Blamed by the ACK cell's stability hold (A7)."""
    host = [0xA0, 0x03, 0x11, 0x22, 0x33, 0xA1, 0x02]
    tgt = pr.I2cTarget(0x50, [0xC3, 0x5A], dd=8, ack_dd=70)
    b, h = await bring_up(dut, [tgt])
    await h.setup_lane(0, "i2c_ctl_fm", 4)
    await h.tx_push(0, host)
    await h.run(1)
    await b.wait(14000)
    got = await h.rx_pop(0)
    v = await h.verdict()
    record("i2c_ctl_late_ack", verdict=summary(v), target_log=tgt.log, pushed=got, target_high_changes=tgt.high_changes[:4])
    check_blame(v, b, 0x77, 0, tgt.high_changes[0], 3 * step_cycles(4), "i2c_ctl_late_ack")


SM30 = dict(tlow=141, thigh=120, thd_sta=120, tsu_sta=141, tsu_sto=120, tbuf=141)


async def i2c_tgt(dut, name, t, expect):
    txs = [(("W", 0x50, [0x11, 0x22]), True), (("R", 0x50, 2), False), (("W", 0x52, [0xAA]), False)]
    b, h = await bring_up(dut, [])
    await h.setup_lane(0, "i2c_tgt_0x50", 6)
    await h.tx_push(0, [0x50, 0xA1, 0x36])
    await h.run(1)
    ctl = pr.I2cController(txs, t0=b.cycle + 400, **t)
    ctl.ops[0] = ("wait", 400)
    b.peers.append(ctl)
    for _ in range(80):
        await b.wait(1000)
        if ctl.done:
            break
    await b.wait(500)
    got = await h.rx_pop(0)
    v = await h.verdict()
    record(name, verdict=summary(v), controller_log=ctl.log, pushed=got, starts=ctl.start_cycles)
    assert got == [0x11, 0x22], got
    if expect is None:
        assert ctl.log[:11] == ["S", "A50W+", "W11+", "W22+", "Sr", "A50R+", "RA1", "R36", "P", "S", "A52W-"], ctl.log
    if expect is None:
        assert not v["fail"] and not v["blame"], summary(v)
    else:
        t_fault = ctl.start_cycles[0] + t["thd_sta"]  # SCL falls too early after START
        check_blame(v, b, expect, 0, t_fault - step_cycles(6), 4 * step_cycles(6) + 8, name)


@cocotb.test()
async def i2c_tgt_clean(dut):
    await i2c_tgt(dut, "i2c_tgt_clean", SM30, None)


@cocotb.test()
async def i2c_tgt_short_start_hold(dut):
    """peer fault: the I2C controller holds START for 60 cycles (2.0 us < 4.0 us Sm minimum)"""
    await i2c_tgt(dut, "i2c_tgt_short_start_hold", dict(SM30, thd_sta=60), 0x82)


@cocotb.test()
async def usb_ls_tx(dut):
    rx = pr.UsbLsReceiver(bit_cycles=20)
    b, h = await bring_up(dut, [rx])
    await h.setup_lane(0, "usb_ls_tx", 7)
    await h.tx_push(0, [0xC3, 0, 0x4B, 3, 0x01, 0x02, 0x03])
    await h.run(1)
    await b.wait(5000)
    got = await h.rx_pop(0)
    v = await h.verdict()
    pk, bad_runs = rx.packets()
    record("usb_ls_tx", verdict=summary(v), pushed=got, packets=pk, bad_runs=bad_runs, bad=getattr(rx, "bad", []))
    assert [(p["pid"], p["payload"]) for p in pk] == [(0xC3, []), (0x4B, [1, 2, 3])], pk
    assert all(p["sync_ok"] and p["pid_ok"] and p["crc_ok"] and not p["stuff_err"] and p["whole_bytes"] for p in pk), pk
    assert bad_runs == 0 and len(got) == 2
    assert not v["fail"] and not v["blame"], summary(v)


@cocotb.test()
async def windows_uart_d6(dut):
    """parameter windows (increment 2 option D): d6 firmware against ROM package 0 (d4 contract)
    fails; with the d6 window table loaded it runs clean at 6 steps per bit"""
    data = [0xA5, 0x3C]
    bit6 = 6 * step_cycles(0)
    rx = pr.UartReceiver(pr.UART_TX, bit6)
    b, h = await bring_up(dut, [rx])
    await h.setup_lane(0, "uart_tx_d6", 0)
    await h.tx_push(0, data)
    await h.run(1)
    v1 = await finish(b, h, int(len(data) * 10.5 * bit6) + 500)
    rom_rx = list(rx.bytes)
    await h.run(0)
    await h.clear_verdict(0)
    await h.load_windows(0, ASSETS["windows"]["uart_tx_d6"])
    rx.bytes.clear()
    await h.tx_push(0, data)
    await h.run(1)
    v2 = await finish(b, h, int(len(data) * 10.5 * bit6) + 500)
    record("windows_uart_d6", rom_verdict=summary(v1), window_verdict=summary(v2), rom_received=rom_rx,
           received=rx.bytes)
    assert v1["fail"], summary(v1)
    assert not v2["fail"] and not v2["blame"], summary(v2)
    assert rx.bytes == data, rx.bytes


@cocotb.test()
async def two_lanes(dut):
    """lane 0 UART TX and lane 1 SPI controller concurrently, both monitored, clean"""
    host = [0xA5, 0x3C, 0x00, 0xFF]
    peer = [0x96, 0x01, 0x80, 0xC3]
    rx = pr.UartReceiver(pr.UART_TX, UART_BIT)
    tgt = pr.SpiTarget(peer, tco=3)
    b, h = await bring_up(dut, [rx, tgt])
    await h.setup_lane(0, "uart_tx_d4", 0)
    await h.setup_lane(1, "spi_ctl_m0", 2)
    await h.tx_push(0, [0x55, 0xC3])
    await h.tx_push(1, host)
    await h.run(3)
    await b.wait(int(2 * 10.5 * UART_BIT) + 800)
    got = await h.rx_pop(1)
    v = await h.verdict()
    record("two_lanes", verdict=summary(v), uart=rx.bytes, spi_target=tgt.received, pushed=got)
    assert rx.bytes == [0x55, 0xC3] and tgt.received == host and got == peer, (rx.bytes, tgt.received, got)
    assert not v["fail"] and not v["blame"], summary(v)
