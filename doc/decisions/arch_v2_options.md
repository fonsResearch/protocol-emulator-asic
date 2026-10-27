# Architecture v2 options (plan v5 step 3, 2026-10-27)

Inputs: `doc/decisions/v2_lessons.md`, `log/harness_audit_v2.md`, `log/pd_probe_6x4.md`
(sections 1-4), `log/disagreements.md` D13. Scope: option A (ISA v1, interface semantics and
contract language v1 kept; agent choice, item V2-10 asks for your review). **Fact** = measured or
read from a file; **estimate** = judgement; **(Recommended)** marks my suggestion. Every item is
your decision.

Budget from step 2: zero global-routing overflow up to 29.2 % utilisation (Yosys typ std cells /
(6x4 core minus macros)); the post-route slow-corner period is above 20 ns for every probe; ~1.32-1.39x
std-cell growth to post-CTS.

## Facts that constrain several items

- **Units used per package** (`emit_lane_rtl.exe`, `PEMU_LIB_STATS`): UART TX 2, UART RX 2,
  I2C controller 3, SPI controller 5, SPI target 5, I2C target 5, USB-LS TX 5. **No package uses
  more than 5 of the 8 units.** In v1 the unit count is not a free parameter: setting
  `Mon_spec.n_units = 5` fails elaboration (units 6/7 are hard-coded loadable slots).
- **ROM words per package**: UART TX 14, UART RX 32, SPI ctl 63-64, SPI tgt 86-87, I2C ctl 143,
  I2C tgt 107, USB 27 (1,173 for all 15).
- **Serial monitor schedule**: with U units evaluated one per cycle, running steps must be at
  least U cycles apart, so P + 1 >= U (v1: U = 8, min_p = 7).
- **I2C target timing** (`protocols_v1/test/test_i2c.ml`, measured in cycles): the firmware needs
  about 7 steps between the SDA edge and SCL-high detection. It works for controller tHD;STA >= 28
  cycles at P = 3 and >= 52 at P = 7. UM10204 Fm minimum tHD;STA = 0.6 µs; Sm = 4.0 µs.
- **Post-route slow-corner WNS at 20 ns** (probes): -0.51 ns (2 UART), -7.11 ns (10 packages),
  -14.39 ns (15 packages). The 2-UART worst path starts at the instruction SRAM output
  (clock-to-output 5.41 ns). The larger probes fail on weak cells driving long wires.

## V2-1 Clock

| option | timing (estimate by WNS shift from the 20 ns probes) | protocol consequences |
|---|---|---|
| **48 MHz, 20.83 ns (Recommended)** | 2-UART probe +0.32 ns; 10-package probe -6.3 ns | USB-LS exactly 32 cycles/bit; I2C target Fm at P = 3 needs 28 cycles, and the Fm minimum is 28.8 cycles, so it passes with 0.8 cycles to spare |
| 40 MHz, 25 ns | 2-UART +4.5 ns; 10-package -2.1 ns | USB-LS 26.67 cycles/bit, not an integer (27 cycles = +1.25 %; tolerance not checked against USB 2.0); I2C target Fm fails (Fm minimum 24 cycles < 28) |
| 33.3 MHz, 30 ns | 10-package about +2.9 ns | USB-LS 22.2 cycles/bit; I2C target Fm fails |
| 60 MHz (v1) | fails on every probe | as v1 |

The project clock comes from the RP2350 on the demo board (TT docs, memory: 1 Hz to 66.5 MHz), so
any of these can be generated. Verification cost: contracts are in steps and the A2 harness has
free ticks, so A2 holds for every P. Only packages whose step constants are derived from µs
(UART bit period, SPI half period, I2C timing, USB) get new constants, a recompiled contract and an
A2 re-run.

## V2-2 Monitor units per lane and evaluation rate

| option | min P | area (estimate) | verification |
|---|---|---|---|
| **5 units, serial (Recommended)** | 4 | saves roughly 3/8 of the per-unit state and logic of 8 units (per-unit state is 960 bits in v1); unmeasured until the generator has the parameter | R1 restated for 5 slots (harness parameter); T5 replaces T8 |
| 8 units, serial (v1) | 7 | measured (v1) | R1 as is |
| 5 or 6 units, 2 per cycle | 2 | adds a second evaluation datapath: the whole v1 engine logic is 38.9k, so at most that [estimate] | R1 restated for paired slots; new proof shape |

## V2-3 D13: monitored I2C target

Requirement: about 7 steps in 0.6 µs (Fm) means (P + 1) <= 0.6 µs x f / 7, i.e. <= 4 cycles at
48 MHz. A serial engine needs P + 1 >= U. Fm target monitoring therefore needs U <= 4 serial slots,
which no 5-unit package meets, or the paired engine of V2-2.

| option | cost | consequence |
|---|---|---|
| **Leave the I2C target out of minimum v2; add Sm target as an increment (Recommended)** | none now | Sm needs (P + 1) <= 4.0 µs x f / 7, i.e. about 27 cycles at 48 MHz, compatible with any U <= 8 |
| Fm and Sm target via the paired engine (V2-2 row 3) | second datapath | full I2C target story; new R1 shape |
| ISA assist for START/STOP detection | ISA change, so option B | removes the 7-step polling cost |
| Drop the I2C target entirely | none | 13 packages remain |

## V2-4 Where contracts live

| option | area | timing | trust |
|---|---|---|---|
| **Logic ROM per lane (Recommended for minimum v2)** | ROM growth 2 to 15 packages: +143.4k for 2 ROM lanes (measured); about 72k per lane [inferred] | ROM decode on the critical path (10.15 ns depth without wires, 15 packages) | netlist theorem covers the shipped contracts unconditionally |
| Loadable, v1 microarchitecture (IR caches) | +170k per lane (measured; 62 % logic) | 10.99 ns depth | conditional on the host loading the intended image |
| Loadable, instructions read from SRAM each slot (no caches) | small [estimate] | SRAM on the path | as above. **Bandwidth rules it out:** an 82-bit instruction is 6 reads of a 256x16 word (3 of 256x32), so 5 serial units need P >= 29 (>= 14), which excludes SPI (P = 7) |
| Hybrid: ROM minimum library now, a cheaper loadable path as an increment | ROM cost now | as ROM | ROM part unconditional; loadable part needs an image check (e.g. on-chip CRC of the loaded store, readable by the host) |

## V2-5 Package set of minimum v2 (budget <= 29 %)

| option | words | utilisation (8 units, ROM-only) | timing at 20 ns, slow corner |
|---|---|---|---|
| 2x UART TX (step-6 baseline) | 28 | 21.7 % (measured) | -0.51 ns (measured) |
| **UART TX + RX, SPI controller + target mode 0 (Recommended)** | 195 | about 23-24 % [estimate: about 100 µm² per added word, from the lib10 row] | between the two measured rows; unknown |
| 10 packages (UART TX/RX, SPI both roles, 4 modes) | 646 | 29.2 % (measured; at the overflow limit) | -7.11 ns (measured) |

SPI modes 1-3 differ from mode 0 only in clock polarity/phase. Adding them later costs about
63-87 words each.

## V2-6 Lanes

| option | area | what it shows |
|---|---|---|
| **2 lanes (Recommended)** | lanes + host port 97.0k (measured, no monitor) | two protocols at once, controller against target on one chip, the non-interference lemma (already proved in v1) |
| 1 lane | saves about 45k [estimate: half the lane share] | single protocol; no non-interference claim |

## V2-7 Floorplan

| option | evidence |
|---|---|
| **Probe floorplan (lane-1 macro at x 3.36, lane-0 macro at x 981.44, both FS at y 41.58) (Recommended)** | 6/6 local PDN tests; zero overflow up to 29.2 % in CI |
| Column floorplan with placement regions per lane | not tested; whether LibreLane 3.1.0.dev3 supports placement regions in this flow is unverified |

## V2-8 Post-GRT timing repair

| option | note |
|---|---|
| **Enable `RUN_POST_GRT_RESIZER_TIMING` in one CI probe of the chosen configuration, compare with it off (Recommended)** | LibreLane marks it experimental ("may result in hangs and/or extended run times") |
| Leave it off; close timing by clock and logic only | the probes show the post-CTS estimate is 0.5-14 ns optimistic |

## V2-9 Per-unit state width

| option | note |
|---|---|
| **Generator parameter sized to the largest timing constant of the shipped library (Recommended)** | v1 synthesis already pruned unreachable bits for ROM lanes (+948 flops going from 2 to 15 packages). Making the width explicit fixes it per configuration and is visible to the proofs |
| Full v1 width | needed only for loadable contracts with arbitrary constants |

## V2-10 Option A review (keep ISA v1)

Agent choice of 2026-10-26. Items that would force option B: the ISA assist in V2-3; any change to
step timing semantics. Everything else above stays within option A.

## V2-11 Growth parameters for 8x4

Lanes, units per lane, evaluation rate, library and loadable path are generator parameters. The 8x4
set is checked by local synthesis and floorplan tests only (rule 8 of v2_lessons.md). The content of
that set is decided when 8x4 opens.

## Decisions (2026-10-27; made by the agent, the user delegated all design decisions)

| item | decision | rationale |
|---|---|---|
| V2-1 | **48 MHz** (CLOCK_PERIOD 20.83 ns) | exact USB-LS bit timing; keeps the Fm I2C target possible at P = 3 later; 2-UART probe would pass by WNS shift. Fallback if minimum v2 does not close: 40 MHz, accepting the USB-LS and Fm-target consequences in V2-1 |
| V2-2 | **5 units per lane, serial**; unit count a generator parameter | covers every package; min P 4; the paired engine is deferred to increment 6 |
| V2-3 | **I2C target out of minimum v2**; Sm target in increment 3, Fm target in increment 6 | D13 cannot be met for Fm with a serial 5-unit engine |
| V2-4 | **Logic ROM for minimum v2**; a redesigned, cheaper loadable path in increment 2 | ROM is measured to route. Loadable contracts are required for step 11 (held-out protocols monitored with no RTL change), so the loadable path is the main design risk after minimum v2. Target: one loadable lane within the remaining budget (29 % minus minimum v2) |
| V2-5 | **UART TX, UART RX, SPI controller mode 0, SPI target mode 0** | about 21-24 % [estimate]; covers both roles of the first two protocols |
| V2-6 | **2 lanes** | concurrency and the non-interference lemma |
| V2-7 | **probe floorplan** | the only one with CI evidence |
| V2-8 | **two CI runs of minimum v2: post-GRT timing repair off and on** | measures the experimental step on our design before relying on it |
| V2-9 | **state width a generator parameter, sized to the shipped library** | makes the pruning explicit and visible to the proofs |
| V2-10 | **keep option A (ISA v1)** | no item above needs an ISA change |
| V2-11 | **parameters only; content decided when 8x4 opens** | rule 8 |

Increment order after minimum v2 is green (step 7; each one through P&R before the next):
1. I2C controller Sm/Fm (P = 14, 3 units; completes the UART/SPI/I2C baseline);
2. loadable contracts on one lane (new microarchitecture);
3. I2C target Sm;
4. SPI modes 1-3;
5. USB-LS TX;
6. paired evaluation for the Fm I2C target.

## Recommended combination (for reference; superseded by the decisions above)

2 lanes; 5 serial units per lane; logic ROM with UART TX/RX and SPI controller/target mode 0; 48 MHz;
probe floorplan; post-GRT timing repair tried in one probe; state width sized to the library; I2C
target out of minimum v2, with the Sm target as the first increment. Estimated utilisation about
21-24 % (below the 29 % zero-overflow point). Timing at 48 MHz is unknown and is the first thing
measured (a CI probe of exactly this configuration, at the start of step 4).
