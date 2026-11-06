# Increment 2: loadable contracts on the v2 serial engine (options study, 2026-11-06)

**Fact** = measured here (commands below) or read from a log; **estimate** = judgement.

## 1. Why the v1 path does not carry over

- v1 loads only units 6/7 of the 8-unit parallel engine; with the v2 serial engine at 5 slots it does not
  elaborate (`Mon_spec.n_units = 5` fails, arch_v2_options.md V2-1). [fact]
- v1 cost +170k um^2 per loadable lane (log/pd_probe_6x4.md). [fact]
- Area budget: the 30 MHz v2 + increment-1 build uses 335,982 um^2 std cells + 2 macros = 43.5 % of
  the 902,417 um^2 core (CI run 42160150374). Headroom to 55 % / 60 % total: about 104k / 149k um^2.
  The routability limit of this floorplan is not measured above 43.5 %. [fact for the use, estimate
  for the limit]

## 2. Measurements (local synthesis, flow/map/map_v1m.sh, typ area / slow logic depth without wires)

`rtl_v1/bin/probe_loadable.exe rom|gen|stats`: one Mon_lane with 5 slots.

| lane form | area | flops | slow depth |
|---|---|---|---|
| ROM (v2inc1 tables and instruction ROM, constant-folded) | 52,526 um^2 | 385 | 8.48 ns |
| general (all tables + five 82-bit IR words as free inputs; storage excluded) | 104,454 um^2 | 443 | 7.36 ns |

Generality costs about +52k um^2 of logic per lane; logic depth does not grow. [fact]

Storage on top (cell areas from the typ liberty: dfrbpq_1 49.0, dlhq_1 30.8 um^2; write logic excluded):

| item | bits | as flops | as latches |
|---|---|---|---|
| context (14 predicates x 29, 7 windows x 12, 15 codes x 9, 5 starts x 7, 5 guards x 26) | 790 | 38.7k | 24.3k |
| IR caches, 5 units x 82 | 410 | 20.1k | 12.6k |
| store macro RM_IHPSG13_1P_256x16 (the largest single macro in the PDK here) | 4096 | 28.1k (macro) | |

Instruction counts (82-bit instructions; `stats` mode) and store words needed (6 per instruction + 56 header):

| package | units | instr | store words | distinct bodies w/o next/alt |
|---|---|---|---|---|
| uart_tx | 2 | 14 | 140 | 13 |
| uart_rx | 2 | 32 | 248 | 17 |
| usb_ls_tx | 5 | 27 | 218 | 16 |
| spi_ctl m0-m3 | 5 | 63-64 | 434-440 | 30-31 |
| spi_tgt m0-m3 | 5 | 86-87 | 572-578 | 33-34 |
| i2c_tgt | 5 | 107 | 698 | 40 |
| i2c_ctl | 3 | 143 | 914 | 59 |

One 256x16 store holds a package of at most 33 instructions [fact, arithmetic]. A body dictionary
(68-bit bodies + one word per pc) still needs about 294 words for spi_tgt and 440+ for i2c_ctl [estimate],
and keeps 6+ dependent reads per pc change, so compression does not reach SPI/I2C with one macro.
Reading instructions from the store every slot stays excluded (6 reads per instruction, 5 slots, P = 7).

## 3. Options (per loadable lane; area deltas are estimates built from the facts above)

| option | area delta | utilisation | capacity / flexibility | verification cost |
|---|---|---|---|---|
| A. Lane 1 fully loadable (lane 1 ROM removed; lane 0 keeps the ROM library), one 256x16 store, 5 IR caches, context in flops | about +145k (52 + 59 + loader/fetcher ~6 + macro 28) | about 59 % | any package of <= 33 instructions, 5 units: UART TX/RX, USB-LS TX, small held-out protocols; SPI/I2C only on lane 0 (ROM) | new loader/fetcher for 5 units (F0-F2 analogues), R1 composition, image-check story (host readback or CRC), E4/E5 map; about 1.5-3 weeks |
| B. As A but lane 1 keeps its ROM library too (mode mux) | about +170k | about 62 % | as A, and shipped packages stay unconditional on both lanes | as A plus the mux; highest routing risk |
| C. As A with a second store macro (512 words) | about +173k | about 62 % | <= 76 instructions: adds SPI controller | as A |
| D. Parametric ROM: windows (and code values) loadable, structures stay ROM | about +10-20k | about 45 % | retimed variants of shipped protocols only (other baud rates, timing classes); no new structure | small (table registers + R1 with register tables) |
| E. No loadable path; spend the time on increments 3-5 (ROM) and steps 8-12; held-out protocols shown by regenerating the chip from contract source | 0 | 43.5 % | none on silicon | none |

Common to A-C: the shipped-package theorem is unconditional only for ROM packages; a loaded package is
conditional on the host loading the intended image (v1 trust note, V2-4).

## 4. Decision (user, 2026-11-06): option A

Lane 1 fully loadable (no ROM on lane 1), lane 0 keeps the ROM library; one 256x16 store; five IR caches;
context in flops. Gate: local synthesis of the full core, then one CI probe at 30 MHz, before the
increment is accepted (fall back to D or E if utilisation or timing fails).

Refinements found while sizing the fetcher [estimates, to be proven]:
- Header with five unit headers: 28 + 7 + 15 + 5 x 3 = 65 words, so the store holds at most
  (256 - 65) / 6 = 31 instructions.
- Fetch bandwidth: one store word per cycle, 6 per instruction. In the worst case every unit of the
  package completes in the same step, so all its IRs refill within one step of P + 1 cycles. The
  admission bound becomes about P >= 6 x units - 1 (v1: 2 units, P >= 13 with margin), proven as F1t.
  2-unit packages (UART TX P = 64, RX P = 32 at 30 MHz) qualify; the 5-unit USB-LS TX at its 30 MHz
  rate (P about 19) does not (needs P >= 29).

## 5. Area gate, first implementation (2026-11-06): correction of section 3

Implementation: Mon_engine serial loadable lane (fetcher_n, 65-word header, context-only tables, no ROM
on lane 1), Mon_lane `pcs` output, Mprog `store_image ?slots`. The shipped ROM cores re-emit
byte-identically and all tests pass unchanged. Local synthesis (flow/map/map_v1m.sh typ) [facts]:

| core | area | flops |
|---|---|---|
| v2inc1 + T, ROM on both lanes (shipped 30 MHz core) | 252,834 um^2 | 2,199 |
| same, lane 1 serial loadable (option A) | 398,826 um^2 | 3,571 |

Delta +146.0k um^2 of std cells (local), with the store macro on top. **Correction:** section 3
compared local-synthesis deltas with the routed CI baseline. The routed CI std-cell area of the
shipped core is 1.33 x its local synthesis (335,982 / 252,834). On one basis the projection is about
398,826 x 1.33 = 530k um^2 routed std cells + 3 macros (84.4k) = about 68 % of the core [estimate],
not 59 %. The storage is also costlier than assumed: each context/IR bit is an enable flop
(dfrbpq_1 + mux2, about 67 um^2, not 49).
