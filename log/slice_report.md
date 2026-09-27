# Slice report: thin end-to-end verification slice (2026-09-27)

Scope of the slice: ISA v0.1 core (64-word SRAM-shaped instruction memory), one protocol
(UART 8N1 TX, bit period d = 3 and 4), one program plus its unrolled twin, and the Yosys/ABC
formal route. Everything is local (darwin, 11 CPUs, 18 GiB). Flow commit for all results
below: ba4f4f1 (formal), with later commits changing only logs and figures (b74ce5e, 56ad70f,
a3a3cc6).

Legend: **fact** = produced by a run whose log is in the repo; **estimate** = my judgement.

## 1. Established (facts)

| # | claim | method | assumptions | runtime |
|---|---|---|---|---|
| A2 | spec running uart_tx never violates the UART monitor, never times out, and completes a frame at least every 10d+5 cycles (d=3,4) | dprove | RUN high and WSTB low from reset; reset not re-asserted; uio_in arbitrary | 0-2 s |
| A2-RTL | same claim, on the RTL (ROM SRAM model) | dprove | as A2 | 1 s |
| A1 | RTL `pemu_core` equals spec on all pins every cycle, for arbitrary rst/ui/uio sequences (so any program loaded over the pins, any RUN toggling) | dprove (2-step induction over latch correspondence) | from reset; both instruction memories start at 0; SRAM output register free | 5-10 s |
| A1-ROM | same, for the fixed uart_tx program | dprove | from reset | 8-9 s |
| B1 | timed QED: P and its unrolled T(P) give identical uo_out, on the RTL alone and on the spec alone | dprove | as A2 | 0-1 s |
| E1 | behavioural SRAM model == unmodified IHP RM_IHPSG13_1P_64x16_c2 functional model inside the core | dprove | from reset; memories 0; both output registers free, independent | 5 s |
| E2 | RTL == Yosys generic `synth` netlist | dprove | from reset | 3 s |
| E3 | generic netlist replays 2715 spec-derived cycles | Icarus | vectors from the spec | 0 errors |
| sim | RTL vs spec interpreter, 300 random programs, >475k cycles; spec interpreter vs spec circuit, 200 programs | cyclesim | random stimulus | 0 mismatches |

Every positive claim has a negative control that fails as required. Every counterexample is
re-found as a shortest BMC trace and replayed in Hardcaml cyclesim, where `bad` must first rise
at exactly that frame. Details: log/proofs.md, formal/README.md, flow/equiv/README.md.

## 2. Oracle independence (facts): log/kill_matrix.md, log/kill_sets.png

446 graph-level mutants (216 RTL, 230 spec), 5 active operators, 4 oracles, 0 error cells:

| | RTL | spec |
|---|---|---|
| proven pin-equivalent (A1 = PASS) | 47 | 40 |
| killed by SIM / A1 / A2 / B1 | 133 / 134 / 55 / 38 | 153 / 158 / 79 / 48 |
| killed by a spec-free oracle (A2 or B1) | 59 of 169 | 81 of 190 |
| killed only by spec-based oracles | 91 | 94 |
| killed only by spec-free oracles (A1 undecided on all of them) | 9 | 15 |
| unresolved (no kill, A1 undecided) | 19 | 15 |

Reading (estimate, with the fact it rests on). The spec-free oracles are not stronger than A1
in principle: A1 covers every program. They are stronger in reach, because they start with the
program in ROM, while A1 must first load it through the pins. On spec mutants they give
something A1 cannot: evidence that the spec itself is wrong, not just that spec and RTL
disagree.

Unresolved class (fact): all 34 are reset-value mutants. Follow-up at 900 s: 2 proven
equivalent, 12 timeout, 20 not run (stopped; resumable).

## 3. Defects found by the verification (facts)

- **Design and model:** D1 (log/disagreements.md). The formal-only ROM variants disagreed on
  load-write visibility.
- **Tool flow**, where the checked model silently differed from the design. All were caught by
  guards or by cyclesim replay; details in formal/README.md.
  - initial values set after optimisation;
  - init attribute on an alias net (twice);
  - duplicate SRAM names swapping initial values in replay;
  - PDR traces treated as first failures;
  - dprove `-T` not bounding its run;
  - `proc_rom` with kept registers leaving a wire undriven;
  - CEC results unparsed, so constant-folded miters were misread;
  - a never-enabled free register deleted by Yosys.

## 4. Not established

- A1 for arbitrary (equal) initial memory: TIMEOUT at 300, 600 and 1200 s, including the
  merged-input model.
- A second, independent engine for A1: sby/smtbmc k-induction did not converge in about
  14 min and was stopped.
- Data correctness of the UART stream (A2 checks framing and timing only), and the exact
  frame period.
- Anything on the real SG13CMOS5L netlist, the TT wrapper (no core instantiated yet), the
  pads, or timing.
- Agent-independence protocol (E): deferred by decision.

## 5. Open decisions (options; not chosen)

1. **A1 cross-check engine.**
   - (a) Rerun sby k-induction under a limit, probably with hand-written strengthening
     invariants. Tools installed; the invariants are manual work.
   - (b) rIC3 (AIGER IC3 checker). Needs crates.io on the allowlist; rust 1.98 is on
     conda-forge.
   - (c) Pono or another BTOR2 engine built from source. Most independent, largest build cost.
   - (d) Defer; report dprove as the only engine.
2. **Arbitrary initial memory.**
   - (a) Reachability decomposition: load M, pulse reset, apply the zero-init A1. Needs two
     small lemmas: memory equality is invariant, and the load sequence writes any M.
   - (b) More compute (remote host). Timeouts so far give no size estimate.
   - (c) Keep the zero-init claim and state it.
3. **A2 data correctness.**
   - (a) Harness captures uio_in at a program-defined offset before the start bit and compares
     it with the monitor's frame_data. Program-specific.
   - (b) Check against the spec's sampled value. Spec-based, not spec-free.
   - (c) Leave A2 as framing/timing only.
4. **Unresolved reset-value mutants.**
   - (a) Finish the follow-up locally: about 50 min, 6 cores.
   - (b) Prove a halted-state re-initialisation lemma, which would make the class provably
     equivalent.
   - (c) Report them as unresolved.
5. **Which core goes into the TT wrapper.**
   - (a) Behavioural flop memory: 1024 extra flops; area to be measured.
   - (b) IHP macro: E1 proven; macro integration in the TT IHP flow is unverified here.
   - Either choice needs a CI run on GitHub, and that needs a push from you.
6. **Halt output 0x00 is a UART break** (the monitor times out during halt/load); this is the
   known v0 issue. Options as in doc/isa/isa_v0.md (v1 plan: pins on uio with oe = 0 while
   halted).
7. **COMBDLY lint** (Hardcaml emits `always @*` with `<=`): accept, post-process, or change
   the emission style.

## 6. Go/no-go criteria for thickening (status only; the decision is yours)

| criterion | status |
|---|---|
| end-to-end route Hardcaml -> Verilog -> AIGER -> proof works, with counterexample replay | met |
| A (pin theorem) proven for one protocol program | met, for framing/timing, from reset, zero initial memory |
| B (independent oracles) measured on a mutant set | met: 446 mutants, kill matrix |
| verification runtime fits local compute | met: base suite ~30 s (excluding the anyinit experiment); campaign ~23 min |
| flow equivalence to a synthesised netlist | met for the generic netlist; not for SG13CMOS5L |
| silicon path (C) exercised | not started: wrapper, CI, pads |
