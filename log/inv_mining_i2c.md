# I2C A2: invariant mining + k-induction (plan step 7, user decision 2026-10-19)

Status 2026-10-19: tooling built and validated; no unbounded U proof. User decision (same day):
stop here, keep the tooling, keep the controller U result bounded (bmc3, 77/76 frames), run the
target A2 with the existing engines and move on to USB-LS TX. All numbers below are measured on
the local machine (11 CPUs) unless marked as estimates.

## Flow

1. `formal/bin/inv_traces.exe <harness> <out> <traces> <cycles> <seed>`: drives the debug build
   of an I2C harness in cyclesim with the Psim peers (`Peers.i2c_target` for controller
   harnesses, `Peers.i2c_controller` for target harnesses). Peer timing, tick pattern (prescaler,
   jitter, random), host bytes, reset/run drops and pad glitches are randomised. The tool records
   the harness inputs and `bad` for every cycle. `INV_VERBOSE=1` prints the first blame of each
   trace.
2. `formal/inv/aig.py`: AIGER reader plus a generated C simulator (64 traces per machine word). It
   replays the recorded inputs on the exact AIG that is proved, deduplicates the guarded states
   (`h_blame_seen = h_env_bad = 0`) and counts cycles where the AIG output differs from the
   recorded `bad`.
3. `formal/inv/houdini.py`: candidate templates T1-T6 over the guarded states (constant bits,
   bit equalities, register domains, key -> set / upper / lower bound, key -> counter
   relation a +- b = c, key -> bit constant / bit equality; keys are the lane pc, the unit pcs and
   their pairs). Every lemma is guarded: G -> c. Filtering is a base-case BMC from the zero initial
   state, followed by Houdini with k-induction on an incremental CaDiCaL unrolling. There are
   three modes: property assumed and checked, property assumed only, and no property.
4. `formal/inv/strengthen.py`: writes bad' = bad | OR_j (G & ~c_j), and `check_extension`
   re-reads both files. It checks that the inputs, latches, next-state functions and original
   AND gates are unchanged and that the original bad is a disjunct of bad'. Then "bad' never
   fires" implies "bad never fires" for any lemma set; the miner is never trusted.

## Measured

| item | value |
|---|---|
| AIG simulator vs Hardcaml `bad` (a2_i2c_ctl_fm_h2_neg, 64 x 20,000 cycles) | 83 bad cycles in both, 0 mismatches |
| controller Fm traces | 256 x 60,000 cycles, 0 `bad`; 94 % guarded; 2,290,673 distinct guarded states; all 173 lane pcs |
| target Fm traces (after two generator fixes, see below) | 512 x 15,000 cycles, 0 `bad`; 28 % guarded; 448,895 distinct states |
| controller candidates T1-T5 | 15,755; Houdini k=1: property CTI after 4 s |
| + T6 (keyed bit relations) | 48,427; k=1: CTI (lane_pc 33 / mon_u0_pc 3); k=3: CTI, 18 s |
| + lower bounds and joint keys | 109,667; base 109,598; k=3 (property assumed and checked): CTI with 100,479 alive, 710 s |
| strengthened model from that set | 8,757 original ANDs kept, 307,836 appended, extension check ok; bmc3 reaches bad' at frame 8 (a mined lemma is false at depth 8; the set had not converged) |
| k=3, property assumed only, FIFO-data lemmas pruned | start 91,728 (base depth 12); stopped at the 1 h limit after 11,204 iterations with about 71,100 alive (71,098 at iteration 11,181) and still eroding at about 290 lemmas/min (79,908 at 1,391 s, 71,098 at 3,218 s); not converged |

Not yet run on the current tooling: target Houdini, rIC3 or ABC on any strengthened model.

## Findings

- Mined correspondences needed: the monitor's 16-bit register equals {header byte, lane r4} at
  lane pc 112 / unit 2 pc 65 (keyed bit equalities, T6); per-pc lower bounds on unit step
  counters (a lane at pc 22 has executed at least about 21 steps since the monitor restarted).
- Houdini must not stop at the first property CTI. The alive set at that point is not
  inductive, and the bmc3 result above shows it.
- The erosion in the last run is a cascade: 162 of 451 lane-pc -> unit-pc correspondence lemmas
  died, the first at iteration 212. The first such CTI is a legal one-cycle SCL glitch between
  ticks (seen by neither lane nor monitor), followed by a unit-1 branch at lane pc 143 that the
  traces never showed. The trace data cannot tell whether that lemma is false (a coverage gap)
  or a missing template.
- Trace generator fixes: (1) the target harness assumes the config byte is in the TX FIFO at
  start, but only a third of the traces pushed it at cycle 1, so the other two thirds hit
  `h_env_bad` at once; (2) pad glitches were enabled in 3 of 4 traces and ended most traces early.
  After both fixes the target guarded fraction rose from 9.7 % to 28 %.
- Performance: each Houdini iteration costs about 0.25 s at about 90k lemmas, dominated by full
  model extraction (pysat `get_model` over millions of Tseitin variables, observed in an
  interrupted traceback).
