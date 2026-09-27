# formal

Owner context and read permissions: see ../isolation_rules.md (or ../../ for doc/ subdirectories).

Hardcaml observer harnesses with a single `bad` output, emitted to Verilog, converted by Yosys
to AIGER miters and checked with ABC (`pdr` for claims, `bmc3` for negative controls). Every
counterexample is replayed on the Hardcaml harness in cyclesim (`bin/replay_cex.ml`); the run
fails if `bad` does not first rise at exactly the frame ABC reports.

```
source tools/env.sh
formal/run_proofs.sh [name-regex] [timeout-s]    # results: formal/work/results.md
```

## Harnesses (src/harness.ml)

| name | claim | environment assumptions |
|---|---|---|
| `a2_uart_d{3,4}` | spec running `Programs.uart_tx ~d` never violates the UART TX monitor (b = d), never trips its timeout, and completes a frame at least every 10d+5 cycles | RUN (ui_in[7]) = 1 and WSTB = 0 from reset; reset never re-asserted; uio_in arbitrary every cycle |
| `a1_rom_d{3,4}` | RTL (ROM SRAM model) and spec (ROM) have equal uo_out every cycle for that fixed program | rst_sync_n, ui_in, uio_in all arbitrary |
| `a1_miter` | RTL `pemu_core` (behavioural SRAM) and spec have equal uo_out/uio_out/uio_oe every cycle | rst_sync_n, ui_in, uio_in all arbitrary, so programs are arbitrary (loaded through the pins) |
| `b1_qed_d{3,4}` | timed QED on the RTL alone: P = `uart_tx` and T(P) = `uart_tx_unrolled` give identical uo_out | as A2 |
| `*_neg*` | negative controls: must FAIL (bad-start program vs monitor; T'(P) with one WAIT one cycle short; `a1_miter_neg` = RTL with SRAM write-through removed) | as the positive twin |

What A2 does not claim yet: that the transmitted byte equals the sampled uio_in (data
correctness); that frames start exactly 10d+3 apart (only the upper bound 10d+5 is checked).

## Initial state and model-construction rules (run_proofs.sh)

1. Proofs start from reset. Every register is set to init 0 by `setundef -zero -init`
   immediately after `proc`, before any optimisation. All reset values in spec, RTL and
   monitors are 0, so this state is the reset state. Instruction memory words start at 0 in
   both spec and RTL: equal, but not arbitrary. That restriction is recorded as an open item.
2. The SRAM output registers (`rtl_imem_dout*`) have init removed and are free at frame 0
   (silicon powers up with X in A_DOUT). `write_aiger -zinit` turns them into extra
   inputs, 16 per SRAM instance; this is visible in the input counts.
3. All `opt` passes run with `-keepdc`, so Yosys never exploits a free initial value.
4. The final `setundef -zero` replaces only x constants that Yosys itself introduces as
   don't-cares. The Hardcaml Verilog is checked for x literals before conversion.

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
