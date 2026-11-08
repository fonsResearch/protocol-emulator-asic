# Virtual demo board, v2 tape-out candidate (plan step 8)

Date: 2026-11-08. Design: branch v2-inc5-usb, commit d9d97d2 (library v2inc5, 30 MHz, packages
0-7). Gate-level netlist: `runs/wokwi/final/nl/tt_um_dean_protocol_emulator.nl.v` of the signed-off
CI run 42426292730 (GDS_logs artifact 13599317641; sha256 b450fe7c24d63d1107968b43c271f7826458913ce80c18aab3c588620c75abb0).
The RTL simulated (`src/pemu_core_v1m.v`, `src/tt_um_dean_protocol_emulator.v`) is byte-identical to
the `src/` of that run's tt_submission (checked by sha256).

## 1. What the board is

`test/demo/` runs the chip, as RTL or as the gate-level netlist, on a simulated board with cocotb
2.0.1 and Icarus 13.0:

- `pemu_host.py`: the board loop and the host API. Every cycle the board resolves the uio pads from
  the chip's `uio_out`/`uio_oe` and the attached device models. Open-drain pins (uio2/uio3, I2C) are
  wired-AND, undriven pins are pulled up. The host SPI port (ui_in[2:0], MISO on uo_out[0], mode 0,
  half period 6 cycles) is bit-banged. The `Pemu` class is the host API (`id`, `lane_config`,
  `load_program`, `select_package`, `load_windows`, `tx_push`, `rx_pop`, `run`, `verdict`,
  `clear_verdict`). Its method names and arguments are the ones the RP2350 MicroPython package of
  plan step 10 will use.
- `assets.json`: assembled firmware images and the ROM package table (index, P, remap, windows),
  exported from the OCaml toolchain by `rtl_v1/bin/export_demo_assets.exe`. The host has no
  assembler or contract compiler of its own.
- `peers.py`: device models written from the protocol documents, not from the OCaml peers
  (`protocols_v1/src/peers.ml`). They are a UART sender and receiver, an SPI mode-0 target and
  controller, an I2C target and controller (cycle timing by UM10204 parameter names, waits for SCL
  high), and a USB-LS receiver that decodes the chip's D+/D- after the run: bit times,
  NRZI, bit unstuffing, SYNC, PID check nibble, CRC16, EOP.
- `test_demo.py`: 17 scenarios. `run_demo.sh rtl|gl` runs one simulator process per scenario and
  writes `results/<mode>/<scenario>.{json,log,vcd.gz}`.

Independence (fact vs estimate): the models share no code with the OCaml environment, and the
host uses only the toolchain's output files. They were written by the same author as the
contracts, so the independence is partial. The OCaml C3/inc tests were used only to choose fault
magnitudes and host streams.

## 2. Checks

- Clean runs: the data the peer received and the bytes the chip pushed equal the expected values,
  and VERDICT is empty.
- Peer faults: blame is raised (not fail) with the expected cause code and lane, and the stamp lies
  in a window after the instant the peer misbehaved. That instant is ground truth from the peer
  model: the cycle of the late MISO change, the early CS rise, or the target's own SDA move with
  SCL high.
- Chip faults (firmware mutants): fail with the expected code.

Stamp to board time: board cycle = rst_n release + stamp + 4. The constant is measured by the
`calibrate` scenario. In it, the bad-start mutant's fail 0x13 is stamped 7236, and the pad edge of
the step that decides it is at board cycle 7250 = 10 + 7236 + 4. The 4 cycles are 2 for the reset
synchroniser and 2 for the board's falling-edge pad sampling. This is a single constant, not fitted
per scenario.

## 3. Results

All 17 scenarios pass on RTL and on the gate-level netlist.

| scenario | what | verdict | stamp | blame - fault instant (cycles) |
|---|---|---|---|---|
| calibrate | uart_tx bad-start mutant | fail 13 lane 0 | 7236 | |
| uart_tx_clean | 5 bytes at 115200 | clean | | |
| uart_tx_bad_start | firmware mutant (start bit 5 steps) | fail 13 lane 0 | 7236 | |
| uart_rx_clean | 6 bytes, nominal baud | clean | | |
| uart_rx_fast_peer | peer 8 % fast | blame 32 lane 0 | 6995 | 969 after frame-0 start |
| spi_ctl_clean | 8 bytes each way, target tco 3 | clean | | |
| spi_ctl_slow_target | target tco 14 cycles | blame 91 lane 1 | 7850 | 9 |
| spi_tgt_clean | controller hp 40 | clean | | |
| spi_tgt_early_cs | CS raised after 9 SCLK edges, frame 2 | blame 52 lane 1 | 9810 | 12 |
| i2c_ctl_clean | Fm, write 3, read 2 | clean | | |
| i2c_ctl_slow_target | read data 70 cycles after SCL fall | blame 77 lane 0 | 43274 | 10 |
| i2c_ctl_late_ack | ACK 70 cycles after SCL fall | blame 77 lane 0 | 39042 | 10 |
| i2c_tgt_clean | Sm controller at 30 MHz minima | clean | | |
| i2c_tgt_short_start_hold | tHD;STA 60 cycles (2.0 us) | blame 82 lane 0 | 32122 | 4 |
| usb_ls_tx | DATA0 (0 bytes) and DATA1 (01 02 03) | clean; both packets decode, CRC16 correct | | |
| windows_uart_d6 | d6 firmware: ROM d4 contract, then loaded d6 windows | fail 13, then clean | | |
| two_lanes | UART TX lane 0 + SPI controller lane 1 | clean | | |

UART fast peer, estimate: the drift is 8 % of 260.4 = 20.8 cycles per bit, so it exceeds the
contract's 2-step tolerance (66 cycles) after about 3.2 bits. The blame comes 969 cycles = 4.0 bit
times of the fast peer after the frame starts.

RTL vs gate level:
- `compare_runs.py`: all 17 JSON records are identical (verdict codes, stamps, pushed data, peer
  logs).
- `check_vcd.py --compare`: the settled values of ui_in, uio_in, uio_out, uio_oe, uo_out and rst_n
  are identical at every clock edge of every scenario (21,767-109,919 edges each).
- Negative control for the comparator: spi_ctl_clean vs spi_ctl_slow_target gives 14,148 differing
  edges.

Run time: RTL about 70 s for all 17 scenarios; gate level 5 min 24 s (about 1,800 cycles/s).

## 4. I2C controller data-delay sweep (30 MHz, Fm P = 7, step 8 cycles)

`DEMO_I2C_DD=<dd>` on `i2c_ctl_slow_target`, RTL (records not committed; rerun to reproduce):

| dd (cycles after SCL fall) | target SDA move with SCL high | verdict | read data |
|---|---|---|---|
| 8, 30, 40, 46 | no | clean | correct |
| 50, 54, 58 | yes | clean | correct |
| 62, 66 | yes | blame 77 | correct |
| 70, 74 | yes | blame 77 | wrong (sampled before the move) |

The band dd 50-58 is a change within the first monitor step of the high phase, before the read
sample. The package tolerates it by design: the design notes D4/D5 in `Library_v1.i2c_ctl` say SCL
observed high may lag the line by up to one step, here 267 ns. The bus is still I2C-illegal there,
but the monitor cannot see it at this step resolution. Every move that can corrupt the read is
blamed. At 33 MHz (P = 8) the OCaml run blames dd 70 too (test_inc1). Estimate, not measured: the
tolerated band is about one step wide at any clock.

## 5. Board-side bugs found during bring-up

All of these were in the Python models or scenarios, none in the chip. Each fix is justified by the
protocol, not by matching the chip:

1. SPI target loaded the next byte both after the 8th SCLK edge and at the next CS fall, so it
   skipped every other byte. Fixed: one byte per 8 edges.
2. I2C target, after the controller ACKs a read byte, advanced the bit index at the first SCL fall
   and dropped the MSB of the next byte.
3. I2C target treated its own delayed SDA edges as START/STOP and reset itself. With that bug the
   late-ACK run looked like an unblamed peer fault. After the fix it is blamed (77). I first read it
   as a contract gap. It was not, and nothing was changed in the contract.
4. USB receiver flagged the 4,205-cycle idle J between packets as off-grid. The grid check now
   applies only inside packets.
5. windows_uart_d6 left one byte in the TX FIFO from the first phase.

## 6. Limits

- The gate-level simulation is functional and zero-delay. It checks the netlist's logic, not its
  timing; timing is covered by the STA sign-off (log/increments_v2.md section 5.1).
- Board pads are ideal: no pad delay, and one pad sample per clock. Asynchronous inputs and
  metastability are not modelled; the 2-flop synchronisers are present in RTL and GL.
- Waveforms are gzip VCD of the top-level pins (tb.v dumps depth 1). `WAVE=fst` writes Icarus FST
  instead. No FST reader was available locally to check those files, so FST is not the default.
- The host API is Python coroutines here. The MicroPython package on the RP2350 is plan step 10.

## 7. Reproduce

```
export PDK_ROOT=<repo>/.toolchain/pdk
cd test/demo
./run_demo.sh rtl
GL_NETLIST=<final/nl netlist> ./run_demo.sh gl
python3 compare_runs.py results/rtl results/gl
python3 check_vcd.py --compare results/rtl results/gl
```
