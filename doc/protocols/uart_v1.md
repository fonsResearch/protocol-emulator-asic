# UART 8N1, v1 (contract source document, step domain)

> **v2 tape-out (2026-11-11).** Clock 30 MHz (v1: 60 MHz). Shipped divisors and package names: `log/protocols_v2.md` and `pemu_cc list` (`doc/toolchain.md`). Values below in cycles or MHz are v1 unless marked v2; step-based contract parameters are unchanged unless `log/protocols_v2.md` says otherwise.

Status: v1 (2026-10-18), plan step 7. Contracts in `monitor_v1/src/library_v1.ml` are written from this document only; firmware is written afterwards (user decision: procedural isolation). The v0 document `uart.md` (cycle domain) stays for the slice.

## 1. Line format (common convention)

- One wire; idles at 1 (mark). A frame is a start bit (0), 8 data bits, least significant first, and a stop bit (1). No parity.
- Sources: the asynchronous start-stop format used by UART peripherals (no single normative standard). The receiver behaviour below follows the usual mid-bit sampling.

## 2. Time base

All times are in *steps* of the emulator lane that owns the protocol (one step per tick). A bit lasts d steps nominally. The host chooses the prescaler so that d steps match the baud rate (ISA v1 section 1). Pin values are the synchronised pad values seen in the step, the same for the lane and its monitor.

## 3. Transmit (chip drives the line; guarantee only)

The line is the pad level through the pull-up: line = !oe || out. Exact timing (tolerance 0): the transmitter is cycle-exact by construction.
- After the step in which the transmitter takes byte b from the host TX stream (step s), the line is high in steps s+1 and s+2. It is then low for d steps (start), carries b LSB first for d steps per bit, then is high for d steps (stop).
- No byte is taken while a frame is being sent (2 + 10d steps after a take).
- Progress (a frame starts while the host stream is non-empty) is a host-stream property. The monitor cannot observe the host FIFO, so this is not part of the contract.

## 4. Receive (environment drives the line)

Let s0 be a step in which the line reads 0 and read 1 in the previous step, while the receiver is idle (no frame in progress). s0 starts a frame. Parameters: d (steps per bit) and m (tolerance, steps), with d >= 2m + 2.

- **Assumption (sender behaviour; violation = blame).** For each bit k = 0 (start), 1..8 (data), 9 (stop), the line is constant over the bit's core, steps s0 + k d + m .. s0 + (k + 1) d - 1 - m. In the start core the line is 0, in the stop core it is 1. Transitions may occur only outside the cores. This allows a total misalignment of up to m steps between the sender's and the receiver's bit grids (baud error, synchroniser and tick quantisation).
- **Guarantee (receiver behaviour; violation = fail).**
  - For every frame the receiver pushes exactly one byte to the host RX stream, in a step of s0 + 9d .. s0 + 10d - 1 - m (within the stop bit's core, after its start).
  - Bit i of the pushed byte (i = 0..7) equals the line in step s0 + (i + 1) d + floor(d / 2), the centre of data bit i.
  - No byte is pushed between frames, or before the stop bit of the current frame.
- Host-stream assumption (outside the monitor): the host RX FIFO is never full while the lane runs (the A2 harnesses assume `rx_level` < 8 at every cycle, `formal/src/ag_pkg.ml` `rx_never_full`; the earlier wording "not full at the push" was weaker than what is proved, correction 2026-11-11, `doc/host.md` section 3.1).

## 5. Parameter sets for the ROM library

| package | d | m | example |
|---|---|---|---|
| `uart_rx_d8_m2` | 8 | 2 | 115200 baud at 60 MHz: P = 64 (65 cycles per step, 8 steps per bit, +0.16%) |
| `uart_tx_d4` (exists) | 4 | - | as step 6 |
