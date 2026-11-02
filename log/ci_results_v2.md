# CI results, v2 minimum on 6x4 (plan v5 step 5)

## 1. Round 1 (pushed 2026-10-27 18:47 UTC)

The netlist is the same in all three runs: `src/pemu_core_v1m.v`, the COMBDLY-fixed 5-slot v2min
core. It is proven equivalent to the Hardcaml Verilog (log/proofs_v2.md section 8). The runs differ
only in LibreLane settings.

| run | branch, commit | CLOCK_PERIOD | post-GRT timing repair | gds job | precheck | gl_test |
|---|---|---|---|---|---|---|
| 40563302709 | v2-6x4 d904d70 | 20.83 ns (48 MHz) | off | pass, 82 min | pass | pass |
| 40563302743 | v2-6x4-pgrt 768abc0 | 20.83 ns | on | pass, 88 min | pass | pass |
| 40563302904 | v2-6x4-40mhz 5d3be7e | 25.00 ns (40 MHz) | off | pass, 134 min | pass | pass |

The `viewer` job failed in all three, as in earlier rounds; it does not touch the design. The docs
job failed on the placeholder `docs/info.md`, which is fixed in commit 86c46e2, not yet pushed.

Physical sign-off (from `final/metrics.json` in GDS_logs; base / pgrt / 40 MHz):

| metric | base | pgrt | 40 MHz |
|---|---|---|---|
| std-cell area (um2) | 294,513 | 294,617 | 294,546 |
| utilisation (incl. macros) | 38.9 % | 38.9 % | 38.9 % |
| instances | 75,260 | 75,257 | 75,263 |
| DRT violations, iter 0 / final | 144 / 0 (iter 5) | 205 / 0 (iter 3) | 311 / 0 (iter 7) |
| route wirelength (um) | 998,581 | 1,000,293 | 997,856 |
| KLayout DRC | 0 | 0 | 0 |
| LVS errors | 0 | 0 | 0 |
| antenna violating nets | 0 | 0 | 1 |
| Magic illegal overlaps | 10 | 10 | 10 |
| disconnected pins (critical) | 1 (0) | 1 (0) | 1 (0) |
| max slew / max cap violations | 24 / 5 | 27 / 4 | 31 / 3 |
| hold WNS fast / typ / slow (ns) | +0.112 / +0.293 / +0.616 | +0.111 / +0.292 / +0.614 | +0.112 / +0.293 / +0.616 |
| setup WNS typ (ns) | +3.593 | +3.945 | +7.814 |
| setup WNS slow (ns), violating endpoints | -6.799, 540 | -6.237, 532 | -2.551, 138 |

The routing problem that ended v1 (Metal3 overflow, DRT not converging in 6 h) does not appear here.

## 2. Slow-corner setup: diagnosis

Facts, from the STA reports (`57-openroad-stapostpnr/nom_slow_1p08V_125C/max.rpt`) and the final netlist:

- **One start point.** All 540 violating paths (base) start at one flop, `_30392_`. Its Q drives
  `core._325`, which in `src/pemu_core_v1m.v` is `assign _325 = rst_sync_n`, so the flop is the reset
  synchroniser. Within the core, `rst_sync_n` is the synchronous clear (Hardcaml `Reg_spec ~clear`)
  and also a data term, e.g. `running = rst_sync_n & run_bit & admit & loaded & ~faulted` and
  `step = rst_sync_n & running & tick`.
- **Endpoints.** Worst are the monitor verdict records `mon_{fail,blame}_{unit,time,code,seen,first}`
  (to -6.80 ns), then unit state `mon_u*_reg` / `mon_u*_k` (to -3.6 ns). At 25 ns only verdict-record
  endpoints fail (-2.55 ns worst).
- **Path shape.** The worst path has about 45 stages: about 1.7 ns of `buf_1` fanout tree on
  `rst_sync_n`, then the unit-step cone and the verdict capture enable. Every cell is drive strength
  `_1`, and slews reach 1.56 ns. The arrival is 27.6 ns against a 20.83 ns period.
- **Why repair did not fix it.** The post-CTS resizer loads all three corners
  (`RSZ_CORNERS or STA_CORNERS`, LibreLane 3.1.0.dev3 `ResizerStep`) and reports "No setup violations
  found". The post-GRT resizer (pgrt run) sees -0.989 ns (94 endpoints) with global-route parasitics
  and repairs it to +0.004 ns. After detailed routing and RCX the slow corner is at -6.24 ns. So both
  pre-route parasitic estimates miss this cone by about 6 ns at the slow corner (the step-2 probes
  showed the same pattern). Mid-flow STA (`STAMidPNR`) reports the default corner only, typical, so
  the gap is not visible until the end.
- **Synthesis.** LibreLane synthesis uses ABC strategy `AREA 0`.

Estimates (not measured):
- A path from `ctrl_run` through the same gates would be shorter only by the reset fanout tree, about
  1.7 ns, so removing `rst_sync_n` from the data logic alone would not close 48 MHz. The report lists
  one path per endpoint, so the worst non-reset path into these endpoints is not visible.
- The slow-corner critical path is about 27.6 ns in both runs (20.83 + 6.80; 25 + 2.55), so the slow-corner
  Fmax of this netlist is about 36 MHz. At the typical corner it is about 58 MHz (20.83 - 3.59 = 17.2 ns).

## 3. Decision (agent, under the user's delegation): clock 33 MHz, slow-corner sign-off

- Timing is signed off at the slow corner (1.08 V, 125 C), post-route with RCX.
- Minimum v2 clock: 33 MHz, CLOCK_PERIOD 30.30 ns. The expected slow margin is about +2.7 ns (from
  the 27.6 ns path; each run re-synthesises and re-routes, so this is an estimate). 33 MHz is
  22 x 1.5 MHz, so USB-LS is exact (increment 5). UART 115200 is +0.5 % (TX P = 71, RX P = 35); SPI
  controller at P = 7 is 1.03 MHz.
- Fallback built in parallel: 30 MHz (33.33 ns), expected margin about +5.7 ns; UART RX +1.4 %
  (P = 32). The fallback is taken if 33 MHz does not show at least 1 ns of slow-corner margin.
- Cost: monitoring the I2C *target* at Fm needs (P + 1) <= about 2.8 cycles at 33 MHz. A serial engine
  with 5 slots cannot do it (P + 1 >= 5); it was already infeasible at 48 MHz with 5 slots. Increment 6
  (Fm target by paired evaluation) is dropped unless the clock returns to 48 MHz. The Sm target
  (increment 3) needs P <= 17 and stays feasible.
- Rejected: 48 MHz with typical-only sign-off (slow corner -6.80 ns); 36 MHz (no margin); post-GRT
  repair as the fix (0.56 ns gain).
- Follow-up (a timing increment before novelty increments, RTL change, needs R1 and top_props re-run):
  register the firing record before the verdict block, and drop the redundant `rst_sync_n` data terms
  where the synchronous clear already covers them. This may allow a higher clock later. Novelty
  increments add logic to this same cone.
- The divisor P is a host register, so the declared clock is the STA target and the documented
  divisor set; other board clocks change only the P values.

The netlist is unchanged by this decision: re-emitting at 33 MHz gives byte-identical Verilog,
sha1 prefix c89129a596831b5c. P is not in the RTL.

## 4. Round 2 (2026-11-02, after the Actions billing block was lifted)

| run | branch, commit | CLOCK_PERIOD | gds | precheck | gl_test |
|---|---|---|---|---|---|
| 41442167676 | v2-6x4 e218611 | 30.30 ns (33 MHz) | pass, 125 min | pass | pass, 5/5 incl. v2_spi_ctl_uart_rx and v2_spi_tgt_uart_tx |
| 40597068304 (attempt 3) | v2-6x4-30mhz afbfff9 | 33.33 ns (30 MHz) | pass, 87 min | pass | pass |

e218611 differs from 9beb28d only in tests, logs and the two v2 gate-level vectors (no RTL or config
change). The docs and test workflows on e218611 pass (the docs fix 86c46e2 is included).

| metric | 33 MHz | 30 MHz |
|---|---|---|
| setup WNS slow / typ / fast (ns) | +2.987 / +13.261 / +19.068 | +6.017 / +16.291 / +22.098 |
| slow setup violating endpoints | 0 | 0 |
| hold WNS (fast), violations | +0.112, 0 | +0.112, 0 |
| route DRC / KLayout DRC / LVS / antenna nets | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| max slew / max cap violations | 24 / 5 | 24 / 5 |
| Magic illegal overlaps | 10 | 10 |
| std-cell area (um2), instances | 294,503; 75,273 | 294,503; 75,273 |

The two final netlists (final/nl) are byte-identical (sha1 prefix 19c7af9bb6f65906). With
`AREA 0` synthesis, and with no setup repair triggered at either period, the period changes only the STA
target. The slow-corner critical path is 30.30 - 2.99 = 27.31 ns (round 1: 27.6 ns).

**Clock decision confirmed: 33 MHz.** Slow-corner margin +2.99 ns, above the 1 ns acceptance threshold of
section 3. The 30 MHz branch stays as a reference only.

Open items:
- max slew (24) and max cap (5) violations, slow corner only, unchanged since round 1; not yet traced.
- Magic illegal overlaps (10), unchanged; not yet attributed.
- E4/E5 netlist equivalence (section 5): not yet proven.

## 5. E4/E5 netlist equivalence, 33 MHz netlist (in progress)

Inputs: GDS_logs/src (RTL as hardened), runs/wokwi/06-yosys-synthesis (E4) and tt_submission (E5) of run
41442167676, commit e218611. The 30 MHz netlist is byte-identical, so a result covers both.

| attempt | method | result |
|---|---|---|
| 1 | v0.1 script, VARIANT=v1m (full IHP SRAM functional models on both sides), ABC dprove | E4 UNDECIDED at the 3,000 s cap (20,320 latches; the BMC stage found no difference in 20 frames). Stopped before E5 |
| 2 | Yosys equiv_make/simple/induct, SRAM as black-box cutpoints | not usable: independent free SRAM outputs per side make all fetch-dependent state unprovable (80 of 2,054 pairs proven) |
| 3 | `flow/equiv/run_equiv_v1m.sh`: SRAMs removed, outputs from one SHARED free input, all 2 x 89 macro input bits compared (`flow/equiv/macro_cut.py`) | E5 UNDECIDED (dprove 1,800 s; 3,872 latches); PDR UNDECIDED (1,400 s, frame 85, no counterexample). E4 cut netlist hit an escaped-identifier bug, since fixed and not yet re-run. Negative controls all FAIL as required: N1 output inverted (frame 0), N2 uio_in[5] buffer inverted (frame 116), N3 SRAM-0 address bit inverted (frame 0) |

Diagnosis so far: ABC signal correspondence (&scorr, also -F 2/4) merges only about 250 of 3,872 latches.
On an RTL-vs-netlist miter nearly all pairs should merge, so something systematic breaks pairwise register
correspondence. Ruled out: tie cells (modelled correctly, L_HI = 1) and asynchronous clear in the core
(Hardcaml emits `always @(posedge clk)`; the core flops' RESET_B pins are on per-flop tiehi cells). Next: a name-based
per-signal diagnosis on the cut sources (running).

Evidence available meanwhile (simulation, not a proof): CI gl_test 5/5 on this netlist (four vector
replays with 0 mismatches and the comparator negative control), and the local replay of the same vectors on the round-1
netlist.
