# Protocol packages on v2 (plan v5 step 6)

v2 minimum ships 4 of the 15 v1 packages in its logic ROM (`Rom_lib.minimum_v2`, decision V2-5).
The other 11 are increments or dropped (doc/decisions/arch_v2_options.md, log/ci_results_v2.md section 3).

## 1. Why the v1 A2 results carry over

`log/harness_audit_v2.md` lists conditions C1-C4 under which the spec-level A2 harness
(`formal/src/ag_pkg.ml`) carries to a new microarchitecture. Status on v2-6x4:

- C1, the lanes implement `Lane_circuit` exactly: holds. Lane A1 is carried because the lane
  sources are byte-identical to v1-tt (log/proofs_v2.md section 8).
- C2, the monitor refines `Mon_spec` per step: holds. R1 r1v2_s5_u0..u4 PASS, negatives FAIL.
- C3, the top composes lane and monitor as ag_pkg does: holds. Differential cyclesim, log/proofs_v2.md
  sections 7.1-7.4, plus the stamp-order argument in 7.5.
- C4, every shipped package is admissible at its documented P: holds. `Rom_lib.admissibility_violations
  ~slots:5` is empty for the v2 minimum; negative tests are in `rtl_v1/test/test_rom_lib_v2.ml`.

The A2 inputs are unchanged since the v1 results: `git diff v1-tt v2-6x4` is empty for
`formal/src/ag_pkg.ml`, `monitor_v1/src/` apart from mon_engine/mon_lane (which A2 does not instantiate), and
`spec_v1/src/`. A2 is not re-run; bounded results stay bounded.

## 2. Package table

Divisors at the 33 MHz v2 clock. Shipped values are from `Rom_lib.minimum_v2_with_p`; increment
values are estimates, to be fixed in each increment.

| # | package | v1 A2 (spec level) | v2 status | P at 33 MHz | chip RTL vs Psim (log/proofs_v2.md 7.x) | gate-level vector |
|---|---|---|---|---|---|---|
| 0 | uart_tx d4 | U proved (dprove 9 s), N1 + 2 negatives | **shipped** | 71 | 7.1, 7.3 (A, B, D, F, K at P = 71) | v1_rom_uart, v2_spi_tgt_uart_tx |
| 1 | uart_rx d8 m2 | U proved (681 s), N1 + 3 negatives | **shipped** | 35 | 7.1, 7.2 (sweep, 6 random), 7.3 (C, E, J, L at P = 35) | v2_spi_ctl_uart_rx |
| 2 | spi_ctl m0 h2 | U proved (65 s) | **shipped** | 7 | 7.1, 7.2 (sweep j = 4, 4 random), 7.3 | v2_spi_ctl_uart_rx |
| 3-5 | spi_ctl m1-m3 | U proved (59-77 s) | increment 4 | 7 | - | - |
| 6 | spi_tgt m0 h3 g6 | U proved (898 s) | **shipped** | 7 | 7.1, 7.2 (6 random), 7.3 (C, E, G, K) | v2_spi_tgt_uart_tx |
| 7-9 | spi_tgt m1-m3 | m2/m3 proved; m1 via the CPOL symmetry lemma | increment 4 | 7 | - | - |
| 10 | i2c_ctl Fm | bounded (bmc3, 77 frames) | increment 1 | about 8 (367 kHz) | - | - |
| 11 | i2c_ctl Sm | bounded (bmc3, 76 frames) | increment 1 | about 32 | - | - |
| 12 | i2c_tgt Fm | bounded with EA1 (co-sim + checkpoint BMC) | **dropped** | needs P + 1 <= about 2.8; 5 slots need P >= 4 | - | - |
| 13 | i2c_tgt Sm | bounded with EA1 | increment 3 | <= 17; step parameters (59/69/59 at P = 3, 60 MHz) to re-derive | - | - |
| 14 | usb_ls_tx | U proved (1,246 s); contents G7 bounded | increment 5 | 21 (exact, 22 cycles per bit) | - | - |

## 3. D13 recurrence check (chip level, own P)

Every shipped package runs on the v2 top RTL at its documented 33 MHz divisor and is compared
against Psim in `rtl_v1/test/test_c3_two.ml`. The scenarios match in every cycle of the monitor-input
stream, pins and pushes, and in the verdict:
- J: UART RX at P = 35 with a 115200-baud sender at 33 MHz, 6 bytes, beside the SPI controller at P = 7;
- K: UART TX at P = 71 beside the SPI target at P = 7;
- L: UART RX at P = 35 with a short stop bit (blame 0x33@9217) beside the SPI controller with tco 14
  (blame 0x91@113; global first blame = lane 1).

## 4. Gate-level vectors per protocol family

`rtl_v1/bin/dump_tt_vectors_v1.exe` (PEMU_LIB=v2min PEMU_LOADABLE=rom PEMU_SLOTS=5) now records two v2
scenarios with a protocol peer in the loop. The pad resolves the chip's current drive and the peer's drive
each cycle, and the peer's response is written into the rows, so a replay needs no peer model.

| vector | cycles | content | exporter notes (RTL) |
|---|---|---|---|
| v2_spi_ctl_uart_rx | 28,085 | L1 SPI ctl m0 P = 7, target peer with a MISO hold glitch (frame 3, bit 4); L0 UART RX P = 35, 115200-baud sender | blame 0x91, unit 4, lane 1; UART RX bytes 55 C3 0F A5; SPI read CB for C3 (the glitched bit); peer received all 8 host bytes |
| v2_spi_tgt_uart_tx | 24,847 | L1 SPI tgt m0 P = 7 with release on blame, controller peer raising CS early on frame 5; L0 UART TX P = 71; then clear fault L1 + CLR_VERDICT | blame 0x52, unit 0, lane 1; lane 1 faulted after 5 frames; flags 0 after the clear |

The v1 vectors regenerate byte-identically. RTL replay (`make` in test/, TT wrapper + COMBDLY core
+ IHP SRAM models): 5/5 PASS, 0 mismatches, comparator negative control detected. Gate-level replay
on the round-1 netlist: see section 5.

Spec-precision note: after CLR_VERDICT, VERDICT reads 0x04. The first-blame lane bit stays set while
the flag is clear. monitor_isa_v1.md section 6 says code, unit and time read 0 while the flag is
clear, and says nothing about the lane bits. This is to be stated in the spec (no RTL change planned).

## 5. Gate-level replay

Local replay of all vectors on the round-1 routed netlist (run 40563302709, 48 MHz build of the same
RTL; `final/nl` netlist, 75,260 instances; Icarus with the PDK cell models): 5/5 PASS. v1_reset_mid,
v1_rom_uart, v2_spi_ctl_uart_rx and v2_spi_tgt_uart_tx have 0 mismatches each, and the comparator
negative control is detected. The simulation binary references 75,259 `sg13cmos5l_*` cells and no RTL
core module. The 33 MHz rebuild is a new netlist, so CI gl_test repeats this replay on it (test.py now
globs `v2_*.vec` as well as `v1_*.vec`).

## 6. Figure

`log/fig/package_status_v2.png`. Footnotes: * SPI target m1 is covered via the CPOL symmetry lemma;
** USB-LS TX contents (G7) are bounded. For packages not yet shipped, "carried" means the A2 result applies
once the package ships at an admissible P (condition C4).
