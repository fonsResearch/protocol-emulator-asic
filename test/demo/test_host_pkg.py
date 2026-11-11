"""Host package on the virtual demo board (plan step 10, doc/host.md section 5).

Every scenario body is a plain blocking function written as it would run on the RP2350: it uses
only the host package (host/pemu) and the toolchain outputs in host/assets (pemu_asm, pemu_cc). It
runs in a cocotb bridge thread; the package talks to the chip through SimPort (test/demo/host_port.py)
instead of pemu.BitBangPort. The cocotb side brings the board up and attaches the device models
(test/demo/peers.py), the same models the step-8 scenarios use (test/demo/test_demo.py).

Checks as in test_demo.py: clean runs deliver the data with an empty verdict; peer faults give a
blame with the expected code and lane, stamped within a window after the fault; firmware faults give
a fail. New here: the host-side RX-full guard (log/witness_v2.md section 3) on a long I2C write.
Results go to $DEMO_OUT/host_<scenario>.json.
"""
import json
import os
import sys
from pathlib import Path

import cocotb
from cocotb.task import bridge

import peers as pr
from host_port import CYCLES_PER_US, SimPort
from pemu_host import Board

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "host"))
import pemu  # noqa: E402

LIB = pemu.load(str(ROOT / "host" / "assets"))
OUT = Path(os.environ.get("DEMO_OUT", Path(__file__).resolve().parent / "results"))
STAMP_OFFSET = int(os.environ.get("DEMO_STAMP_OFFSET", "4"))
UART_BIT = 30e6 / 115200
SM30 = dict(tlow=141, thigh=120, thd_sta=120, tsu_sta=141, tsu_sto=120, tbuf=141)


def us(cycles):
    return int(cycles / CYCLES_PER_US) + 1


def record(name, **kw):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"host_{name}.json").write_text(json.dumps(kw, indent=1, default=str))


def step_cycles(pkg):
    return LIB.package(pkg)["p"] + 1


def check_blame(v, b, code, lane, t_fault, window, name):
    assert v["blame"] and not v["fail"], f"{name}: verdict {v}"
    assert v["host_valid"], f"{name}: host guard {v['host_faults']}"
    assert v["blame_code"] == code, f"{name}: blame code {v['blame_code']:#x}, expected {code:#x}"
    assert v["blame_lane"] == lane, f"{name}: lane {v['blame_lane']}"
    t = b.release + v["blame_time"] + STAMP_OFFSET
    assert t_fault <= t <= t_fault + window, f"{name}: blame at board cycle {t}, fault {t_fault}, window {window}"


def clean(v):
    return not v["fail"] and not v["blame"] and v["host_valid"]


async def host_run(dut, peers, body):
    """bring the board up with [peers], then run body(chip, board) as host code in a bridge thread;
    returns (board, body result)"""
    b = Board(dut)
    b.peers = list(peers)
    await b.start()
    chip = pemu.Pemu(SimPort(b))

    def main():
        chip.check_id()
        return body(chip, b)

    return b, await bridge(main)()


# ---------------------------------------------------------------- UART


@cocotb.test()
async def uart_tx_clean(dut):
    rx = pr.UartReceiver(pr.UART_TX, UART_BIT)
    data = [0xA5, 0x3C, 0x00, 0xFF, 0x55]

    def body(chip, b):
        chip.setup_lane(0, LIB.program("uart_tx_d4"), LIB.package(0))
        chip.tx_push(0, data)
        chip.run(1)
        chip.wait_us(us(len(data) * 10.5 * UART_BIT + 500))
        return chip.verdict()

    _, v = await host_run(dut, [rx], body)
    record("uart_tx_clean", verdict=v, received=rx.bytes)
    assert rx.bytes == data and rx.framing_errors == 0 and clean(v), (rx.bytes, v)


@cocotb.test()
async def uart_tx_bad_start(dut):
    """firmware fault: short start bit, fail 0x13 on lane 0"""
    rx = pr.UartReceiver(pr.UART_TX, UART_BIT)

    def body(chip, b):
        chip.setup_lane(0, LIB.program("uart_tx_bad_start_d4"), LIB.package(0))
        chip.tx_push(0, [0xA5, 0x3C])
        chip.run(1)
        chip.wait_us(us(3000))
        return chip.verdict(), chip.fault()

    _, (v, f) = await host_run(dut, [rx], body)
    record("uart_tx_bad_start", verdict=v, fault=f)
    assert v["fail"] and v["fail_code"] == 0x13 and v["fail_lane"] == 0 and not v["blame"] and v["host_valid"], v


@cocotb.test()
async def uart_rx_fast_peer(dut):
    """peer fault: the attached UART is 8 % fast; blame 0x32 within the first frame"""
    data = [0x55, 0xA5, 0x00, 0xFF, 0x3C, 0x81]
    bit = UART_BIT / 1.08
    tx = pr.UartSender(pr.UART_RX, bit, data, t0=0, gap=300)

    def body(chip, b):
        chip.setup_lane(0, LIB.program("uart_rx_d8_pin1"), LIB.package(1))
        chip.run(1)
        base = b.cycle + 500
        tx.edges = [(c + base, x) for c, x in tx.edges]
        b.peers.append(tx)
        chip.wait_us(us(tx.end - b.cycle + 1000), drain=(0,))
        return base, chip.rx_pop(0), chip.verdict()

    b, (base, got, v) = await host_run(dut, [], body)
    record("uart_rx_fast_peer", verdict=v, pushed=got)
    check_blame(v, b, 0x32, 0, base, int(10 * bit), "uart_rx_fast_peer")


@cocotb.test()
async def windows_uart_d6(dut):
    """option-D retune from the toolchain: the d = 6 example fails under ROM 0 as shipped, and runs
    clean after loading the window table printed by `pemu_cc retune 0 uart_tx:d=6,pin=0`"""
    data = [0xA5, 0x3C]
    bit6 = 6 * step_cycles(0)
    rx = pr.UartReceiver(pr.UART_TX, bit6)
    win = LIB.windows("uart_tx_d6")

    def body(chip, b):
        chip.setup_lane(0, LIB.program("ex_uart_tx_d6"), LIB.package(win["rom"]))
        chip.tx_push(0, data)
        chip.run(1)
        chip.wait_us(us(len(data) * 10.5 * bit6 + 500))
        v1, rom_rx = chip.verdict(), list(rx.bytes)
        chip.run(0)
        chip.clear_verdict(0)
        chip.load_windows(0, win["windows"])
        rx.bytes.clear()
        chip.tx_push(0, data)
        chip.run(1)
        chip.wait_us(us(len(data) * 10.5 * bit6 + 500))
        return v1, rom_rx, chip.verdict()

    _, (v1, rom_rx, v2) = await host_run(dut, [rx], body)
    record("windows_uart_d6", rom_verdict=v1, window_verdict=v2, rom_received=rom_rx, received=rx.bytes)
    assert v1["fail"] and v1["host_valid"], v1
    assert clean(v2) and rx.bytes == data, (v2, rx.bytes)


# ---------------------------------------------------------------- SPI


@cocotb.test()
async def spi_ctl_slow_target(dut):
    """peer fault: target clock-to-out 14 cycles, MISO not settled; blame 0x91 on lane 1"""
    host = [0xA5, 0x3C, 0x00, 0xFF, 0x81, 0x7E, 0x55, 0x0F]
    tgt = pr.SpiTarget([0x96, 0x01, 0x80, 0xC3, 0x5A, 0xF0, 0x33, 0xE7], tco=14)
    first_miso = []

    class Probe:
        prev = None

        def step(self, cyc, out, oe, pad):
            m = pr.bit(pad, pr.MISO)
            if self.prev is not None and m != self.prev and pr.bit(pad, pr.CS) == 0:
                first_miso.append(cyc)
            self.prev = m
            return (0, 0)

    def body(chip, b):
        chip.setup_lane(1, LIB.program("spi_ctl_m0"), LIB.package(2))
        chip.run(2)
        got = chip.transfer(1, host)  # chunks of 7: RX never full
        chip.wait_us(us(8 * 600), drain=(1,))
        return chip.verdict()

    b, v = await host_run(dut, [tgt, Probe()], body)
    record("spi_ctl_slow_target", verdict=v, target_received=tgt.received)
    # transfer() stops streaming at a pending verdict: the blame falls in the first chunk of 7
    assert tgt.received == host[:7], tgt.received
    check_blame(v, b, 0x91, 1, first_miso[0] - 2 * step_cycles(2), 6 * step_cycles(2), "spi_ctl_slow_target")


@cocotb.test()
async def two_lanes(dut):
    """lane 0 UART TX and lane 1 SPI controller concurrently, both monitored, clean"""
    host = [0xA5, 0x3C, 0x00, 0xFF]
    peer = [0x96, 0x01, 0x80, 0xC3]
    rx = pr.UartReceiver(pr.UART_TX, UART_BIT)
    tgt = pr.SpiTarget(peer, tco=3)

    def body(chip, b):
        chip.setup_lane(0, LIB.program("uart_tx_d4"), LIB.package(0))
        chip.setup_lane(1, LIB.program("spi_ctl_m0"), LIB.package(2))
        chip.tx_push(0, [0x55, 0xC3])
        chip.run(3)
        got = chip.transfer(1, host)
        chip.wait_us(us(2 * 10.5 * UART_BIT + 800), drain=(1,))
        return got + chip.rx_pop(1), chip.verdict()

    _, (got, v) = await host_run(dut, [rx, tgt], body)
    record("two_lanes", verdict=v, uart=rx.bytes, spi_target=tgt.received, pushed=got)
    assert rx.bytes == [0x55, 0xC3] and tgt.received == host and got == peer, (rx.bytes, tgt.received, got)
    assert clean(v), v


# ---------------------------------------------------------------- I2C


@cocotb.test()
async def i2c_ctl_slow_target(dut):
    """peer fault: the target changes SDA 70 cycles after SCL falls (inside the high phase)"""
    host = [0xA0, 0x03, 0x11, 0x22, 0x33, 0xA1, 0x02]
    tgt = pr.I2cTarget(0x50, [0xC3, 0x5A], dd=70, ack_dd=8)

    def body(chip, b):
        chip.setup_lane(0, LIB.program("i2c_ctl_fm"), LIB.package(4))
        chip.tx_push(0, host)
        chip.run(1)
        chip.wait_us(us(14000), drain=(0,))
        return chip.rx_pop(0), chip.verdict()

    b, (got, v) = await host_run(dut, [tgt], body)
    record("i2c_ctl_slow_target", verdict=v, target_log=tgt.log, pushed=got)
    check_blame(v, b, 0x77, 0, tgt.high_changes[0], 3 * step_cycles(4), "i2c_ctl_slow_target")


def i2c_tgt_body(txs, t, host_bytes, drain, rounds, tail=500):
    def body(chip, b):
        chip.setup_lane(0, LIB.program("i2c_tgt_0x50"), LIB.package(6))
        chip.tx_push(0, host_bytes)
        chip.run(1)
        ctl = pr.I2cController(txs, t0=b.cycle + 400, **t)
        ctl.ops[0] = ("wait", 400)
        b.peers.append(ctl)
        for _ in range(rounds):
            chip.wait_us(us(1000), drain=drain)
            if ctl.done:
                break
        chip.wait_us(us(tail), drain=drain)
        return ctl, chip.rx_pop(0), chip.verdict()

    return body


@cocotb.test()
async def i2c_tgt_short_start_hold(dut):
    """peer fault: the controller holds START for 60 cycles (< 4.0 us Sm minimum); blame 0x82"""
    txs = [(("W", 0x50, [0x11, 0x22]), True), (("R", 0x50, 2), False), (("W", 0x52, [0xAA]), False)]
    t = dict(SM30, thd_sta=60)
    b, (ctl, got, v) = await host_run(dut, [], i2c_tgt_body(txs, t, [0x50, 0xA1, 0x36], (0,), 80))
    record("i2c_tgt_short_start_hold", verdict=v, controller_log=ctl.log, pushed=got)
    t_fault = ctl.start_cycles[0] + t["thd_sta"]
    check_blame(v, b, 0x82, 0, t_fault - step_cycles(6), 4 * step_cycles(6) + 8, "i2c_tgt_short_start_hold")


LONG = [0x10 + k for k in range(16)]


@cocotb.test()
async def i2c_tgt_long_write_drained(dut):
    """16-byte write to the target; the host drains RX while waiting: all bytes, clean, host valid"""
    txs = [(("W", 0x50, LONG), False)]
    _, (ctl, got, v) = await host_run(dut, [], i2c_tgt_body(txs, SM30, [0x50], (0,), 120))
    record("i2c_tgt_long_write_drained", verdict=v, controller_log=ctl.log, pushed=got)
    assert got == LONG, got
    assert clean(v), v


@cocotb.test()
async def i2c_tgt_long_write_undrained(dut):
    """the same write with a host that never drains RX: the lane's PUSH blocks at a full RX FIFO
    and the contract reports fail 0x56 (push missing); the host guard has recorded the full FIFO,
    so the verdict carries host_valid = False (the fail is not evidence of a chip fault)"""
    txs = [(("W", 0x50, LONG), False)]
    _, (ctl, got, v) = await host_run(dut, [], i2c_tgt_body(txs, SM30, [0x50], (), 120, tail=40000))
    record("i2c_tgt_long_write_undrained", verdict=v, controller_log=ctl.log, pushed=got)
    assert not v["host_valid"] and v["host_faults"], v
    assert v["fail"] and v["fail_code"] == 0x56 and not v["blame"], v
    assert got == LONG[:8], got


# ---------------------------------------------------------------- USB


@cocotb.test()
async def usb_ls_tx(dut):
    rx = pr.UsbLsReceiver(bit_cycles=20)

    def body(chip, b):
        chip.setup_lane(0, LIB.program("usb_ls_tx"), LIB.package(7))
        chip.tx_push(0, [0xC3, 0, 0x4B, 3, 0x01, 0x02, 0x03])
        chip.run(1)
        chip.wait_us(us(5000))
        return chip.rx_pop(0), chip.verdict()

    _, (got, v) = await host_run(dut, [rx], body)
    pk, bad_runs = rx.packets()
    record("usb_ls_tx", verdict=v, pushed=got, packets=pk, bad_runs=bad_runs)
    assert [(p["pid"], p["payload"]) for p in pk] == [(0xC3, []), (0x4B, [1, 2, 3])], pk
    assert all(p["sync_ok"] and p["pid_ok"] and p["crc_ok"] and not p["stuff_err"] for p in pk), pk
    assert bad_runs == 0 and len(got) == 2 and clean(v), (got, v)
