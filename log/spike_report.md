# Feasibility spike: assume-guarantee monitors on the v0.1 core (2026-10-17)

Plan step 2. Concept: `doc/concept/assume_guarantee.md`; language: `doc/contracts/language_v0.md`.
Legend as in `log/slice_report.md`: **fact** = produced by a run whose command is in the repo; **estimate** = judgement.

## 1. What was built

| file | content |
|---|---|
| `contracts/src/contract.ml` | the contract language as an OCaml embedded DSL (Q1): observables, edge predicates, await/hold/skip/raise/loop/repeat, fail/blame roles, WF1-WF3 validation, text printer |
| `contracts/src/program.ml` | compiler to flat monitor programs: zero-time statements folded into on-complete actions (one instruction per watcher per cycle), predicates normalised to at most 2 literals |
| `contracts/src/interp.ml` | reference semantics interpreted directly on the DSL tree (independent of the compiler) |
| `contracts/src/mon_circuit.ml` | front end (own 2-flop synchronisers, previous-cycle values), verdict block (sticky flags, first causes), and S1-mon as a circuit: the compiled program elaborated as a hardwired FSM |
| `contracts/src/engine.ml` | programmable monitor engine: generic datapath executing encoded instructions from a ROM (proofs) or loadable registers (area estimate) |
| `contracts/src/library.ml` | the spike contract `uart_tx_v01` (exact UART form from `doc/protocols/uart.md`, a progress bound, one assumption: RUN never drops after rising) and its control variants |
| `formal/src/ag_harness.ml`, `formal/src/registry.ml` | U, N1, A1-mon and end-to-end harnesses in the existing flow (`formal/prove_one.sh`: Yosys to AIGER, ABC dprove, bmc3 counterexample and cyclesim replay) |
| `contracts/test/*` | expect tests: text view, role rules, directed runs, three-way differential, waveform |

Not built in the spike: streams and data checks, registers, mark/elapsed, the generic A1-mon (engine equal to an interpreter circuit for every program), the program-load path for monitors.

## 2. Results (facts)

### 2.1 Tests (`dune runtest contracts`)

- Three-way differential (DSL interpreter vs hardwired circuit vs ROM engine): 0 mismatches over 6 runs of 20,000 random cycles each. Stimulus: random RUN drops, resets, `uio_in`, and either the spec core's TX or a random TX. The runs contained 98-148 fail events and 54-175 blame events each, so every check kind was exercised.
- Directed (spec core, d = 4):

  | scenario | events |
  |---|---|
  | RUN held high, 1,500 cycles | none |
  | RUN dropped at cycle 103 | blame 0x81 at 105, fail 0x13 at 106 |
  | same, contract without the assumption | fail 0x13 at 106 with no blame |
  | contract for d = 3 against the d = 4 program | fail 0x13 at 17 |

- Role rules: a `fail` check on an input and a `blame` check on a chip output are both rejected.
- Waveform (`contracts/test/test_waveform.ml`) of the RUN-drop window: RUN falls at 103, `blame` latches at 105 (two-cycle synchroniser), the first wrong TX cycle and `fail` at 106.

### 2.2 Proofs (ABC dprove; every FAIL replayed in cyclesim at the reported frame)

| harness | claim | expected | result | depth | latches | wall s |
|---|---|---|---|---|---|---|
| u_spec_uart_d3 | U on the spec, environment free | PASS | PASS | | 79 | 43 |
| u_spec_uart_d4 | | PASS | PASS | | 81 | 12 |
| n1_spec_uart_d3 | N1: under R_P no blame, no fail (incl. progress bound) | PASS | PASS | | 80 | 29 |
| n1_spec_uart_d4 | | PASS | PASS | | 82 | 8 |
| a1mon_uart_d3 | hardwired monitor == ROM engine, all monitor inputs free | PASS | PASS | | 87 | 1 |
| a1mon_uart_d4 | | PASS | PASS | | 91 | 1 |
| a1mon_uart_variant_d4 | same, contract with 4 watchers incl. a 1-instruction watcher | PASS | PASS | | 110 | 0 |
| u_rtl_uart_d3 | U end to end: RTL core (SRAM fetch) + engine | PASS | PASS | | 107 | 26 |
| u_rtl_uart_d4 | | PASS | PASS | | 109 | 51 |
| u_spec_uart_delay1_d4 | blame delayed 1 cycle | PASS | PASS | | 88 | 34 |
| u_spec_uart_delay2_neg_d4 | blame delayed 2 cycles | FAIL | FAIL | 11 | 88 | 0 |
| u_spec_uart_noassume_neg_d4 | no assumption watcher | FAIL | FAIL | 5 | 78 | 0 |
| u_spec_uart_badprog_neg_d4 | known-bad program (start bit d+1) | FAIL | FAIL | 10 | 81 | 0 |
| n1_spec_uart_overstrong_neg_d4 | assumption that blames any uio_in[0] change | FAIL | FAIL | 2 | 84 | 1 |
| a1mon_window_neg_d4 | engine with windows one cycle too long | FAIL | FAIL | 4 | 91 | 0 |
| a1mon_code_neg_d4 | engine reporting a wrong cause code | FAIL | FAIL | 3 | 91 | 0 |

Readings:
- **Margin.** delay 1 passes and delay 2 fails for all input sequences. The assumption monitor therefore has exactly one cycle of slack before the earliest possible wrong TX cycle. This is the synchroniser alignment the language's time-conversion rule must preserve.
- **The assumption is necessary.** Without it, U fails at frame 5.
- **N1 has teeth.** An over-strong assumption is caught at frame 2.
- **A negative control was vacuous at first, and the discipline caught it.** The first version of `a1mon_window_neg_d4` passed. The planted bug sat in watcher 0 (`host_run`), which has no bounded window, so the comparator was optimised away (identical latch count). With the bug planted in every unit, the control fails at frame 4. The fix and its reason are recorded in `contracts/src/engine.ml`.

### 2.3 Scaling of U with window length

| d (bit period) | max window (cycles) | u_spec wall s | u_rtl wall s |
|---|---|---|---|
| 3 | 29 | 43 | 26 |
| 4 | 39 | 12 | 51 |
| 6 | 59 | 6 | 38 |
| 8 | 79 | 315 | 373 |
| 12 | 119 | 533 | not run |
| 16 | 159 | 1,001 | not run |

From d = 8 to d = 16 the window doubles and U on the spec takes 3.2x longer (315 s to 1,001 s); latches grow only from 83 to 85. Below d = 8 the times are not monotonic (dprove's heuristics vary). Extrapolation to a 115,200-baud UART at 50 MHz (d = 434, window 4,339) is an estimate only: about 7.5 h at linear growth, far more if growth is superlinear, per package and per proof run. Not usable as is.

### 2.4 Area (Yosys mapping to SG13CMOS5L typ liberty, as `flow/map/map_cmos5l.sh`; no placement)

| circuit | area um^2 | flops | share of 6x4 core (902,417 um^2) |
|---|---|---|---|
| hardwired monitor, uart_tx_v01 (3 watchers) | 5,225 | 65 | 0.58% |
| ROM engine, same program | 5,191 | 67 | 0.58% |
| loadable engine, 2 units x 16 slots, 81-bit instructions | 211,847 | 2,719 | 23% |
| loadable engine, 4 x 16 | 418,377 | 5,345 | 46% |
| loadable engine, 4 x 32 | 825,749 | 10,661 | 92% |
| loadable engine, 8 x 16 | 828,164 | 10,597 | 92% |
| loadable engine, 4 x 16, 16-bit windows | 457,412 | 5,873 | 51% |

Derived: one loadable instruction slot costs about 6,365 um^2 (4 x 32 minus 4 x 16, over 64 slots), about 78.6 um^2 per stored bit. The engine logic per unit, without its slots, is about 4.7k um^2.

## 3. Findings

1. **The theorem form works on a real core.**
   - U and N1 prove in seconds to tens of seconds at small bit periods, on both the spec and the RTL.
   - A1-mon as translation validation (engine on the compiled program equal to the hardwired elaboration) proves in about 1 s.
   - The composition and the direct end-to-end proof agree.
2. **Window length is the scaling risk (most important).** Proof time jumps between d = 6 and d = 8. Real protocols have windows of hundreds to thousands of cycles: a UART bit at 115,200 baud and 50 MHz is 434 cycles, and I2C Sm tLOW is 235 cycles. Bit-level model checking with explicit cycle counters will not reach these by brute force [estimate]. Options, for the architecture gate:
   - **(a) Timebase prescaler in the architecture.** Driver timing and monitor windows count programmable ticks, not cycles, so contracts keep small constants. A one-off divider lemma (the prescaler produces exact tick spacing) is proved separately. This turns a verification limit into an architecture feature.
   - **(b) Scale-invariance argument.** Prove at small d and show by a separate abstraction proof that behaviour depends only on counters reaching thresholds. Research risk; soundness needs care.
   - **(c) Strengthened invariants** relating the program's WAIT counter to the monitor's window counter, for k-induction or IC3. Per-package manual work; could be machine-assisted, with every invariant checked.
   - **(d) More compute.** Unlikely to help if growth is exponential in counter width [estimate].
3. **A programmable monitor store in flops is infeasible.** About 6.4k um^2 per instruction slot; the UART contract alone needs 27 slots. Options:
   - (a) hardwired monitors per protocol at tape-out (about 5k um^2 each), giving up on-chip checking for post-tape-out packages;
   - (b) a compressed encoding (window constants and codes via small tables, contract-local observable indices; roughly 45-50 bits per instruction [estimate]);
   - (c) a latch-based store (roughly half the flop area [estimate, unmeasured]; equivalence and timing of latches are harder);
   - (d) an SRAM-backed store with per-watcher instruction caching. One read per cycle conflicts with several watchers completing in the same cycle; that needs dual-port SRAM or a compiler restriction;
   - (e) a less expressive but parameterised block: window-check units configured by registers.
4. **WF1/WF2 as implemented are stricter than the language document.** A `fail` hold may not mention an input even as a condition. Language v1 should separate conditions from requirements syntactically, for example `hold (cond => req)`.
5. **A1-mon is per contract (translation validation), not generic.** That is sufficient for the per-package theorem. A generic proof (engine equal to an interpreter circuit for all programs) is still open; it matters only if monitor programs are loaded at run time.

## 4. Go/no-go for the concept (status; the decision is yours)

| criterion | status |
|---|---|
| unconditional theorem U proves on spec and RTL for a real program | met (UART TX; spec up to d = 16, RTL up to d = 8) |
| non-vacuity N1 proves, with a negative control | met |
| on-chip monitor proved equal to the proof monitor | met per contract (translation validation); generic not established |
| blame-before-fail timing understood | met: exactly 1 cycle of margin, formally |
| U scales to realistic windows | **not met**: needs one of 3.2 (a)-(c) |
| programmable monitor fits the area budget | **not met** with flop storage; needs one of 3.3 (a)-(e) |
| data checks, streams, I2C contracts in code | not attempted in the spike |

## 5. Fallback tiers (updated)

- **Full:** programmable monitors (one of 3.3 (b)-(e)), U at real windows via a prescaler or invariants, U and N1 per package lifted to the netlist.
- **Reduced:** hardwired assumption monitors for the shipped protocols (about 5k um^2 each), U at real windows, post-tape-out packages proved with their assumptions stated rather than monitored.
- **Minimum:** U and N1 at small windows only, plus a scaling argument stated as unproved.

## 6. Addendum: tick spike for decision G1 (plan step 3, same day)

Change: optional `tick` enable added to `Spec_circuit.create`. It gates the execution state (pc, out, sr, lc, wait); synchronisers and the load path still run every cycle. The same enable is added to the monitor (watcher state, edge history, firing) and the engine. A `Prescaler` (`contracts/src/prescaler.ml`) samples its divisor p during reset and ticks every p+1 cycles. With no tick given, every circuit is unchanged.

| harness | claim | expected | result | depth | latches | wall s |
|---|---|---|---|---|---|---|
| presc_lemma | consecutive ticks exactly p+1 cycles apart, every 8-bit p | PASS | PASS | | 26 | 0 |
| presc_lemma_neg | planted: divisor 37 never ticks | FAIL | FAIL | 39 | 26 | 6 |
| u_spec_tick_d4 | U with the tick input completely free | PASS | PASS | | 81 | 29 |
| n1_spec_tick_d4 | N1 with the tick free | PASS | PASS | | 82 | 8 |
| u_spec_tick_noassume_neg_d4 | no assumption | FAIL | FAIL | 5 | 78 | 0 |
| u_spec_presc_d4 | U with the real prescaler, divisor free | PASS | PASS | | 97 | 27 |
| u_spec_uart_d4, a1mon_uart_d4, a1_miter | regression with tick absent | PASS | PASS | | 81 / 91 / 2202 | 21 / 1 / 14 |

Readings:
- **U holds for every tick pattern**, so it holds for the prescaler's ticks; the prescaler lemma gives exact real time (bit = d x (p+1) cycles). One proof (`u_spec_presc_d4`, 27 s) covers bit periods 4 to 1,024 cycles in steps of 4. The explicit-cycle proof at d = 16 alone took 1,001 s. **G1's condition is met.**
- **Regression is clean.** Latch and AND counts of the existing harnesses are identical to before.
- **Constraints this introduces (for ISA v1):**
  - bit periods are d x (p+1), so a 115,200-baud UART at 50 MHz (434 cycles) needs d = 7, p = 61 (or d = 14, p = 30), and one proof per d [arithmetic];
  - other rates need a fractional prescaler, whose lemma is a separate obligation;
  - a lane on a slow tick reacts in ticks, not cycles, so fast-reacting protocols run with p = 0, where windows are short anyway;
  - lane and monitor sample inputs only on ticks. Sub-tick input pulses are invisible to both, which keeps the theorem consistent but is a stated behaviour.
- **Not done:** interpreter (Interp) support for ticks and differential tests in tick mode; tick-mode A1 (RTL with tick against spec with tick).
