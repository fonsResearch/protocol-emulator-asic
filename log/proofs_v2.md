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

### 7.3 Differential cyclesim: both lanes at once (2026-10-27)

`rtl_v1/test/test_c3_two.ml` runs two ROM packages concurrently on disjoint pins. It compares them
with two independent Psim lanes, each with its own peer; the chip sees the composed peer drive. Per lane it compares
the monitor-input stream (uio_in on that lane's interface pins only), the owned pins and the pushes in every cycle.
Globally it compares the first fail and first blame, including the lane bits (VERDICT bits 2/3), against
the spec rule "earliest stamp, lane 0 on ties".

| scenario | per-lane streams, pins, pushes | first fail | first blame |
|---|---|---|---|
| A L0 uart_tx, L1 spi_ctl tco 3 | = / = | - | - |
| B L0 uart_tx bad start, L1 spi_ctl tco 14 | = / = | L0 13@81 = | L1 91@113 = |
| C L0 uart_rx 8 % fast, L1 spi_tgt early CS | = / = | - | L1 52@2345 = (L0 32@4421 later) |
| D = B with lanes swapped | = / = | L1 13@81 = | L0 91@113 = |
| E = C with lanes swapped | = / = | - | L0 52@2345 = |
| F L0 uart_tx, L1 spi_ctl tco 14, release on blame | = / = (L1 faults: 0 pushes) | - | L1 91@113 = |
| G L0 spi_tgt early CS release on blame, L1 uart_tx | = / = (L0 faults: 2 pushes) | - | L0 52@2345 = |

This covers lane-1 wiring of the lane view, the per-lane blame return (F, G), non-interference
(a faulting lane leaves the other unchanged), both package orders, and the cross-lane first choice.
Not covered: equal stamps across lanes (the tie rule); the scenarios do not produce one.

**C3 item 1 (wiring lemma), disposition.** In the RTL the engine's lane view is literally the
expressions the lemma states (`Top_v1`, construction of `lanes` for `Mon_engine.create`: running,
tick, uio_out & OWN, uio_oe & OWN, xo in its uo_out position, FIFO events, raw ui_in/uio_in). The
lane's blame_in is the engine's registered `mon_blame_to_lane<L>`. A formal lemma at RTL level
would therefore be vacuous. The residual risks are:
- lane-index mapping inside the engine, covered by 7.3 (both orders, release on blame on each lane);
- netlist-level wiring, covered by E4/E5 equivalence of the final GDS netlist against the RTL:
  proven on the green v2 run 41442167676 (log/ci_results_v2.md section 5).
Item 1 is closed on this basis (agent decision; a reviewer may still ask for a formal statement).

### 7.4 Reset during a run (2026-10-27)

`test_c3_two.ml` scenarios H and I use a prefix on the same chip instance. It runs B with release on blame
on L1 (fail L0 13@81, blame L1 91@113, L1 faulted); at the moment of reset the verdict pins show
fail 1 and blame 1. Reset is then asserted mid-run: H after 2,003 cycles for 3 cycles, I after 157 cycles
for 1 cycle. Both lanes are then reconfigured from scratch and a fresh scenario runs: H = A (no firings), I = C.
Both match a fresh Psim in every compared quantity; H's verdict is empty, as predicted. So no verdict,
unit, history, FIFO or fault state survives reset into the next run, including a 1-cycle reset.
Not covered: reset without reconfiguration. Registers are cleared by reset, so the lanes stay halted
until the host writes RUN, which top_props `run_after_reset_k33` proves.

### 7.5 C3 item 2: stamp-order lemma (argument, not machine-checked)

**Lemma S.** Per lane L and role r: if the verdict records a first firing of role r for L with stamp s, then
s is the least stamp among L's role-r firings since the last reset or verdict clear. Apart from the
documented in-flight-at-clear case (monitor_isa_v1.md section 6), the global first is the least
stamp over both lanes, lane 0 on ties.

**Argument.**
1. Firings are recorded in nondecreasing stamp order.
   - R1 (r1v2_s5_u0..u4, PASS): unit j's firing of step t appears at cycle t + j, and its stamp is t
     (`stamp = mux2 step now_q stamp_l`, with stamp_l latched at the step).
   - Admission (P >= slots - 1, `Rom_lib.admissibility_violations` and the engine's min_p) puts steps
     at least `slots` cycles apart, so every firing of step t is recorded before any firing of a
     later step.
   - A lane's serial engine fires at most one unit per cycle.
2. The record takes the first firing (`take = rec & ~seen`), so by step 1 it holds the least stamp.
3. Cross-lane rule (`precedes`): the other lane's stamp being 1-7 later, or absent, means this lane is first; equal stamps
   go to lane 0. Stamps of competing first records differ by at most 7, so the comparison is exact
   modulo 2^32.

**Chip theorem (assembled).** The pieces are:
- A2 U (harness): no fail in a step before the first blame step.
- C3 composition: chip and harness agree up to the first blame. Evidence: the 7.1-7.4 differential
  runs, plus the 7.2 window result that divergence starts only after a recorded blame.
- Lemma S.

Together they give: if the chip records a fail with stamp s_f, it records a blame with stamp s_b <= s_f.

Status: Lemma S is a paper argument over proven R1 and the verdict RTL. The differential runs back it
(identical stamps in every scenario). A formal harness for the verdict block is possible, but the block
is not separable in `Mon_engine` today. It is left as an option for the step-12 sign-off.

## 8. Open in step 4

- Done 2026-10-27: COMBDLY post-process of the 5-slot netlist (7,033 assignments, no X literals). It
  is proven EQUIVALENT to the Hardcaml Verilog (`tools/check_combdly_equiv.sh`, Yosys equiv_simple
  -seq 2 + equiv_induct, 830 s). RTL replay of the v2 vectors on it: 3/3. Floorplan tests 6/6.
  It is in the TT build at `src/pemu_core_v1m.v` (commit ada5d7d). CI variants: v2-6x4-pgrt
  (post-GRT timing repair on), v2-6x4-40mhz (25 ns).
- Done: `top_props` on the v2 top; C3 sections 7.1-7.5 (items 1-3 closed as stated there).
- Lane A1: confirmed carried over. `git diff v1-tt v2-6x4` is empty for rtl_v1/src/lane_rtl.ml,
  prescaler16.ml, sram256.ml, spec_v1/src/ and formal/src/a1_lane.ml. The core netlist is flattened,
  so a per-module byte comparison of the emitted Verilog is not possible; the source identity is the evidence.
- E4/E5 netlist equivalence on the green v2 GDS run (41442167676, e218611): proven, 2,285 of 2,285
  pairs each, negative controls N1-N5 fail as required (log/ci_results_v2.md section 5). Step 5 closed.

## 9. R1 with the pipelined slot schedule (increment 3, 2026-11-07)

`formal/src/mon_ref.ml ~pipe`: claim "unit j of Mon_spec fires in step t => Mon_lane fires unit j
in cycle t + j + 1 with the same role and code, and in no other cycle"; every slot gets the ghost
word of step t; invariant i_seq: busy_q over since 1..slots with slot_q = since - 1. ENGINE=ind:
r1v2p_s5_u0..u4 PASS (2-3 s each, 1,173 latches), r1v2p_s5_u4_t5 (ticks 5 apart) PASS;
r1v2p_s5_u4_t4_neg FAIL (depth 6), r1v2p_s5_u3_smask_neg FAIL (depth 5), replay ok. R1 needs ticks
at least slots cycles apart; the admission bound P >= slots comes from the blame-to-lane latency.

## 10. C3 host-clear sweep with the pipelined schedule (2026-11-08)

`rtl_v1/test/test_c3_pipe.ml` (shipped configuration: lane pipe + vpipe + param_windows), same
scenarios as section 7.2. Prediction shifted by one cycle: a host clear landing d cycles after a
blame of unit j makes the chip diverge from the A2 harness composition iff d in 1 .. j + 1.
- uart_rx 8 % fast, blame 32@4421, j = 0: diverges only at d = 1 (was never); 0 mismatches.
- spi_ctl MISO hold glitch, blame 91@1145, j = 4: diverges for d = 1..5 (was 1..4); 0 mismatches.
The first-blame verdict is identical in every run, so theorem U is unaffected; the C3 statement in
section 7 holds with j replaced by j + 1 for lane_pipe builds. The open item of increments_v2 3.4
is closed.
