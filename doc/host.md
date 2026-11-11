# Host package `pemu` (RP2350, MicroPython)

Plan v5 step 10. `host/pemu/` is the host-side driver of the chip: lane setup from toolchain
outputs, streams, run control, verdict decoding, and a guard for the host-stream assumption the
monitor cannot see. It is plain Python in the MicroPython subset: no dataclasses, typing or
pathlib, `json` and `time` only. It also runs unchanged under CPython, which is how it is
tested against the virtual demo board (section 5).

Status: verified against the RTL of the tape-out candidate in simulation only. It has not been
run on an RP2350 or on silicon (no hardware in this project, see `log/demo_v2.md`).

## 1. Files

| path | content |
|---|---|
| `host/pemu/__init__.py` | `Pemu`, `PemuError`, `BitBangPort`, `load(root)` (toolchain outputs on the filesystem) |
| `host/pemu/port.py` | `BitBangPort`: SPI mode 0 by GPIO (`machine.Pin`) |
| `host/pemu/device.py` | `Pemu`: register-level and lane-level API, verdict, RX-full guard |
| `host/assets/` | toolchain outputs to copy to the board: `library.json`, `programs/*.json`, `windows/*.json` |
| `host/tools/build_assets.py` | rebuilds `host/assets/` from `pemu_asm` / `pemu_cc` (`--check` compares) |

## 2. Port

The chip's host port is SPI mode 0: CS_n, SCK and MOSI on `ui_in[2:0]`, MISO on `uo_out[0]`
(`doc/interface_v1.md` section 4). Transfers are MSB first. MISO is sampled before each rising
SCK edge, and the SCK half period must be at least 4 chip cycles (133 ns at 30 MHz). A port
object has `xfer(list_of_bytes) -> list_of_bytes` (one CS-low transaction) and `sleep_us(us)`.

```python
from machine import Pin
import pemu
port = pemu.BitBangPort(Pin(CS, Pin.OUT), Pin(SCK, Pin.OUT), Pin(MOSI, Pin.OUT), Pin(MISO, Pin.IN))
```

### 2.1 Board wiring (open)

Which RP2350 GPIOs reach `ui_in[0..2]` and `uo_out[0]` on the Tiny Tapeout demo board, and how the
board's own firmware selects the project and drives the clock and reset, is not taken from a
datasheet here. Check it against the Tiny Tapeout demo-board documentation for the IHP shuttle
before first use. The package does not assume any pin numbers.

## 3. API

| call | effect |
|---|---|
| `check_id()` | ID register must read 0xA1 |
| `setup_lane(lane, program, package=None, p=None)` | lane config (own, od, P, cfg, cfg2), firmware load, ROM package select and remap; `package=None` runs the lane unmonitored (needs `p`) |
| `load_windows(lane, windows)` | option-D window override (`pemu_cc retune` output; 8 entries, 12 bits) |
| `tx_push(lane, data)`, `rx_pop(lane)` | host streams; `rx_pop` returns the bytes drained by `wait_us` plus the FIFO contents |
| `transfer(lane, data, chunk=7)` | for packages that push one RX byte per TX byte (SPI controller): push at most 7 bytes, wait for their replies, pop, repeat; RX never full whatever the host's speed; stops at a pending verdict |
| `run(lanes)` | CTRL RUN bits (bit 0 lane 0, bit 1 lane 1) |
| `wait_us(us, drain=(), poll_us=200)` | wait, polling every `poll_us`: RX-full guard on running lanes, RX drain for lanes in `drain` |
| `verdict()` | fail/blame flags, lanes, codes, units, step stamps (VERDICT 0x40..0x4B), plus `host_valid` and `host_faults` |
| `status()`, `fault()` | STATUS and FAULT registers decoded |
| `clear_verdict(lanes_running)` | CTRL CLR_VERDICT; also clears the host guard record |

Admission: RUN of a lane with an enabled package takes effect only if its P is at least 5 on the
tape-out build (`doc/toolchain.md` section 3.1). Every ROM package's own P satisfies this.

### 3.1 Host-stream guard

The package proofs (A2) assume that the lane's RX FIFO is never full. The harness encodes this
as the environment violation `rx_level = 8` at any cycle (`formal/src/ag_pkg.ml`, `rx_never_full`).
It applies to every ROM package except UART TX, which never pushes. The monitor cannot observe
the RX FIFO. With a full RX FIFO the lane's `PUSH` blocks (ISA v1 section 5), and a contract can
then report the missing push as a chip fail: the I2C target reports fail 0x56, a chip guarantee
violation caused by the host (`log/witness_v2.md` section 3).

Decision 2026-11-11 (user delegated): document the requirement and guard it on the host; no RTL
change. The guard records RX level 8 on a running lane in three places: before every pop
(`rx_pop`, `wait_us` drain), at every `wait_us` poll, and in `verdict()`. `verdict()` then
reports `host_valid = False`. Such a run is outside the proved envelope, and a fail in it is not
evidence of a chip fault.

Exactness: only host pops lower the RX level. If every pop goes through this package, a full
episode lasts until a pop, which sees it first, or until the end of the run, which `verdict()`
sees. So the guard flags a run if and only if the RX level reached 8 on a running lane, which is
the harness condition. Raw `read()` calls on the RX data register bypass the guard.

Documentation discrepancy found here: `doc/protocols/uart_v1.md` and `spi_v1.md` state the
weaker assumption "the RX FIFO is not full at the push", and `usb_ls_v1.md` states that USB
needs no host-stream assumption. The proofs assume "never full" for all three. A run with exactly
8 undrained bytes and no further push satisfies the documented form but is outside the proof.
The protocol documents are corrected to the proved form (plan step 10 documentation pass).

## 4. Assets

`host/tools/build_assets.py` writes `host/assets/` from the toolchain only:
- `library.json`: `pemu_cc json`, the ROM library with P, remap and windows per package.
- `programs/<name>.json`: `pemu_asm asm -f json` of the shipped firmware (disassembled by
  `pemu_asm shipped`, then reassembled) and of `toolchain/examples/*.s` as `ex_<name>`.
- `windows/uart_tx_d6.json`: `pemu_cc retune 0 uart_tx:d=6,pin=0`.

These go through the text path (disassembly, then assembly). They are identical to the step-8
demo assets (`test/demo/assets.json`, written directly from OCaml) in every program image, lane
configuration, package table and window table.

## 5. Verification against the virtual demo board

`test/demo/test_host_pkg.py`: 11 scenarios. Each scenario body is a blocking function that uses
only `pemu` and `host/assets`, as it would on the RP2350. It runs in a cocotb bridge thread, and
the package reaches the chip through `SimPort` (`test/demo/host_port.py`): the same SPI waveform
as the step-8 host, with `sleep_us` at 30 cycles per microsecond. The device models are the step-8
peers (`test/demo/peers.py`). Run:
`cd test/demo && DEMO_OUT=$PWD/results/rtl_host make COCOTB_TEST_MODULES=test_host_pkg FST=`.

| scenario | expectation |
|---|---|
| uart_tx_clean | 5 bytes received, clean |
| uart_tx_bad_start | fail 0x13, lane 0 |
| uart_rx_fast_peer | blame 0x32 within the first frame |
| windows_uart_d6 | d = 6 example: fail under ROM 0 as shipped; clean with the retuned windows |
| spi_ctl_slow_target | blame 0x91, lane 1, stamp window as step 8 |
| two_lanes | UART TX and SPI controller concurrently, clean |
| i2c_ctl_slow_target | blame 0x77 |
| i2c_tgt_short_start_hold | blame 0x82 |
| i2c_tgt_long_write_drained | 16-byte write, host drains: 16 bytes, clean, host valid |
| i2c_tgt_long_write_undrained | host never drains: fail 0x56 with `host_valid = False`, 8 bytes |
| usb_ls_tx | two packets decoded (SYNC, PID, CRC, stuffing), clean |

### 5.1 Results (2026-11-11)

11/11 pass on the RTL (`src/`, 66 s) and 11/11 on the signed-off gate-level netlist (final/nl of
CI run 42426292730, sha256 b450fe7c..., 266 s). `compare_runs.py results/rtl_host
results/gl_host`: 0 differing records.

| scenario | verdict | stamp | host_valid |
|---|---|---|---|
| uart_tx_clean | clean | | yes |
| uart_tx_bad_start | fail 13 lane 0 | 7236 | yes |
| uart_rx_fast_peer | blame 32 lane 0 | 6995 | yes |
| windows_uart_d6 | ROM 0 as shipped: fail; retuned: clean | | yes |
| spi_ctl_slow_target | blame 91 lane 1 | 7134 | yes |
| two_lanes | clean | | yes |
| i2c_ctl_slow_target | blame 77 lane 0 | 43274 | yes |
| i2c_tgt_short_start_hold | blame 82 lane 0 | 32122 | yes |
| i2c_tgt_long_write_drained | clean, 16 bytes | | yes |
| i2c_tgt_long_write_undrained | fail 56 lane 0, 8 bytes | 79762 | no (25 guard records) |
| usb_ls_tx | clean, 2 packets | | yes |

Every verdict and stamp of a scenario that also exists in step 8 (`log/demo_v2.md`) is identical,
except spi_ctl_slow_target (7134 here, 7850 in step 8), where `transfer()` pushes the TX bytes
after RUN instead of before.

Two findings while writing these scenarios, both about the host-stream assumption:
1. The step-8 SPI controller scenarios leave 8 bytes in RX without a drain. That is outside the
   proved envelope (RX never full), although no further push happened. The first version of
   this run flagged it (`host_valid = False`).
2. Draining by polling is not enough for the SPI controller at P = 7. All 8 byte exchanges
   (about 300 cycles each) finish before a 200 us poll, and a bit-banged MicroPython status read
   is itself of the order of 100 us (estimate, not measured on an RP2350). `transfer()` (chunks of
   at most 7) keeps RX below 8 independent of host speed.

### 5.2 MicroPython

`micropython host/tools/upy_check.py` (unix port, MicroPython v1.29.0, conda-forge) imports the
package and drives `BitBangPort` through fake `Pin` objects wired to a small SPI-target model with
the chip's framing. It checks ID, register reads, writes, and the guard flag: ok. This shows that
the package parses and runs under MicroPython and that the bit-bang framing is right. It says
nothing about RP2350 pin timing or the demo board, which have not been tested.


## Note: TX FIFO overflow (2026-11-11)

A write to a full TX FIFO is dropped by the chip without an error. `Pemu.tx_push` does not check
the level; callers that may push more than the free space must wait for room first (`fifo_status`),
as the 1-Wire driver `host/pemu/onewire.py` does (log/flexibility_v2.md section 4).
