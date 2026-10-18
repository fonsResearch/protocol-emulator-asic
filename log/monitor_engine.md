# Plan step 6: monitor engine RTL v1 and contract compiler

Date 2026-10-18. Specification: `doc/contracts/monitor_isa_v1.md`. Decisions: `doc/decisions/arch_v1_options.md` section M. All numbers below are copied from expect tests in the repository, proof result rows, or synthesis logs. Estimates are marked as such.

## 1. What exists

| layer | file | role |
|---|---|---|
| language | `monitor_v1/src/lang.ml`, `interp.ml` | EDSL and reference semantics |
| compiler | `compile.ml`, `mprog.ml` | EDSL to ISA; 82-bit encoding; store image |
| ISA model | `mmodel.ml` | executable ISA semantics |
| spec circuit | `mon_spec.ml` | parallel Hardcaml circuit of the ISA (8 units) |
| engine lane | `mon_lane.ml` | time-multiplexed lane: parallel bank, one unit datapath, 8 slots |
| engine | `mon_engine.ml` | 2 lanes, ROM library, verdict, registers, loadable store path (lane 1) |
| core | `rtl_v1/src/top_v1.ml` `?lib ?loadable` | engine wired to lanes, pins, SPI registers, admission |
| proofs | `formal/src/mon_ref.ml`, `mon_fetch.ml` | R1, F0, F1t, F1d, F2 |

## 2. Simulation evidence (cyclesim, expect tests)

Chain: interpreter = ISA model = spec circuit = multiplexed lane = core over the pins.

| comparison | workload | result |
|---|---|---|
| Interp vs Mmodel | 677 compiled random packages, 271,477 cycles, 6,635 firings | 0 mismatches |
| Interp vs Mmodel, UART TX package on lane traces | correct / start d+1 / MSB first / stop d-1 | firings 0 / 40 / 40 / 39, 0 mismatches |
| Mmodel vs Mon_spec | 200 packages x 401 cycles (80,200 cycles), 1,984 firings | 0 mismatches |
| Mmodel vs Mon_spec, UART TX package | correct / 3 faulty programs | firings 0 / 11 / 11 / 11, 0 mismatches |
| Mon_spec vs Mon_lane, T8 | 200 packages, 66,623 steps, 24,673 firings | 0 mismatches |
| same, all 8 units filled | 66,656 steps, 109,065 firings | 0 mismatches |
| same, spacing 13 | 10,636 steps, 4,188 firings | 0 mismatches |
| same, spacing 7 (T8 broken) | 18,780 steps, 30,921 firings | 3,310 mismatches, 10,237 overruns (assumption is needed) |

Mutation sensitivity: Mon_spec 8/8 planted mutants detected; Mon_lane 6/7 detected, the survivor (write only when act) is equivalent.

Generator coverage: each language construct appears in at least 85 packages (`since`); modified expects in 327.

Over the pins (core, `rtl_v1/test/test_top_mon.ml`):
- **Admission.** P = 6 refused (FLAGS 0x14). RUN without a loaded context refused. P = 12 with two loadable units refused. P = 13 runs.
- **Correct UART TX program.** VERDICT 0x00.
- **Faulty start bit d+1.** Fail pin `uo[1]` = 1, FIRST_FAIL 0x13 (data bit 0).
- **Blame on `ui_in[3]`.** Lane 1 faults with cause BLAME (FAULT 0x20), FIRST_BLAME 0x41, first-blame lane 1.
- **CLR_VERDICT.** Clears flags, codes and times.
- **Lockstep ROM vs loaded.** Lane 0 runs the UART package from ROM (units 0, 1); lane 1 runs the same package loaded into its store (units 6, 7). Same program and P, one CTRL write. Faulty program on lane 0 only: FIRST_FAIL 0x13, unit 0, FAIL_TIME 42208. On lane 1 only: FIRST_FAIL 0x13, unit 6, FAIL_TIME 42208.
- **Structural non-interference with the engine.** 0 other-lane signals with the OWN boundary (4,110 without). With the monitor view unmasked the check finds 4,110 (sensitivity).

## 3. Formal results (ABC; formal/README.md)

| harness | claim | expected | engine | result | latches | wall s |
|---|---|---|---|---|---|---|
| r1_mon_lane_u0 .. u7 | Mon_lane refines Mon_spec, unit j | PASS | ind | PASS (each) | 1,214 | 3-5 |
| r1_mon_lane_u3_smask_neg | step mask unlatched | FAIL | bmc | FAIL depth 4, replay ok | 1,207 | 1 |
| r1_mon_lane_u7_t7_neg | T8 relaxed to 7 | FAIL | bmc | FAIL depth 8, replay ok (reset only in frame 0; steps at 1 and 8) | 1,214 | 2 |
| f0_mon_pc_eff | pc_eff and slot timing of units 6/7 | PASS | dprove | PASS | 1,510 | 15 |
| f0_mon_pc_eff_mask_neg | pc_eff ignores the step mask | FAIL | dprove | FAIL depth 2, replay ok | 1,510 | 0 |
| f1t_mon_fetch | IR valid at every loadable slot | PASS | dprove | PASS | 63 | 14 |
| f1t_mon_fetch_restart_neg | completion restart bug | FAIL | bmc | FAIL depth 14, replay ok | 63 | 0 |
| f1t_mon_fetch_runonly_neg | fetch gated by running only | FAIL | bmc | FAIL depth 14, replay ok | 63 | 0 |
| f1t_mon_fetch_p11_neg | min_p 11 with two units | FAIL | bmc | FAIL depth 31, replay ok | 63 | 1 |
| f1d_mon_fetch_data | valid IR words = store words | PASS | ind | PASS | 311 | 0 |
| f1d_mon_fetch_data_addr_neg | fetch address off by one | FAIL | bmc | FAIL depth 2, replay ok | 311 | 0 |
| f2_mon_ctx_load | context registers = stored header | PASS | ind | PASS | 1,698 | 2 |
| f2_mon_ctx_load_delay_neg | loader ignores read latency | FAIL | bmc | FAIL depth 3, replay ok | 1,692 | 0 |

**What the proofs give together.** A firing of the time-multiplexed engine is the firing the parallel ISA circuit produces at that step (R1). This holds for any constant tables and any instruction source, given T8. For the loadable lane, the instruction a slot evaluates is the stored instruction at its pc (F0 + F1t + F1d), and the tables are the stored header (F2).

**Not proved, tested only:**
- Mon_spec = Mmodel = Interp (differential tests);
- the ROM library muxes and register file of Mon_engine;
- the verdict block's first-cause ordering.

The R1/F1/F2 composition is a paper argument stated in the harness headers. It is not machine-checked as one theorem.

**Engine note [agent choice, flagged].** R1, F1d and F2 are proved with ABC k-induction (`ENGINE=ind`), because their properties carry explicit strengthening invariants; `dprove` timed out on them at 3,600 s. The project default remains `dprove` (user decision 2026-09-27).

**Harness corrections made during this step:**
- R1 `clean`: a slot check coinciding with a new step ignored resets inside the window. This affected only the negative control's witness.
- F0: in a reset cycle Mon_lane may still evaluate the slot due, without effect, so check (b) is restricted to non-reset cycles.
- F1 negative: P = 12 is not a violation, so the control uses P = 11.
- F2 negative: the first mutant was equivalent.
- Counterexample replayer: values wider than 62 bits were truncated.

## 4. Design bugs found and fixed in this step

1. **Bare-modifier expect never fired.** An `expect` on a bare `Reg_bit`/`Elapsed_ge` compiled to predicate 0 plus a modifier, and the model and circuit read predicate 0 as "no expect". Found by widening the random generator. With the old rule the model differs from the interpreter in 697 cycles.
2. **Context-write race.** A PKG/REMAP write in the cycles after a lane halts could change the tables under the pending slots of its last step. Found while writing R1; context writes now need the sequencer idle (directed test).
3. **Fetch restart loop.** A completing fetch saw the stale valid bit and restarted forever. Found by the fetch_late flag in the first end-to-end run.
4. **Fetch aborted on halt.** A lane halting just after a tick aborted a fetch that slots 6/7 of that step still needed. Found while writing F1; the fetcher is now enabled while slots are pending. `f1t_mon_fetch_runonly_neg` reproduces the old behaviour.
5. **Combinational loop** in the loader's context-write gate, caught by cyclesim at elaboration.

## 5. Area and timing (Yosys 0.69 / ABC, IHP sg13cmos5l stdcells, no wire load)

| build | std-cell area typ | flops | SRAM macros |
|---|---|---|---|
| core v1, no engine (earlier) | ~97,914 um2 | - | 2 |
| engine, ROM only (2-package library) | 183,611 um2 | 1,870 | 2 |
| engine, lane 1 loadable (default) | 353,835 um2 | 3,174 | 3 |
| engine, both lanes loadable | 524,486 um2 | 4,477 | 4 |

- **Default build total.** 353,835 + 3 x 28,127 = ~438k um2, 36% of the 8x4 core area (1,208,173 um2).
- **Post-route estimate.** At an estimated ~1.3x growth (one published IHP tile, not a rule), standard cells come to ~42% of the placeable area, against the TT 60% default target density. The 2-package test library understates the final ROM.
- **Slow-corner logic depth** (1.08 V/125 C, register to register, no wires): 10.99 ns for the default build (7.11 ns for ROM only), against 16.67 ns at 60 MHz.
- **Not measured.** Paths from SRAM A_DOUT (5.13 ns clock-to-out at the slow corner) and wire delay. They need OpenROAD STA (TT CI, plan step 8). Candidate if tight: register the bank or prefetch the slot's instruction one cycle early.
- **Verilog.** COMBDLY post-process of the default build (6,289 assignments) proved equivalent with Yosys `equiv_*` (7 min; script now uses `proc -norom`). No X literals in the emitted Verilog.

## 6. Open items handed to later steps

- **Step 7** (protocol packages): the real ROM library (floor protocols) and its area. Package proofs (A2) against Mon_spec.
- **Step 8** (silicon path): OpenROAD timing including A_DOUT paths. A third macro (lane 1 store) in the floorplan and PDN.
- **Reviews requested from the user** (agent choices, all marked [choice] in the ISA document):
  - restart rule;
  - registered blame (one extra lane step before release);
  - a firing in the same cycle as CLR_VERDICT survives;
  - min_p = 13 (12 suffices);
  - VERDICT/FIRST_UNITS layout;
  - `ind` as proof engine for the strengthened harnesses.
