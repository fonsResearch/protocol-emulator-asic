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

## 7. Composition lemma C3: analysis and decision (2026-10-27)

Chip composition vs the A2 harness (`formal/src/ag_pkg.ml`):

- **Firing time.** Mon_spec reports unit j's firing in the step cycle t. The chip engine reports it in
  cycle t + j (R1), stamped t (monitor_isa_v1.md: "Firings are stamped with the step cycle t").
- **Blame to the lane.** Registered, so it arrives at t + j + 1 on the chip and at t + 1 in the
  harness. Lane spec and RTL consume a blame through a bypass, `blame_now = bpend | (blame_in & rob)`
  (`spec_v1/src/lane_circuit.ml` l. 142, `rtl_v1/src/lane_rtl.ml` l. 277). A blame arriving in the
  step cycle is therefore taken by that step. Admission gives j <= slots - 1 <= P, so the chip blame
  arrives no later than the lane's next step, and that step sees it as in the harness.
- **Divergence after a blame.** A host `clear_fault` within j cycles after a blaming step can leave
  the chip and the harness in different lane states. This only happens after a blame has fired, and U
  constrains only fails before the first blame, so U is unaffected [argument; to be checked by the
  differential run below].
- **Verdict pins.** `uo[1]` (fail) and `uo[2]` (blame) rise when the firing is recorded, up to slots - 1
  cycles after its step. Within one step, a fail from unit 0 can appear on the pin before a blame from
  unit 4.

**Decision (agent, under the user's delegation):** the chip-level theorem is stated on step stamps:
every recorded fail has a recorded blame with stamp <= the fail stamp (FAIL_TIME, BLAME_TIME, VERDICT).
The pins are documented as indicators with up to slots - 1 cycles of latency. Rejected alternative:
delay both flags to the end of the slot window in hardware (small RTL change, but a new engine proof
for an indicator).

C3 plan:
1. A wiring lemma on the v2 top with the lanes and engine cut: the engine's lane view equals
   (lane outputs & OWN, lane xo bits, raw pads); blame_in(L) = the engine's blame(L), registered.
2. A stamp-order lemma from R1 plus the verdict block.
3. A differential cyclesim: v2 top RTL against the harness composition (lane model + Mon_spec, wired as
   in ag_pkg), with random environments, host clears and resets, for each shipped package. Compare the
   verdict (flags, codes, stamps) and pins up to the documented latency.

### 7.1 Differential cyclesim, plan item 3 (directed part, 2026-10-27)

`rtl_v1/test/test_c3_diff.ml`: the v2 top RTL (Top_v1, ROM monitor, 5 slots, `Rom_lib.minimum_v2`,
behavioural SRAMs) is driven through its pins by a bit-banged host SPI master and a protocol peer.
It is compared with Psim (Lane_model, Interp, and Mmodel cross-check, wired as in ag_pkg) on the same
firmware, peer and divisor. RUN-to-start latency is calibrated on UART TX: unique k = 19.
The test runs 9 scenarios in the `rtl_v1/test` runtest, about 25 s:

| scenario | monitor inputs | pads, pins | fail | blame | rx bytes |
|---|---|---|---|---|---|
| uart_tx correct | = | = | - / - | - / - | = (0) |
| uart_tx bad start | = | = | 13@81 / 13@81 | - / - | = (0) |
| uart_rx nominal | = | = | - / - | - / - | = (8) |
| uart_rx 8% fast | = | = | - / - | 32@4421 / 32@4421 | = (6) |
| uart_rx late sampling | = | = | 4B@7021 / 4B@7021 | - / - | = (6) |
| spi_ctl m0 tco 3 | = | = | - / - | - / - | = (8) |
| spi_ctl m0 tco 14 | = | = | - / - | 91@113 / 91@113 | = (8) |
| spi_tgt m0 hp 40 | = | = | - / - | - / - | = (8) |
| spi_tgt m0 early CS | = | = | - / - | 52@2345 / 52@2345 | = (7) |

The table is psim / chip. Times are Psim cycles; chip stamps are mapped to Psim time. "Monitor inputs" means
lane 0's running, tick, uio_in, owned uio_out/uio_oe and FIFO events, compared every cycle. `uo_out`
(the xo bits) was zero on the chip throughout, and Psim drives it as 0.

Finding during bring-up (a testbench issue, not RTL): the first harness version resolved pads from
the same-cycle outputs. Psim has one cycle of output-to-pad delay (`Lane_model.step` returns the
pre-update outputs, and the pad of cycle t uses those of t - 1). Pin calibration hid the skew, and
all stamps came out +1. With the time-based SPI controller peer, the early-CS blame came 2 steps
early (chip 52@2330, psim 52@2345) and pins diverged after it. The diagnosis:
1. `rtl_v1/test/test_c3_replay.ml` replays Psim's monitor-input stream into Mon_spec and
   Mon_lane (5 slots). All three give B52@2345.
2. Replaying the chip's own monitor-input stream (from `Top_v1.create_with_debug`) into Interp
   reproduced every chip verdict exactly, so the RTL monitor matched the spec on the inputs it got.
3. The streams differed only in running/tick vs pad phase.

Fix: the chip harness now applies Psim's pad delay. As a side effect, this showed that the comparison
detects a one-cycle phase change between lane and environment.

Test-only RTL-adjacent change: `Top_v1.debug` gained `mon_running` (visibility). The emitted v2 netlist is
byte-identical (sha1 c89129a5..., v2min, 5 slots). `Psim.run` gained an optional `on_cycle` hook.

Not yet covered by item 3 (still open): random environments, host `clear_fault` and resets during a
run, and both lanes active. The U-preservation argument after a blame is still untested. The directed scenarios fire
no clears, and post-blame behaviour matched because nothing intervened. Items 1 (wiring lemma) and 2
(stamp-order lemma) are not done.

### 7.2 Differential cyclesim: host clears and randomised environments (2026-10-27)

`rtl_v1/test/test_c3_env.ml` reuses the 7.1 harness. Psim gained `?clear_at`. The chip harness issues CTRL
writes (0x21: RUN lane 0, clear fault lane 0) during the run. The write is timed so that the
`clear_fault` pulse lands at a chosen Psim time; the measured latency from transaction start is
194 cycles. The observed pulse times then drive Psim.

**Clear-window sweep.** Release on blame is set (cfg bit 0), and the clear lands at t + d around the
first blame step t. C3 predicts divergence exactly for 1 <= d <= j, where j is the blaming unit's
slot: there the clear wipes the harness lane's pending blame (arrived at t + 1) before the chip's
blame arrives at t + j + 1. At d = j + 1 the clear wins over the same-cycle blame, so the two agree again.

| scenario | first blame | j | d tested | diverged |
|---|---|---|---|---|
| UART RX 8 % fast | 32@4421 | 0 | -40, 0..6, 10, 40, 70, 200 | none (window empty) |
| SPI ctl, MISO hold glitch (frame 3, bit 4), tco 3 | 91@1145 | 4 | same | d = 1..4 only; from cycle 1154 (the lane's next step); first-blame verdict identical |

Prediction mismatches: 0 in both. This confirms the C3 analysis at the cycle level: the only
chip/harness divergence is a lane state change after a blame has been recorded, so U (no fail
before the first blame) is unaffected.

**Randomised environments** (seeded, 16 cases, one clear each, placed near a blame half of the time):
- 6 UART RX: rate x0.90-1.10, glitch / short-stop / none, rob 0/1.
- 6 SPI target: hp 24-64, gap 100-300, five controller defect kinds, rob 0/1.
- 4 SPI controller: tco 0-20.

11 cases have a blame. None diverge, in any cycle of the monitor-input stream, pins, verdict or
pushes. Three clears landed within slots - 1 cycles after a blame, but on j = 0 blames, so the
non-empty-window case is covered by the sweep only.

Harness pitfalls fixed on the way, all test bugs and not design differences:
1. Random peer parameters must be drawn once, outside the peer constructor; a draw inside gave the
   chip and Psim different peers.
2. The chip keeps running during the post-run SPI readback. Received bytes are therefore compared
   from the pushes recorded inside the window, and the FIFO readback is checked only as a prefix.
3. Clears must start after the CTRL-write latency.

Still open: reset during a run, both lanes active at once, the wiring lemma (item 1) and the stamp-order
lemma (item 2).

## 8. Open in step 4

- Done 2026-10-27: COMBDLY post-process of the 5-slot netlist (7,033 assignments, no X literals). It
  is proven EQUIVALENT to the Hardcaml Verilog (`tools/check_combdly_equiv.sh`, Yosys equiv_simple
  -seq 2 + equiv_induct, 830 s). RTL replay of the v2 vectors on it: 3/3. Floorplan tests 6/6.
  It is in the TT build at `src/pemu_core_v1m.v` (commit ada5d7d). CI variants: v2-6x4-pgrt
  (post-GRT timing repair on), v2-6x4-40mhz (25 ns).
- `top_props` (load gate, OWN, pin gating, RUN after reset) on the v2 top; composition lemma C3.
- Lane A1: lanes are unchanged, so the v1 lane A1 (log/proofs_v1.md) applies. To confirm by
  checking that `Lane_rtl` is byte-identical in the emitted v2 netlist.
