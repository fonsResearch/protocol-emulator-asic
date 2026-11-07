# v2 increments (plan v5 step 7)

Rule (plan): one increment at a time. Each gets RTL, verification, local synthesis and a bounded CI probe.
It is accepted only if CI stays green and the slow-corner timing closes at the chosen clock.
Work happens on branch `v2-inc1-i2c`; `v2-6x4` stays the frozen minimum until it is tagged.

## T. Timing option: registered firing record (`Mon_engine ~verdict_pipe`, default off)

The verdict block records a registered copy of each lane's firing (fire, role, code, unit, stamp),
one cycle later. The aim is to cut the unit-step cone off the verdict registers, which were the worst
slow-corner endpoints of round-1 CI (log/ci_results_v2.md section 2). blame_to_lane stays on the
unregistered firing, so the C3 blame-arrival argument (log/proofs_v2.md section 7) is unchanged.
Verdict pins and registers see a firing one cycle later, and stamps are unchanged.

- The default build is unchanged: v2min with the option off emits byte-identical Verilog (sha1 prefix c89129a596831b5c).
- Cost: +24 flops on v2min and +26 on v2inc1 (fire, role, code, unit per lane). The registered stamp merges
  with the existing step-latched stamp. Area +2,157 um2 (v2min) and +1,405 um2 (v2inc1), Yosys typ.
- Tests with the option on: the cross-lane verdict scenarios B, C, D, G (`test_c3_two.ml`) and the I2C
  scenarios (`test_inc1.ml`). All match Psim, with identical stamps, codes, lane bits and blame routing.
- Still to do before acceptance: top_props re-run on a pipelined top (no verdict property is expected
  to depend on it), regenerated gate-level vectors (uo[1]/uo[2] move by one cycle), spec text
  (monitor_isa_v1.md section 6: in-flight window and pin latency).

## 1. I2C controller, Fm and Sm (ROM packages 4 and 5)

- `Rom_lib.v2_inc1_with_p`: Fm P = 8 (step 0.273 us, SCL 367 kHz; P = 7 would give 412 kHz, over the
  Fm limit), Sm P = 32 (step 1 us, as in v1). The contract encodes only UM10204 minimum times, so the
  longer Fm step keeps it valid. Admissible at 5 slots (`test_rom_lib_v2.ml`). Both packages have 3 units.
- Chip level (`test_inc1.ml`, v2 top RTL with library v2_inc1 vs Psim, I2C target peer on the wired-AND
  bus): Fm clean, clock stretch 200, NACK of write byte 1, target data delay 30/50/70, and Sm clean and
  stretch 600. All are identical in the monitor-input stream, pins, verdict and pushes. Status bytes are
  00, or 02 on the NACK. Read data C3 5A. Data delay 70 (beyond the 54-cycle low phase) is blamed 0x77,
  identically on chip and Psim. U holds in every scenario.
- A2: the v1 results are bounded (bmc3 77 / 76 frames) and are carried as bounded under C1-C4.

Local synthesis (Yosys; slow = slow corner, no wires):

| build | std cells typ (um2) | util. | flops | depth, map_v1m.sh slow (sized) | depth, reduced script (no sizing) |
|---|---|---|---|---|---|
| v2min | 217,934 | 25.8 % | 1,933 | 9.10 ns | 18.24 ns |
| v2min + T | 220,091 | 26.0 % | 1,957 | 8.35 ns | 15.06 ns |
| v2inc1 | 251,429 | 29.7 % | 2,173 | 9.85 ns | 21.75 ns |
| v2inc1 + T | 252,834 | 29.9 % | 2,199 | ABC failure (see below) | 21.14 ns |

Utilisation is std cells / (6x4 core - 2 macros). The step-2 probe had zero GRT overflow up to 29.2 %.
The ABC script of `flow/map/map_v1m.sh slow` fails deterministically on v2inc1 + T ("node has no fanout"
after buffer/upsize). The reduced script `strash; dch; map -D; topo; stime -p` was therefore run on all four for a like-for-like comparison.

Findings:
1. T removes the verdict path as the critical path on v2min (-17 %, reduced script).
2. I2C adds about 3 ns to the unit-step cone itself (reduced script, v2inc1 + T vs v2min). T then saves
   only 3 %, so the new critical path is not in the verdict block. It is most likely the wider ROM fetch
   mux and counters; the path has not been traced.
3. Estimate, not measured: with round-1's routed-slow / reduced-script ratio (27.6 / 18.24 = 1.51),
   v2inc1 + T would need about 32 ns at the slow corner, more than 30.30 ns at 33 MHz. Round-2 CI (33 MHz)
   calibrates this ratio. Then decide between (a) a lower clock for increments, (b) shortening the
   ROM fetch path (a pipelined fetch changes Mon_lane slot timing and needs a new R1), or
   (c) a CI probe of v2inc1 + T to measure directly.

### 1.x CI probe of v2inc1 + T (option (c), agent decision; pushed 2026-11-04)

Round-2 CI calibrates the ratio of finding 3: routed slow-corner critical path 27.31 ns (30.30 - 2.99)
over the reduced-script depth 18.24 ns gives 1.50, so the estimate for v2inc1 + T is 21.14 x 1.50 = 31.7 ns,
about 1.4 ns over 30.30 ns. This is an estimate; the probe measures it.

Branch v2-inc1-i2c (rebased on v2-6x4 131940e) commits the emitted core for the probe:
- `src/pemu_core_v1m.v`: `PEMU_LOADABLE=rom PEMU_LIB=v2inc1 PEMU_SLOTS=5 PEMU_VPIPE=1 emit_lane_rtl.exe
  top_macro_mon_sweep`, then `tools/fix_combdly.py` (8,033 assignments); `tools/check_combdly_equiv.sh`
  raw == fixed EQUIVALENT (379 s). The same recipe with PEMU_LIB=v2min reproduces the v2-6x4
  `src/pemu_core_v1m.v` byte for byte.
- `test/vectors/v1_rom_uart, v1_reset_mid, v2_spi_ctl_uart_rx, v2_spi_tgt_uart_tx`: regenerated with
  the same environment (`dump_tt_vectors_v1.exe` now emits the v2 scenarios for v2inc1 too: packages
  0-3 are unchanged). Each differs from v2min in exactly one row: the fail (uo_out bit 1) or blame
  (bit 2) pin rises one cycle later, the documented T pin latency. RTL replay 5/5 (4 scenarios +
  comparator negative control).
- Not covered by gate-level vectors yet: the I2C packages 4/5 (chip-level cyclesim tests only,
  test_inc1.ml 8/8). E4/E5 for this netlist need their own correspondence map (flow/equiv/maps/).
- info.yaml unchanged (33 MHz, 6x4).

Probe result, CI run 41887577418 (82dd594, 33 MHz, CLOCK_PERIOD 30.30): gds and gl_test PASS (gate-level
replay of the 4 regenerated vectors + comparator control); precheck still running at the time of writing;
the `viewer` render job failed after 11 s (not examined). Post-PnR STA:

| corner | setup WNS | setup violations | hold WNS |
|---|---|---|---|
| slow 1.08 V 125 C | -1.986 ns (TNS -255.1 ns) | 218 | +0.605 ns |
| typ | +10.273 ns | 0 | +0.286 ns |
| fast | +17.281 ns | 0 | +0.108 ns |

Route DRC 0, antenna 0, std-cell area 335,900 um^2 (utilisation 43.5 %), 2,197 flops, max-slew 45,
max-cap 7. Measured slow path 32.3 ns against the 31.7 ns estimate. All 218 violators start at
core._325 (rst_sync_n, a synchronous-clear data input of the step gating) and end in the monitor unit
state (mon_u*_reg/_m0/_k/_pc, mon_vp_code0). Worst path: 1.8 ns to the flop output, about 2.2 ns of
reset fanout buffers (buf_1), then about 29 ns of unit-step logic in _1-drive cells; the six stages with
output slew above 0.9 ns (nor4_1 3.33 ns, nor3_1 2.33, a221oi_1 1.63, o21ai_1 1.56, nand4_1 1.50,
a21oi_1 1.41) sum to about 11.8 ns. Flow settings: ABC strategy AREA 0, post-GRT resizer timing off.

Flow-only probe (branch v2-inc1-delay, run 41946726172, SYNTH_STRATEGY DELAY 0 + post-GRT resizer
timing): slow WNS -6.11 ns, area +12.8 %, rejected. The sg13cmos5l library has the critical complex gates
(nand3, nand4, o21ai, a221oi, a22oi) only in drive 1, so the resizer can only buffer.

30 MHz probe (user choice 2026-11-05), branch v2-inc1-30mhz: the AREA 0 netlist configuration of 82dd594
(same RTL, vectors, src/config.json except CLOCK_PERIOD 33.33; info.yaml clock_hz 30000000). Estimate
before the run: slow setup WNS about +1.0 ns (-1.99 + 3.03), assuming placement and repair stay similar.
The documented protocol divisors (Rom_lib.*_with_p, docs/info.md) are for 33 MHz and are re-derived only
if this probe closes timing; the netlist does not depend on them (P is host-set).

E4/E5 for the 33 MHz v2inc1 + T netlists (82dd594, run 41887577418): both PROVEN, 2,549 of 2,549 pairs
(flow/equiv/run_e5_induct.sh, maps/v2inc1T_82dd594.json, about 290 s each). Synthesis recoded the
same four FSMs (_955, _1039 and two 4-state FSMs, here _10772 and _11245); map: _955[1], _1039[0..2]
renames, one misnamed net (core._13995 holds s2_ui[0], as core._13013 did on v2min), the 3-state FSM
and mon_mask invariants. All 2,197 flops and all output ports paired. Controls on E5: N1 uo_out[0]
driver inverted (0 proven), N4 wrong invariant (51 unproven), N5 xnor2 -> xor2 next to mon_now[5]
(mon_now[5] unproven), all FAIL as required. The 30 MHz build needs its own E5 run on its final netlist.

30 MHz probe result, CI run 42160150374 (d9d2c64): gds, gl_test, precheck PASS (viewer: GitHub Pages
404 as before). Post-PnR slow setup WNS +1.318 ns, 0 violations (estimate +1.0 ns); typ +13.485 ns,
fast +20.435 ns; hold +0.108 ns, 0 violations; area 335,982 um^2 (43.5 %); route DRC 0, antenna 0,
max-slew 45, max-cap 6, Magic illegal overlaps 10. The synthesis netlist is byte-identical to the 33 MHz
one (E4 above covers it); the final netlist differs (repair/placement): E5 on it PROVEN with the
unchanged map maps/v2inc1T_82dd594.json, 2,549 of 2,549 pairs (203 s), all 2,197 flops and all outputs
paired, N1 (uo_out[0] driver inverted) FAIL as required.

Divisors at 30 MHz: `Rom_lib.divisors_at` states the rules behind the documented values (UART
P + 1 = round(f / (115200 * steps)), SPI P = 7, I2C Fm shortest step >= 0.25 us, Sm >= 1 us) and
reproduces the 33 MHz values exactly (test_rom_lib_v2). At 30 MHz: UART TX 64 (+0.16 %), UART RX 32
(bit 264 cycles, -1.4 %), SPI 7, I2C Fm 7 (step 0.267 us, SCL 375 kHz), Sm 29; admissible at 5 slots.
Chip RTL vs Psim at these divisors (cyclesim): J30/K30 (UART RX/TX with a 30 MHz 115200-baud peer, beside
SPI) no firings, chip = Psim; L30 short stop blamed (33@8449), chip = Psim; I2C Fm/Sm set (clean,
stretch, NACK, data delay 30/50/70, + vpipe) chip = Psim, U holds. Data delay 70 cycles (2.33 us, beyond
the Fm 0.9 us data-valid maximum) is now blamed in the first byte (B77@1065; at 33 MHz B77@5950).
The emitted core is unchanged by these edits (byte-identical re-emit). docs/info.md updated for 30 MHz.

## 2. Loadable contracts (option A, doc/decisions/inc2_loadable_options.md): CI probe as-is (user choice 2026-11-06)

Branch v2-inc2-loadA. Lane 1 serial loadable (all 5 slots from a 256x16 store `core.u_lstore_l1`,
65-word context header, five 82-bit IR caches, lowest-index-first fetcher, admission P >= max(4, 6k + 1)
for k enabled units); lane 1 has no ROM; lane 0 keeps the v2inc1 ROM library; verdict pipe on; 30 MHz.
- `src/pemu_core_v1m.v`: PEMU_LOADABLE=l1 PEMU_LIB=v2inc1 PEMU_SLOTS=5 PEMU_VPIPE=1, fix_combdly applied
  (equivalence check of the transform not yet run; it does not gate this probe).
- Floorplan: floorplan C of v1-tt adapted to 6x4: u_lstore_l1 (3.36, 41.58), u_imem_l1 stacked at
  (3.36, 207.9), u_imem_l0 (981.44, 41.58); PDN macro connections include lstore_l1.
- Vectors regenerated from this RTL (5 scenarios incl. v1_loadable_l1: UART TX loaded into lane 1,
  context loaded, no firing). The v2 scenarios select ROM SPI on lane 1, which this build no longer has:
  their lane-1 SPI is unmonitored here, so these vectors check RTL vs netlist only. RTL replay 6/6.
- Local synthesis 398,826 um^2 (3,571 flops); projected routed utilisation about 68 % [estimate].
- Not yet verified: loadable functional tests beyond the one positive scenario, F0-F2 proofs for the
  serial fetcher/loader, E4/E5.

Probe result, CI run 42242730817 (d7deed2): FAILED, not routable in the 6x4 floorplan as built.
- Build GDS ran 5.77 h (job limit 6 h). Per-step time from the job log: DetailedRouting 294.2 min,
  RepairDesignPostGRT 24.8 min, GlobalRouting 7.5 min, KLayout.DRC 7.1 min (green runs: 80-117 min total).
- Placement: effective utilisation 0.567; global placement routing overflow on about 10.4 % of tiles
  (1,826 overflowed tiles at the last report). Detailed routing did not converge: 37,929 violations
  after iteration 0, 22,474 after 1, 19,872 after 2 (later iterations not extracted).
- End of flow: Magic illegal overlaps 48 (10 on all earlier runs); LibreLane Netgen.LVS crashed parsing
  Netgen's JSON (`Invalid \escape`), which suggests an LVS mismatch report listing escaped net names
  [inference]. No artifacts were uploaded (artifact storage quota full at the time).
- Conclusion: option A as built (local synthesis 398.8k um^2, projected about 68 %) exceeds what this
  floorplan routes; the highest measured routable point remains 43.5 % (increment-1 build).

### 2.D Option D: host-loadable window tables on the ROM lanes (user choice 2026-11-06)

`Mon_engine ~param_windows` (default off; shipped cores re-emit byte-identically): per lane WIN_CTL
(+3, bit7 override, [2:0] index), WIN_LO (+6), WIN_HI (+7, commit); windows 1-7 of the lane's tables
come from these registers when the override is on. Reach (doc/decisions/inc2_loadable_options.md
section 6): uart_tx d 3-12, spi_tgt g 6-12, i2c_ctl one more class, i2c_tgt 12 classes.
- Local synthesis: 275,239 um^2, 2,399 flops (+22.4k, +200 flops over the shipped 30 MHz core);
  projected routed utilisation about 46.8 % [estimate].
- Chip RTL vs Psim, exact differential (rtl_v1/test/test_inc2d.ml): ROM package + loaded windows of a
  variant = Psim with the variant contract, and without the override = Psim with the shipped contract:
  uart_tx d6 on ROM d4 (clean: fail 13@81 without override, accepted with; bad start fail 13@97),
  spi_tgt g9 on ROM g6 (gap 64 cycles: accepted by g6, blamed 55@1049 by g9; gap 40 blamed by both
  at 55@1025; gap 144 clean), i2c_ctl l7h5 firmware on the Fm package (F61@5392 without override,
  clean with). Registers: readback 0x0234, writes refused while the lane runs.
- Probe branch v2-inc2-pwin: src core PEMU_PWIN=1 PEMU_LOADABLE=rom PEMU_LIB=v2inc1 PEMU_SLOTS=5
  PEMU_VPIPE=1 (fix_combdly applied), 30 MHz config of v2-inc1-30mhz (2 macros); vectors from this RTL
  including v2_pwin_uart (override off: fail 13; windows(d6) loaded: clean; d6 bad start: fail 14);
  RTL replay 6/6.

CI run 42304838081 (v2-inc2-pwin 4a84397, attempt 2 after the repo was made public; attempt 1 cancelled
for Actions minutes): gds 1 h 51 min, precheck pass, gl_test pass (viewer job fails as on every run).
Core in the run == flow/equiv/work/inc2/pw_fixed.v (cmp).

| metric | inc1 30 MHz (42160150374) | option D (42304838081) |
|---|---|---|
| std-cell area | 335,982 um^2 | 366,728 um^2 |
| utilisation | 43.47 % | 46.87 % (projected 46.8 %) |
| std cells / instances | 25,345 / 77,343 | 27,555 / 77,789 |
| setup WS slow / typ / fast | +1.318 / - / - ns | +3.643 / +14.896 / +21.268 ns |
| hold WS (fast) | +0.108 ns | +0.099 ns |
| setup / hold violations | 0 / 0 | 0 / 0 |
| route DRC, KLayout DRC, LVS, antenna | 0, 0, 0, 0 | 0, 0, 0, 0 |
| max slew / max cap / max fanout | 45 / 6 / 162 | 60 / 6 / 187 |
| Magic illegal overlaps | 10 | 10 |
| wirelength / vias | 1,290,237 / 177,034 | 1,345,807 / 193,086 |
| power (total) | 4.86 mW | 5.30 mW |

Slow-corner worst path (57-openroad-stapostpnr/nom_slow_1p08V_125C/max.rpt): start _38194_ = core._325
(reset synchroniser), end _37305_ = core.mon_u3_pc[5] (+3.643 ns), next _36013_ = core.mon_u0_pc_0[5]
(+3.651 ns); data arrival 30.41 ns. Slack rose by 2.3 ns although logic was added; I read that as
placement variation between runs, not as a property of option D [inference], so the 30 MHz margin to
plan with is the smaller of the two runs (+1.3 ns).

E4/E5 (flow/equiv/maps/v2pwin_4a84397.json; prep_cut_v1m.sh + run_e5_induct.sh): E5 proven 2,749/2,749
(254 s), E4 proven 2,749/2,749 (269 s). The only new map entry is the misnamed flop _14241 = s2_ui[0]
(same pattern as _13013 in v2-min and _13995 in increment 1); a first run without it left exactly that
pair unproven. All 2,397 gate flops paired, outputs and both macro buses paired. Negative controls:
N1 (uo_out[0] inverted) 0 proven; N4 (wrong FSM invariant) 51 unproven; N5 (xnor2 -> xor2 in the
mon_now[5] cone) exactly mon_now[5] unproven. Status: option D signed off at 30 MHz on 6x4.

## 3. Increment 3: I2C target, standard mode (ROM package 6)

Branch v2-inc3-i2ctgt (from v2-inc2-pwin). Library `Rom_lib.v2_inc3` = v2inc1 + `i2c_tgt` Sm; the
build is PEMU_LIB=v2inc3 PEMU_LOADABLE=rom PEMU_SLOTS=5 PEMU_VPIPE=1 PEMU_PWIN=1.

### 3.1 Divisor and contract parameters (agent decision under delegation)

The contract counts steps, so its parameters depend on the clock and P. Rule of
doc/protocols/i2c_v1.md 3.2, floor(UM10204 minimum / step) - 1. Constraint: the firmware detects
START by polling (about 7 steps), so hd must stay above that or a short tHD;STA is missed silently.
Measured in Psim (protocols_v1/test/test_i2c_tgt30.ml, controller peer at the 30 MHz Sm minima,
tHD;STA swept 20-120 cycles):
- P = 4..12: clean at the minima, every failed transaction with a short tHD;STA is blamed (B82),
  no silent miss;
- P = 14, 16: transactions fail at the minima without any firing (silent). The earlier
  "P <= 17" estimate in log/protocols_v2.md (from 33 MHz arithmetic) was wrong;
- P = 4 works from tHD;STA = 30 cycles and blames every value below 120 that was tested.
Decision: P = 4 (admission minimum, finest step 0.167 us): h_min 23, l_min 27, hd 23
(`Rom_lib.i2c_tgt_sm_params`; 33 MHz would give 25/30/25). Further Psim checks at P = 4: clock
stretching up to 102,325 cycles clean; controller faults blamed (tLOW 120: B71, tHIGH 100: B72,
late data: B83, tHD;STA 60: B82); firmware mutants fail (F54 missing ACK, F57 LSB-first write,
F55 LSB-first read, F61 stretch in high phase, F61 read data change in high phase); "ACK address
0x51" is undetected, as documented ([O]).

### 3.2 A2 at the new parameters (bounded, same evidence class as v1 Sm)

A2 is spec-level with free ticks, so only the contract parameters matter. New harnesses
a2_i2c_tgt_sm30_{u, n1_cover_neg, noack_neg, stretchhigh_neg} (formal/src/ag_pkg.ml, EA1 as v1;
model 23 inputs, 299 latches, 6,757 AND gates). inv_traces got an `_sm30_` controller base (Sm
minima in 30 MHz steps at P = 4); with the v1 Sm base no B1 violation would be generated.
- co-sim, Hardcaml debug harness, replayed on the AIG (aigsim): clean 512 x 30,000 cycles
  (15.36M, 14,162,470 guarded) and adversarial 512 x 30,000 (15.36M, 4,689,424 guarded): bad 0,
  AIG-vs-Hardcaml bad mismatch 0;
- controls on clean traffic (64 x 30,000 each): N1 cover 98 bad cycles (non-vacuity), noack 34,
  stretchhigh 18;
- checkpoint BMC (formal/inv/ckpt_bmc.py, bmc3, depth 40, 300 s per window): 8 clean traces x
  checkpoints 300/2,000/6,000/12,000/20,000 = 40 windows, 0 hits; 35 windows to 40 frames, 2 to
  38/39, 3 (all at checkpoint 6,000) stopped at the cap without a reported depth. Self-test on the
  noack mutant from 20 cycles before its first bad cycle: hit at +2 frames, cyclesim replay OK
  (F54 at frame 9454).
Status: U bounded, not proved (as v1 Sm). A window covers at most 40 steps, less than one SCL
period (about 52 steps), so long-range relations rest on the co-simulation.

### 3.3 Chip level

- rtl_v1/test/test_inc3.ml, v2 top RTL vs Psim (shipped configuration vpipe + param_windows, and
  the default build): clean, tLOW 120, tHIGH 100, tHD;STA 60, late data: monitor-input stream,
  owned pins, verdict and pushes equal in all 6.
- Harness fix (test_c3_diff.chip_run): the peer is no longer called before Psim cycle 0. The I2C
  controller peer counts its own calls, so the calls during the RUN write started its START about
  195 cycles early (all earlier peers were reactive or time-based; no other expect output changed).
- Admissibility (test_rom_lib_v2.ml): 7 packages admissible at 5 slots; i2c_tgt 5 units, 107
  instructions.
- Core: COMBDLY fix equivalence-checked (832 s); vectors v2_i2c_tgt (43,630 cycles, VERDICT 0) and
  v2_i2c_tgt_blame (43,510, blame 0x82); the other 5 vectors regenerate byte-identically; local RTL
  replay 8/8.
- Local synthesis (flow/map/map_v1m.sh typ): 281,887 um^2, +6,648 over option D. Projected routed
  utilisation about 48.0 % [estimate, option-D routed/local ratio 1.332], above the highest
  measured routable point (46.9 %); a CI run decides.

### 3.4 First CI run fails timing; pipelined monitor schedule (user choice: RTL fix)

CI run 42335133787 (29c780b, P = 4 build): gds, precheck and gl_test pass, routing clean (48.11 %
utilisation, 377,905 um^2 std cells, route DRC / KLayout DRC / LVS 0, 1 antenna net, wirelength
1,531,915 um = +14 % over option D for +3 % area), but slow-corner setup WS -3.536 ns with 490
violating endpoints (typ +10.30 ns, hold +0.113 ns). Every violator starts at core._325
(rst_sync_n) and ends in the lane-0 unit state (mon_u*_reg/m0/k/pc/stopped). Worst path: 4.5 ns
of reset buffer tree, then the reset/running/tick gating of slot 0 and the unit datapath, with two
nor4_1 stages on long wires (3.6 and 2.2 ns); arrival 37.60 ns at 33.33 ns. The same cone was the
worst path in every v2 run (+1.32 ns inc1, +3.64 ns option D), so it varies by several ns between
placements. The local slow-script depth predicted none of these swings.

Fix (Mon_lane ~pipe, Mon_engine ~lane_pipe, Top_v1/emitter/vectors PEMU_LPIPE=1; default off,
default builds re-emit byte-identically): slot u runs in cycle tick + 1 + u, always from the bank,
events and step mask latched at the tick; the tick only enables those latches and starts the
sequencer (busy_q = slot runs now, cur = slot_q). Consequences: a firing appears one cycle later
(stamp unchanged), the registered blame reaches the lane at t + j + 2, so ROM-lane admission is
P >= slots (5); the I2C target moves to P = 5 with contract 19/22/19 (Psim at P = 5: clean at the
minima, every short tHD;STA blamed, no silent miss; stretching to 102,324 cycles; controller
faults B71/B72/B83/B82; firmware mutants F54/F57/F55/F61/F61 without prior blame).
- Local reduced-script slow depth (flow/map/map_v1m.sh slowr): 21.43 ns -> 14.66 ns; area typ
  283,629 um^2 (+1.7k). Routed slow path about 24.6 ns at the 1.68 routed/local ratio of run
  42335133787 [estimate], i.e. about +8.7 ns at 30 MHz.
- R1 (formal/src/mon_ref.ml ~pipe, claim t + j + 1, ENGINE=ind): r1v2p_s5_u0..u4 PASS (2-3 s each),
  r1v2p_s5_u4_t5 (ticks 5 apart) PASS; negatives r1v2p_s5_u4_t4_neg FAIL depth 6 and
  r1v2p_s5_u3_smask_neg FAIL depth 5, both replay ok. (A first control at spacing 5 was not a
  negative: slot 4 then runs in the next tick cycle from the old latches, which is correct.)
  The unpipelined r1v2_s5_u0..u4 still PASS.
- A2 at 19/22/19 (same method as 3.2): co-sim clean 512 x 30,000 (14,121,050 guarded) and
  adversarial 512 x 30,000 (4,833,844 guarded), bad 0, AIG/Hardcaml mismatch 0; controls N1 108,
  noack 36, stretchhigh 18 bad cycles; checkpoint BMC 40 windows no hit (29 to 40 frames, 11 to
  32-39 frames at the 300 s cap); self-test hit at +2, replay OK (F54 at frame 7889). Bounded.
- Chip RTL vs Psim (rtl_v1/test/test_inc3.ml, lane pipe + vpipe + param_windows): I2C target 6
  scenarios equal; the 8 C3 directed scenarios of the v2 minimum packages equal (codes and stamps
  as without the pipe); admission: P = 4 refused, P = 5 runs.
- Vectors: v1_reset_mid identical; v1_rom_uart, v2_pwin_uart, v2_spi_*: one row each differs,
  the verdict pin rising one cycle later; v2_i2c_tgt(_blame) regenerated at P = 5. Combdly fix
  equivalence-checked (566 s); RTL replay 8/8.
- Open: C3 host-clear divergence window is now 1..j+1 cycles (paper argument of proofs_v2 7.x
  shifts by one; the clear-fault sweep was not re-run with the pipe).

### 3.5 Pipelined build: CI and sign-off

CI run 42387459848 (a1e567e; core == flow/equiv/work/inc3p5/c_fixed.v): gds 2 h 34 min, precheck
pass, gl_test pass (viewer fails as always).

| metric | option D (42304838081) | inc3, P = 4 (42335133787) | inc3 + lane_pipe (42387459848) |
|---|---|---|---|
| std-cell area / utilisation | 366,728 / 46.87 % | 377,905 / 48.11 % | 378,963 / 48.23 % |
| setup WS slow / typ / fast (ns) | +3.643 / +14.896 / +21.268 | -3.536 / +10.299 / +18.392 | +6.341 / +16.387 / +22.331 |
| setup violations / hold WS | 0 / +0.099 | 490 / +0.113 | 0 / +0.098 |
| route DRC, KLayout DRC, LVS, antenna | 0, 0, 0, 0 | 0, 0, 0, 1 | 0, 0, 0, 0 |
| max slew / cap / fanout | 60 / 6 / 187 | 117 / 12 / 184 | 91 / 8 / 192 |
| wirelength (um) / power | 1,345,807 / 5.30 mW | 1,531,915 / 5.35 mW | 1,498,218 / 5.41 mW |

Worst slow path now starts at the sequencer register mon_slot[2] and ends in mon_u2_pc_0[3]
(+6.341 ns, arrival 27.74 ns); the reset synchroniser no longer starts the worst path. The
estimate of 3.4 (+8.7 ns) was 2.4 ns optimistic.

E4/E5 (maps/v2inc3p_a1e567e.json): E5 proven 2,744/2,744 (246 s), E4 proven 2,744/2,744 (234 s).
New entries beyond the option-D map: misnamed flop _14749 = s2_ui[0]; invariants mon_smask(_0)
bits equal; mon_bank_l(_0)[15] == 0 and (~mon_busy | mon_bank_l[0]) (synthesis removed these
constant bits; with the pipe every slot reads the bank copy, so the free gold bits had left all
unit state unproven: 588 then 328 unproven before the invariants were complete; a first try had
bits 0 and 15 swapped, the concatenation is MSB first). All 2,452 gate flops paired, outputs and
both macro buses paired. Controls: N1 0 proven; N4 19 unproven; N5 exactly mon_now[5] unproven.
Status: increment 3 signed off at 30 MHz on 6x4.
