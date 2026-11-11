# Oracle independence campaign v2 (plan step 9)

Date: 2026-11-08 to 2026-11-10. Design: branch v2-inc5-usb at the tape-out candidate (commit
d9d97d2 RTL; the campaign adds no RTL change: the mutation hooks below are no-ops and the emitted
core stays byte-identical to `src/pemu_core_v1m.v`, checked by cmp). Generated tables:
`log/kill_matrix_v2.md`; per-mutant rows: `log/kill_matrix_v2.csv`,
`log/kill_matrix_v2_contracts.csv`; figure: `log/kill_sets_v2.png`. All runs local.

Scope (user decisions 2026-11-08): SIM on every graph mutant; the full oracle matrix on a
stratified sample of 120 per unit; libsigrokdecode rebuilt as a spec-free oracle (no timed-QED
port, no demo-board sub-sample); contract mutants on the five packages with unbounded A2 proofs.

## 1. Mutants

Graph mutants: the v1 signal-graph mutator (`formal/src/mutate.ml`, operators op_swap,
const_invert, off_by_one, mux_swap, clear_drop, enable_drop), on new scopes
(`formal/src/mutate_v2.ml`):

| unit | design | sites |
|---|---|---|
| lane_rtl | `Lane_rtl` (SRAM macro stubbed) | 1,970 |
| lane_spec | `Lane_circuit` (imem stubbed) | 1,623 |
| mon_lane | `Mon_lane`, shipped 5 slots + pipelined schedule, own observation front end; tables, present bits and fetched word are inputs (ROM contents are not mutated here) | 1,789 |

The identity copy (index id) passes every oracle on all three units, which validates the copier on
the v2 graphs. Sample: 120 per unit, stratified by operator, seed 20261108
(`formal/mutation/v2/sample.py`).

Contract mutants (`formal/src/cmut.ml`) on the Lang source of uart_tx, uart_rx, spi_ctl m0,
spi_tgt m0, usb_ls_tx: window bound +-1, hold length +-1, drop a check, fail<->blame, code + 1,
negate an expect. 861 sites; 345 are rejected by `Lang.validate`, `Compile` or the slot limit
and not sampled. 166 of the rejections are role swaps refused by well-formedness rule WF2 (a
blame check may not constrain chip-driven observables): the contract language statically
excludes the error "a guarantee written as an assumption" on chip outputs. Sample: 20 valid per
package.

## 2. Oracles

| oracle | family | unit(s) | what it is |
|---|---|---|---|
| SIM | spec-based | all | the unit's differential cyclesim test with the mutant (lane vs `Lane_model`, 300 programs x 2,000 cycles; monitor vs `Mon_spec`, 200 random packages, tick spacing 5 and 9). New expect test pins the shipped monitor configuration: 0 mismatches over 101,313 steps, negative control (spacing 4) 1,481 |
| A1 | spec-based | lane_rtl, lane_spec | lane refinement, L1 + L2 (RTL), L2 + L3 (spec), dprove. All applicable obligations PASS = proven pin-equivalent, excluded from denominators |
| A2 | spec-free | lane_spec | package U proofs uart_tx d4 and spi_ctl m0 on the mutant spec lane |
| R1b | spec-based | mon_lane | R1 refinement claim only, bounded: BMC 20 frames (about 3 steps at tick spacing 6). See 5.1 |
| C3 | spec-based | lane_rtl, mon_lane | v2 top with the mutant in both lanes vs Psim, 11 directed scenarios (C3 set + USB + I2C controller) |
| SR | spec-free | lane_rtl, mon_lane | libsigrokdecode (uart, spi, usb_signalling + usb_packet, i2c) on the same chip runs' pad traces vs the intended traffic, plus pushed bytes vs bytes the peer sent |
| A2U, A2N, SV | contract | contracts | A2U: U proof with the shipped firmware; A2N: the package's firmware-mutant negatives must still FAIL; SV: Psim directed scenarios (peer defects, firmware mutants) vs the shipped contract's firings |

Every formal kill is a counterexample replayed in cyclesim.

## 3. Results

### 3.1 SIM, full population

| unit | killed | survived | kill rate |
|---|---|---|---|
| lane_rtl | 1,544 | 426 | 78.4 % |
| lane_spec | 1,212 | 411 | 74.7 % |
| mon_lane | 818 | 971 | 45.7 % |

No errors or timeouts (5,382 mutants, 128 min on 9 jobs).

### 3.2 Sample, full matrix (denominator = not proven equivalent)

| unit | equivalent (excluded) | denominator | SIM | A1 | A2 | R1b | C3 | SR | no kill |
|---|---|---|---|---|---|---|---|---|---|
| lane_rtl | 16 (A1) | 104 | 92 | 104 | - | - | 54 | 51 | 0 |
| lane_spec | 28 (A1) | 92 | 87 | 91 | 30 | - | - | - | 1 |
| mon_lane | 29 (equivalence triage) | 91 | 60 | - | - | 78 | 21 | 0 | 10 |

Unique kills (exactly one oracle): lane_rtl A1 11; lane_spec A1 3; mon_lane R1b 18, SIM 3. 95 %
intervals per cell are in `log/kill_matrix_v2.md`.

Findings:
1. A1 kills every non-equivalent lane mutant in the sample except one undecided (lane_spec 1525,
   clear_drop on lane_rx_head, A1 L2 undecided at 900 s, every other oracle survived). SIM misses
   12 of the 104 non-equivalent lane_rtl mutants; all 12 are A1 kills, 11 of them unique.
2. Spec-free oracles: SR kills 51/104 lane_rtl mutants and A2 30/92 lane_spec mutants; every SR kill
   is also a spec-based kill in this sample, so SR adds independence, not coverage.
3. SR kills 0/91 monitor mutants. This is structural: the monitor only observes (release_on_blame
   is off in the scenarios), so a monitor bug never changes the traffic on the pins. Monitor
   correctness rests on spec-based oracles and on the verdict comparison (C3, 21/91).
4. C3 is the weakest chip-level oracle for the monitor (21/91): its 11 scenarios exercise few
   watcher paths.

### 3.3 Monitor survivor triage

The 39 monitor mutants no oracle killed were checked against the unmodified lane
(`Mut_v2_harness.eq_mon`: same inputs, same free-but-constant tables and present bits, same
fetched word, dprove):

| class | mutants | meaning |
|---|---|---|
| EQ | 26 | sequentially equivalent on every output for any tables and inputs (unbounded proof) |
| EQ-rom | 3 (1759, 1765, 1770) | differ only in act/pc6/pc7/pcs, which feed only the loadable fetcher; the shipped ROM-mode build has no fetcher, so equivalent for the shipped chip |
| NE | 10 | firings differ even under the tick-spacing assumption (steps >= 6 apart), counterexamples at depth 20 (one at 26), replayed |

Without the tick-spacing assumption the 10 NE counterexamples are 5-6 frames deep; with it they are
20-26 frames, i.e. at or past R1b's 20-frame bound, which is why R1b missed them. SIM with 10x the
package budget (2,000 compiled random packages) kills 6 of the 10 (148, 711, 943, 1048, 1174, 1175,
at packages 215-667), so those divergences are reachable with compiled packages and were only rare.
4 (587, 626, 860, 876) survive 911,564 steps; whether their divergence needs tables the compiler
never produces is open.

Interpretation: these survivors measure the campaign's oracles at their campaign budgets. The
shipped `Mon_lane` is signed off by the unbounded R1 proof (r1v2p_s5_u0..u4, k-induction); a design
with any of these firing divergences under the tick-spacing assumption would falsify R1's claim.

### 3.4 Contract mutants

| package | A2U K | A2N K | SV K | none |
|---|---|---|---|---|
| uart_tx | 9 | 1 | 9 | 11 |
| uart_rx | 2 (3 U) | 0 | 8 | 12 |
| spi_ctl | 8 | 0 | 9 | 11 |
| spi_tgt | 4 | 0 | 3 | 14 |
| usb | 4 (11 U) | 0 | 4 | 15 |

63/100 contract mutants are caught by no oracle (kill sets: none 63, A2U+SV 22, SV 10, A2U 4,
A2U+A2N+SV 1). By operator class: code bump 0/14 caught, role swap 0/3, weakening 8/40, shorter
hold 8/10, longer hold 17/21, other strengthening 3/11. USB U proofs mostly time out at 1,800 s on
mutated contracts (shipped proof: 1,246 s).

Cause, measured with `mutants_v2.exe ccov`: the directed scenarios fire 10 of the 65 distinct checks
of the five contracts (uart_tx 1/12, uart_rx 2/15, spi_ctl 1/13, spi_tgt 5/14, usb 1/11). A mutation
of a check no scenario or negative ever triggers can only be noticed by A2U, and only if it
strengthens the check enough to reject the correct firmware. The contract-error tolerance figure
is therefore mostly a statement about fault-scenario coverage of the checks, not about the
contracts. Remedy (done 2026-11-11, `log/witness_v2.md`): a per-check witness obligation, i.e.
every fail check fires for some chip behaviour and every blame check for some peer behaviour.
All 103 checks of the 8 shipped contracts are witnessed. Replaying the witnesses as oracle W
kills 70 of the 100 sampled contract mutants and lowers the undetected count from 63/100 to
25/100: code bumps 14 to 2 survivors, role swaps 3 to 0, weakenings 32 to 15. The 25 survivors
are 15 mutants on statements whose code is shared with the witnessed statement, and 10 bound
changes that no witness probes (`log/witness_v2.md` section 5).

## 4. Comparison with v1 (log/kill_matrix.md, slice engine)

v1: 446 mutants, oracles SIM / A1 / A2 / B1 on the slice engine; spec-free oracles killed 59/169 RTL
mutants. v2 targets the shipped units (v1 lane, v2 monitor lane) and adds chip-level and contract
mutants; the lane result (A1 104/104, SR 51/104) is the comparable line. Not comparable one to one:
different designs, operators applied to larger graphs, sampled instead of exhaustive.

## 5. Method notes and deviations

1. R1 on mutants is bounded (R1b). Site indices must refer to the same graph as the SIM oracle, so
   the mutant lane uses the canonical scope (its own observation front end, no only_unit). The
   shipped R1 invariants do not cover two separate front ends, and k-induction is undecided on the
   identity copy in that scope (4-8 s). The claim alone is checked by BMC; depth 20 was chosen by
   cost (20 frames 33 s, 24 frames 80 s, 48 frames over 900 s per unit, measured on the identity).
2. Counterexample replay: for 60 formal FAIL rows, bmc3 could not reach the failing depth within
   the limit (dprove's sequential reductions find the failure far faster than plain BMC), so the
   replay was missing. `formal/prove_one.sh` now falls back to dprove's own counterexample and
   counts a kill when bad rises in cyclesim; all 60 replay (50 by the fallback, 10 by BMC).
3. Two runner-side defects, fixed before any result was used: a stale binary snapshot (dune
   outputs are read-only, so the snapshot could not be overwritten; snapshots are now versioned,
   `fbin_<epoch>`) and a taps side channel (`Lane_circuit.taps`) that leaked between two spec copies
   in one harness.
4. Earlier versions of `one_formal.sh` deleted their own scratch Verilog and AIGER under
   `formal/work/mut_v2/formal/`. Scratch now lives outside the repo; nothing in the repo is
   deleted by the campaign scripts.

## 6. Limits

- Sampling: 120 per unit gives about +-8 points at 95 % on mid-range kill rates.
- R1b bounded at 20 frames; the monitor's formal kill rate is a lower bound.
- SV and C3 scenario sets are small (coverage in 3.4); SR checks traffic only, never verdicts.
- Contract mutants were sampled from 5 of the 8 shipped packages; I2C contracts are not covered.
- lane_spec 1525 remains undecided.

## 7. Reproduce

```
dune build && formal/mutation/v2/snapshot.sh
formal/mutation/v2/run_sim.sh 9 300                                   # SIM, all mutants (about 2 h)
python3 formal/mutation/v2/sample.py                         # samples
SCRATCH=/tmp/mut formal/mutation/v2/run_matrix.sh 8 900       # full matrix (several hours)
python3 formal/mutation/v2/kill_matrix_v2.py                 # tables
python3 formal/mutation/v2/plot_kill_sets_v2.py log/kill_matrix_v2.csv log/kill_matrix_v2_contracts.csv log/kill_sets_v2.png
```
