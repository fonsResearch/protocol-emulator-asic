# v2 proofs and checks (plan v5 step 4)

Branch v2-6x4. Configuration of minimum v2 (doc/decisions/arch_v2_options.md "Decisions"): ROM-only
monitor, 5 serial slots per lane, library `Rom_lib.minimum_v2` (UART TX d4, UART RX d8 m2, SPI ctl m0
h2, SPI tgt m0 h3 g6), 2 lanes, ISA v1 lanes unchanged.

## 1. Implementation route (2026-10-27)

`Mon_lane.create ?slots`, `Mon_engine.create ?slots` and `Top_v1.create ?mon_slots` take the slot
count (default 8). `Mon_spec` (8 units) and every interface width are unchanged. Units `slots`..7
have no state and never fire. Elaboration-time checks: a loadable lane needs 8 slots; every ROM
package must fit in the slots. ROM-mode admission is `min_p = slots - 1`. The lanes are
unchanged.

| check | result |
|---|---|
| default build (8 slots, lane 1 loadable, 15 packages) after COMBDLY fix vs v1-tt `src/pemu_core_v1m.v` | byte-identical |
| `PEMU_SLOTS=8` vs default | byte-identical |
| `dune runtest` with defaults (all existing expect tests) | pass, no diffs (153 s) |
| elaboration negative: 15 packages on 4 slots | raises (`spi_ctl_v1_m0_h2` needs 5 units) |
| elaboration negative: loadable lane with 5 slots | raises |

## 2. Cyclesim: Mon_lane (5 slots) = Mon_spec (`monitor_v1/test/test_mon_lane.ml`)

| run | packages | steps | firings | mismatches |
|---|---|---|---|---|
| 5 slots, spacing 5 (random packages with <= 5 units) | 200 | 101,632 | 32,435 | 0 |
| 5 slots, every package filled to 5 units, spacing 5 | 200 | 101,646 | 112,451 | 0 |
| 5 slots, 5 units, spacing 9 | 50 | 15,080 | 17,659 | 0 |
| negative: spacing 4 (T4) | 50 | 30,670 | 37,539 | **5,613** (16,827 overruns) |

## 3. Formal R1 (`formal/src/mon_ref.ml`, ABC; 2026-10-27)

The harness takes `?slots`; the sequencer invariant's window end is `slots - 1` (was 7).
Positive harnesses ran with `ENGINE=ind` (k-induction, `ind -F 12`), negative controls with
`ENGINE=bmc` (`BMC_F` 30) and the usual shortest-trace replay.

| harness | result | wall s | note |
|---|---|---|---|
| r1v2_s5_u0 .. u4 | PASS (each) | 12-17 | 1,211 latches |
| r1v2_s5_u3_smask_neg | FAIL depth 4, replay ok | 0 | planted step-mask bug |
| r1v2_s5_u4_t4_neg | FAIL depth 5, replay ok | 1 | T4 instead of T5 |
| r1_mon_lane_u0 .. u7 (v1, regression) | PASS (each) | 10-16 | 1,214 latches |
| r1_mon_lane_u3_smask_neg, r1_mon_lane_u7_t7_neg | FAIL depth 4 / 8, replay ok | 0 / 7 | as v1 |

(A first run with the runner's default engine `dprove` timed out at 600 s on u0 and u1. The
documented engine for R1 is `ind`; see formal/README.md.)

## 4. Static admissibility (`rtl_v1/test/test_rom_lib_v2.ml`)

`Rom_lib.admissibility_violations ~slots:5 (minimum_v2_with_p ())` = [] at the documented 48 MHz
divisors (UART TX P = 103, RX 51, SPI 7, 7). Negative controls: I2C target at P = 3 on 5 slots
(P below the minimum of 4), and the minimum library on 4 slots (SPI packages need 5 units). Both
are reported.

## 5. Chip-level scenario (cyclesim, `dump_tt_vectors_v1.exe`, PEMU_SLOTS=5, PEMU_LIB=v2min, rom)

v1_rom_uart (12,817 cycles): lane 0 runs UART TX with ROM package 0 enabled at P = 7. The correct
program gives VERDICT 00 00 00 00; the start-bit mutant gives VERDICT 01 15 (fail, code 0x15),
cleared by CTRL. v1_reset_mid (9,133 cycles): ID and restart as v1.

## 6. Carried-over proofs (2026-10-27)

- Lane A1 and the prescaler lemma: `rtl_v1/src/lane_rtl.ml`, `prescaler16.ml`, `sram256.ml` and
  `spec_v1/` are unchanged between main and v2-6x4 (`git diff --stat` empty). The v1 results in
  log/proofs_v1.md therefore apply to the v2 lanes.
- `formal/src/top_props.ml` builds the register blocks, host port and lane directly; it does not use
  the monitor or `Top_v1.create`. Re-run on the v2 tree (dprove):

| harness | result | wall s |
|---|---|---|
| load_gate | PASS | 98 |
| load_gate_neg | FAIL depth 3, replay ok | 0 |
| own_disjoint | PASS | 0 |
| own_disjoint_neg | FAIL depth 2, replay ok | 0 |
| lane_pin_gate | PASS | 1 |
| run_after_reset_k3 / k33 | PASS / PASS | 0 / 1 |
| run_after_reset_cover_neg / k34_neg | FAIL depth 33 / 33, replay ok | 0 / 0 |

## 7. Open in step 4

- Done 2026-10-27: COMBDLY post-process of the 5-slot netlist (7,033 assignments, no X literals). It
  is proven EQUIVALENT to the Hardcaml Verilog (`tools/check_combdly_equiv.sh`, Yosys equiv_simple
  -seq 2 + equiv_induct, 830 s). RTL replay of the v2 vectors on it: 3/3. Floorplan tests 6/6.
  It is in the TT build at `src/pemu_core_v1m.v` (commit ada5d7d). CI variants: v2-6x4-pgrt
  (post-GRT timing repair on), v2-6x4-40mhz (25 ns).
- `top_props` (load gate, OWN, pin gating, RUN after reset) on the v2 top; composition lemma C3.
- Lane A1: lanes are unchanged, so the v1 lane A1 (log/proofs_v1.md) applies. To confirm by
  checking that `Lane_rtl` is byte-identical in the emitted v2 netlist.
