# Architecture v2 (tape-out candidate)

The chip as submitted: branch `v2-inc5-usb`, core commit d9d97d2, signed off by CI run
42426292730 (`log/increments_v2.md` section 5.1). This document is an overview with pointers.
The normative definitions are the documents in the "defined in" column.

## 1. Block structure

```
 host SPI (ui[0..2], uo[0]) ──> host port + register file ──┬──> lane 0 ── 256x16 SRAM ─┐
                                                            ├──> lane 1 ── 256x16 SRAM ─┤ pin mux ── uio[7:0]
                                                            └──> monitor engine <───────┘ (own masks)
                                                                 (2 x 5 slots, ROM library,
                                                                  window tables, verdict) ──> uo[1] fail, uo[2] blame
```

| block | what | defined in |
|---|---|---|
| lane (x2) | ISA v1 driver: 16-bit instructions from its own 256x16 SRAM macro, one step per prescaler tick (divisor P), 8-byte TX and RX FIFOs, serializer (NRZI, stuffing, CRC5/16, pair mode), owns a subset of `uio[7:0]` | `doc/isa/isa_v1.md`, `doc/interface_v1.md` |
| monitor engine | per lane: observation front end, 14-entry predicate bank, 5 serial unit slots, ROM package select and pin remap; shared verdict block (fail and blame, code, unit, step stamp) | `doc/contracts/monitor_isa_v1.md` |
| ROM library | 8 compiled packages (contract programs), selected per lane by index | `rtl_v1/src/rom_lib.ml` (`v2_inc5`), `pemu_cc list` |
| window tables (option D) | per lane, host override of the 7 timing windows of the selected ROM package | monitor_isa_v1.md section 8, `doc/toolchain.md` section 3.2 |
| host port | SPI mode 0 target, register file (lanes at 0x10/0x20, monitor at 0x40-0x7F) | `doc/interface_v1.md` section 5 |

Build options on in this build (`log/increments_v2.md`): `PEMU_SLOTS=5` (5 monitor slots per lane),
`PEMU_VPIPE=1` (registered firing record before the verdict), `PEMU_PWIN=1` (window tables),
`PEMU_LPIPE=1` (pipelined slot schedule: slot u runs at tick + 1 + u from latched copies),
`PEMU_LOADABLE=rom` (logic-ROM contracts only), `PEMU_LIB=v2inc5`.

## 2. Packages

| ROM | package | pins | P at 30 MHz | step |
|---|---|---|---|---|
| 0 | UART TX, d = 4 steps/bit | uio0 | 64 | 115385 baud |
| 1 | UART RX, d = 8, tolerance m = 2 | uio1 | 32 | 113636 baud |
| 2 | SPI controller mode 0, h = 2 | uio4 CS, uio5 SCLK, uio6 MOSI, uio7 MISO | 7 | SCLK 0.94 MHz [arithmetic: 30 MHz / (8 x 2 x 2)] |
| 3 | SPI target mode 0 | as 2 | 7 | |
| 4 | I2C controller Fm | uio2 SCL, uio3 SDA (open drain) | 7 | 0.27 us |
| 5 | I2C controller Sm | as 4 | 29 | 1 us |
| 6 | I2C target Sm, address from the host config byte | as 4 | 5 | 0.2 us |
| 7 | USB-LS TX (DATA packets) | uio0 D+, uio1 D- | 19 | 1 bit (1.5 Mbit/s) |

Firmware for each is in `spec_v1/src/programs_v1.ml`, disassembled by `pemu_asm shipped`. A lane
can also run any firmware unmonitored (package disabled), e.g. SPI modes 1-3.

## 3. Timing, area, admission

- Clock 30 MHz (CLOCK_PERIOD 33.33 ns). Slow corner (1.08 V, 125 C) setup slack +5.827 ns,
  hold +0.075 ns; typical +16.189 ns, fast +22.253 ns. Std-cell area 381,949 um^2, 48.56 %
  utilisation of 6x4. Route DRC, KLayout DRC, LVS and antenna 0. 86 max-slew and 6 max-cap
  warnings remain (`log/increments_v2.md` section 5.1).
- Worst path: `mon_slot_0[2]` (lane-1 slot sequencer) to `mon_vp_code0[7]` (verdict code).
- Admission: RUN of a lane with an enabled package needs P >= 5 (pipelined schedule, P >= slots;
  monitor_isa_v1.md section 7). All shipped divisors satisfy it.
- Latency: unit u of step t runs in cycle t + 1 + u (pipelined schedule). Its firing reaches the
  verdict block and pins one cycle after that, plus the verdict-pipe register, and a blame reaches
  the lane at t + u + 2. VERDICT records the step stamp t, so the reported time does not depend
  on the slot (monitor_isa_v1.md sections 6-7; C3 analysis in `log/proofs_v2.md` section 7).

## 4. What is verified, and where

| claim | evidence |
|---|---|
| package A2: no fail without an earlier blame (U), per package | `log/protocols_v2.md`: unbounded for UART TX/RX, SPI controller/target, USB-LS TX; bounded for the I2C controller (bmc3, 76-77 frames) and the I2C target (co-sim and checkpoint BMC, with assumption EA1) |
| every contract check can fire as the first verdict | `log/witness_v2.md` (103/103) |
| lane RTL = lane spec (A1), monitor lane = monitor spec (R1) | `log/proofs_v2.md` |
| chip composition (C3): chip verdict = harness verdict except a documented host-clear window | `log/proofs_v2.md` section 7 |
| final netlist = RTL (E4/E5, 2,748/2,748 pairs, with negative controls) | `log/increments_v2.md` section 5.1 |
| mutation campaign and oracle independence | `log/campaign_v2.md`, `log/kill_matrix_v2.md` |
| demo board and host package on RTL and gate level | `log/demo_v2.md`, `doc/host.md` |

Assumptions the proofs rest on but the chip does not check: physical assumptions PH1-PH8
(`doc/concept/assume_guarantee.md`), and host-stream assumptions. The host keeps the RX FIFO from
filling, for all packages except UART TX. There are also package-specific TX-side conditions
(e.g. SPI target: TX data present when the lane pops; I2C target: config byte present at start;
`doc/protocols/*.md`). The host package guards the RX condition (`doc/host.md` section 3.1).

## 5. Known limits

- Not tested on silicon or on a real demo board. The RP2350 pin mapping is open (`doc/host.md`
  section 2.1).
- USB facts still from memory: CRC16 preset all ones; bit-stuffing range (`doc/protocols/usb_ls_v1.md`).
- USB and UART share uio0/uio1, so they cannot run on the two lanes at once. Whether overlapping
  OWN settings across lanes are refused was not checked (`log/increments_v2.md` section 5).
- Contract-mutation survivors: 25/100 after the witness oracle (`log/witness_v2.md` section 5).
