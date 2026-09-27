# formal

Owner context and read permissions: see ../isolation_rules.md (or ../../ for doc/ subdirectories).

Hardcaml observer harnesses with a single `bad` output, emitted to Verilog, converted by Yosys
to AIGER miters and checked with ABC `dprove` (every harness; user decision 2026-09-27).
On any failure, `bmc3` produces a shortest counterexample, which is replayed on the Hardcaml
harness in cyclesim (`bin/replay_cex.ml`): `bad` must first rise at exactly the last frame.
(PDR and dprove traces are valid, but they need not be first failures, so they are not
replayed directly.) Every solver call runs under a wall-clock limit (`tlimit.sh`), because
dprove's `-T` bounds only its final PDR stage.

```
source tools/env.sh
formal/run_proofs.sh [name-regex] [timeout-s]    # results: formal/work/results.md
formal/prove_one.sh <harness> <vdir> <workdir> <timeout-s> <expected>
formal/mutation/run_mutants.sh [timeout-s] [jobs] [nprog]   # resumable; then kill_matrix.py
```

Engine choice, measured on the positive harnesses before the switch (pdr / dprove, seconds):
a2 2.1-8.7 / 0.6-1.5; b1 1.2-2.7 / 0.1-0.3; a1_rom 1.2-9.3 / 7.3-9.3; a1_miter UNDECIDED at
1200 / 5.5. After its reductions, dprove closes most harnesses by interpolation, a1_rom_d3 by
BDD reachability, and a1_miter by 2-step induction over latch correspondence. The trusted
base is ABC's reduction pipeline plus whichever engine closes the proof.

## Harnesses (src/harness.ml)

| name | claim | environment assumptions |
|---|---|---|
| `a2_uart_d{3,4}` | spec running `Programs.uart_tx ~d` never violates the UART TX monitor (b = d), never trips its timeout, and completes a frame at least every 10d+5 cycles | RUN (ui_in[7]) = 1 and WSTB = 0 from reset; reset never re-asserted; uio_in arbitrary every cycle |
| `a1_rom_d{3,4}` | RTL (ROM SRAM model) and spec (ROM) have equal uo_out every cycle for that fixed program | rst_sync_n, ui_in, uio_in all arbitrary |
| `a1_miter` | RTL `pemu_core` (behavioural SRAM) and spec have equal uo_out/uio_out/uio_oe every cycle | rst_sync_n, ui_in, uio_in all arbitrary, so programs are arbitrary (loaded through the pins) |
| `b1_qed_d{3,4}` | timed QED on the RTL alone: P = `uart_tx` and T(P) = `uart_tx_unrolled` give identical uo_out | as A2 |
| `a2_rtl_uart_d{3,4}` | A2 on the RTL directly (ROM SRAM model): spec-free | as A2 |
| `b1_qed_spec_d{3,4}` | timed QED on the spec alone (ROM imem) | as A2 |
| `a1_miter_anyinit` | A1 with arbitrary initial instruction memory, required only on runs where spec and RTL memories start equal | as A1; experimental (TIMEOUT at 300 s; see xcheck/) |
| `*_neg*` | negative controls: must FAIL (bad-start program vs monitor; T'(P) with one WAIT one cycle short; `a1_miter_neg` = RTL with SRAM write-through removed) | as the positive twin |

What A2 does not claim yet: that the transmitted byte equals the sampled uio_in (data
correctness); that frames start exactly 10d+3 apart (only the upper bound 10d+5 is checked).

## Initial state and model-construction rules (run_proofs.sh)

1. Proofs start from reset. Every register is set to init 0 by `setundef -zero -init`
   immediately after `proc`, before any optimisation. All reset values in spec, RTL and
   monitors are 0, so this state is the reset state. Instruction memory words start at 0 in
   both spec and RTL: equal, but not arbitrary. That restriction is recorded as an open item.
2. The SRAM output registers (`rtl_imem_dout*`) and any register named `free_*` have init
   removed and are free at frame 0 (silicon powers up with X in A_DOUT). `write_aiger -zinit`
   turns them into extra inputs, 16 per SRAM instance. Guard: the run fails unless the AIGER
   map has exactly 16 free init bits per SRAM output register.
   SRAM register names must be unique per harness (guard: DUPLICATE-SRAM-NAME). The Verilog
   backend and cyclesim number duplicate names in different orders, and the replayer maps
   initial values by name; this caused a real replay mismatch on the two-instance B1 harness.
3. All `opt` passes run with `-keepdc`, so Yosys never exploits a free initial value.
4. The final `setundef -zero` replaces only x constants that Yosys itself introduces as
   don't-cares. The Hardcaml Verilog is checked for x literals before conversion.
5. Undriven-bit guard (`undriven_guard.py`): the AIGER backend reports the used bits of
   top-level input ports (ui_in[6], ui_in[7]) as "undriven, treated like $anyseq". That is
   harmless: each is still exactly one AIGER input (checked in the map). Any other undriven
   bit fails the run.

## Mutation engine (src/mutate.ml, bin/mutants.ml, mutation/)

Mutants are made on the Hardcaml signal graph, with no source edits. The design (RTL engine, or
spec) is elaborated on formal input wires, with its memory model stubbed out. The graph from
the outputs and memory inputs back to the formal inputs is copied node by node, with fresh uids
and names kept, and exactly one node changed. The memory model (RTL SRAM, spec imem) is then
built outside the mutation scope. Operators: op_swap, const_invert, off_by_one, clear_drop,
mux_swap. (enable_drop is implemented but has no sites: the only enabled registers are inside
the excluded memory models.) Sites: 216 RTL, 230 spec. Validation: the identity copy (site
`id`) reproduces the unmutated AIG sizes and results exactly for every oracle harness.
Oracles per mutant: SIM (random differential co-simulation against the unmutated partner
model, 40 programs, ~67k cycles), A1, A2 (UART monitor, d=3), B1 (timed QED, d=3). A1 = PASS
on a mutant means it is proven pin-equivalent from reset (an equivalent mutant).

Flow bug found while building this (recorded for the method section). The first version ran
`prep` (which includes opt) before `setundef -init`, so optimisation saw undefined initial
values. With undefined init, `opt_dff` is allowed to fold, for example, a flop with constant D
(such as the RUN synchroniser with RUN tied high) into that constant. That is a legal
refinement of X-init, but not of reset-init. The init unset also missed the SRAM output
register, because it carried two names. Negative-control depths under the old flow were
a2_neg_d3 = 30, a2_neg_d4 = 39 and b1_neg_d4 = 1; under the fixed flow they are 9, 10 and 17,
and all three replay exactly in cyclesim. The old frame-1 B1 counterexample cannot be real:
both instances drive uo_out = 0x00 until their first OUT, which is at cycle 2 or later. The
old counterexamples were not replayed, since the replay tool came later, so which mechanism
produced each old depth was not isolated. Replaying every counterexample in cyclesim is the
guard against this class of error.
