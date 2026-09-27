# Proof log

## Run 2026-09-27 (first proofs, Yosys route)

Setup: code state = commit 9881f36 plus the formal/ changes in this commit. Yosys 0.69+post (9f75ca1f), ABC 1.01 bundled with that Yosys,
local machine (darwin, 11 CPUs, 18 GiB). Command: `formal/run_proofs.sh . 900`, total wall 28 s.
Contracts, assumptions and init rules: formal/README.md.

| harness | expected | engine | result | depth/frames | inputs/latches/ands | wall s | cex replay |
|---|---|---|---|---|---|---|---|
| a2_uart_d3 | PASS | pdr | PASS |  | i/o = 9/ 1 lat = 77 and = 883 | 2 |  |
| a2_uart_neg_d3 | FAIL | bmc3 | FAIL | 9 | i/o = 9/ 1 lat = 64 and = 781 | 0 | replay ok |
| a1_rom_d3 | PASS | pdr | PASS |  | i/o = 34/ 1 lat = 130 and = 1670 | 1 |  |
| b1_qed_d3 | PASS | pdr | PASS |  | i/o = 41/ 1 lat = 137 and = 1573 | 2 |  |
| b1_qed_neg_d3 | FAIL | bmc3 | FAIL | 14 | i/o = 41/ 1 lat = 137 and = 1575 | 0 | replay ok |
| a2_uart_d4 | PASS | pdr | PASS |  | i/o = 9/ 1 lat = 79 and = 931 | 4 |  |
| a2_uart_neg_d4 | FAIL | bmc3 | FAIL | 10 | i/o = 9/ 1 lat = 65 and = 815 | 0 | replay ok |
| a1_rom_d4 | PASS | pdr | PASS |  | i/o = 34/ 1 lat = 131 and = 1735 | 9 |  |
| b1_qed_d4 | PASS | pdr | PASS |  | i/o = 41/ 1 lat = 137 and = 1578 | 3 |  |
| b1_qed_neg_d4 | FAIL | bmc3 | FAIL | 17 | i/o = 41/ 1 lat = 137 and = 1579 | 0 | replay ok |
| a1_miter | PASS | dprove | PASS |  | i/o = 34/ 1 lat = 2202 and = 12720 | 6 |  |
| a1_miter_neg | FAIL | dprove | FAIL | 6 | i/o = 34/ 1 lat = 2202 and = 12670 | 0 | replay ok |

depth/frames = frame at which bad is asserted, i.e. counterexample length minus 1. "replay ok" = the
Hardcaml cyclesim replay raises bad first at exactly that frame.

Notes
- a1_miter under plain `pdr -T 1200`: UNDECIDED, timed out in frame 18 at 1200 s. dprove
  (BMC, then latch correspondence, fraiging, retiming, then K-step induction with K=2) closes it
  in about 6 s. dprove's transformations (retiming with initial-state computation, fraiging,
  scorr) are a larger trusted base than a single PDR run. Planned independent cross-check:
  the same AIGER in a second engine (sby k-induction via smtbmc, or a BTOR2 engine).
- a1_miter_neg (no SRAM write-through) counterexample: load word 0x1009 (OUT 0x09) at address 0,
  raise RUN; spec drives 0x09 at frame 6, mutant RTL 0x00.
- Earlier runs of this session with a wrong flow order (init set after opt) are superseded;
  see formal/README.md, "Flow bug".

Open items
- Instruction memory initial contents: zero and equal in spec and RTL; not arbitrary-equal.
- A2 does not claim data correctness or the exact 10d+3 frame period.
- a1_miter is proven for the behavioural SRAM; the IHP macro equivalence is separate (plan step 10).
