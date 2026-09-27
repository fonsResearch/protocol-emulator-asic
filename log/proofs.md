# Proof log

## Run 2026-09-27 (flow v2: dprove everywhere)

Setup: commit ba4f4f1. Yosys 0.69+post (9f75ca1f) with its bundled ABC 1.01, on the local
machine (darwin, 11 CPUs, 18 GiB). Command: `formal/run_proofs.sh . 300`. Contracts,
assumptions and model-construction rules: formal/README.md.
Flow v2 relative to the first run (superseded, below):
- dprove for every harness;
- BMC-shortest counterexamples for replay;
- wall-clock limits on every solver call;
- `proc -norom` (no inferred ROMs);
- keep on free-init registers;
- guards for free init bits, duplicate SRAM names and undriven bits.

| harness | expected | engine | result | depth | inputs/latches/ands | wall s | cex replay |
|---|---|---|---|---|---|---|---|
| a2_uart_d3 | PASS | dprove | PASS |  | i/o = 9/ 1 lat = 77 and = 896 | 1 |  |
| a2_uart_neg_d3 | FAIL | dprove | FAIL | 9 | i/o = 9/ 1 lat = 64 and = 801 | 0 | replay ok |
| a2_rtl_uart_d3 | PASS | dprove | PASS |  | i/o = 25/ 1 lat = 94 and = 874 | 1 |  |
| a1_rom_d3 | PASS | dprove | PASS |  | i/o = 34/ 1 lat = 130 and = 1697 | 7 |  |
| b1_qed_d3 | PASS | dprove | PASS |  | i/o = 41/ 1 lat = 137 and = 1638 | 1 |  |
| b1_qed_spec_d3 | PASS | dprove | PASS |  | i/o = 9/ 1 lat = 99 and = 1551 | 0 |  |
| b1_qed_neg_d3 | FAIL | dprove | FAIL | 14 | i/o = 41/ 1 lat = 137 and = 1639 | 0 | replay ok |
| a2_uart_d4 | PASS | dprove | PASS |  | i/o = 9/ 1 lat = 79 and = 942 | 2 |  |
| a2_uart_neg_d4 | FAIL | dprove | FAIL | 10 | i/o = 9/ 1 lat = 65 and = 834 | 0 | replay ok |
| a2_rtl_uart_d4 | PASS | dprove | PASS |  | i/o = 25/ 1 lat = 96 and = 899 | 2 |  |
| a1_rom_d4 | PASS | dprove | PASS |  | i/o = 34/ 1 lat = 131 and = 1761 | 9 |  |
| b1_qed_d4 | PASS | dprove | PASS |  | i/o = 41/ 1 lat = 137 and = 1641 | 1 |  |
| b1_qed_spec_d4 | PASS | dprove | PASS |  | i/o = 9/ 1 lat = 101 and = 1661 | 0 |  |
| b1_qed_neg_d4 | FAIL | dprove | FAIL | 17 | i/o = 41/ 1 lat = 137 and = 1644 | 0 | replay ok |
| a1_miter | PASS | dprove | PASS |  | i/o = 34/ 1 lat = 2202 and = 12720 | 5 |  |
| a1_miter_neg | FAIL | dprove | FAIL | 6 | i/o = 34/ 1 lat = 2202 and = 12670 | 0 | replay ok |
| a1_miter_anyinit | PASS | dprove | TIMEOUT |  | i/o = 2082/ 1 lat = 2204 and = 22963 | 300 |  |

depth = frame of the shortest (bmc3) counterexample. "replay ok" = in Hardcaml cyclesim,
bad first rises at exactly that frame.

## Experiments on the open A1 caveats (2026-09-27)

| experiment | result | notes |
|---|---|---|
| a1_miter with ABC pdr alone | UNDECIDED, 1200 s, frame 18 | dprove proves it in about 6 s |
| a1_miter with sby smtbmc k-induction (z3), depth 20 | not converged after about 14 min CPU; stopped by user decision | run without a wall-clock limit (before tlimit.sh); to be rerun under a limit |
| a1_miter_anyinit (two free memories plus an equal-at-frame-0 condition) | TIMEOUT 600 s and 300 s | latch correspondence finds no pairs: they are equal only conditionally |
| a1_miter_anyinit, merged init inputs (formal/xcheck/run_anyinit_merged.sh) | TIMEOUT 1200 s | correspondence reduces 3444 latches to 1163 (as zero-init A1), but K=2 does not close |
| engine timing, pdr vs dprove on positive harnesses | dprove 2-10x faster except a1_rom_d3 (9.3 vs 1.2 s) | see formal/README.md |

Untested route for arbitrary-equal initial memory: a reachability decomposition. Every equal
memory image M can be loaded over the pins, and a reset then leaves (M, reset state) in both
models. The zero-init A1 proof then covers it, given two lemmas: memory equality is invariant,
and the load sequence writes any M.

## Superseded: first run 2026-09-27 (flow v1)

pdr for claims, bmc3 for negatives, dprove for A1 only. Results agreed with v2 on every harness
(PASS/FAIL and negative-control depths 9, 10, 14, 17, 6). AIG sizes differ slightly because of
proc_rom. Tool-flow defects found and fixed since then are listed in formal/README.md.
