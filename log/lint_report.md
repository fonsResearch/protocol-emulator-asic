# Lint report: tt_um wrapper + flop-memory core, LibreLane-equivalent (2026-10-16)

## What LibreLane 3.1.0.dev3 does (fact; read from the PyPI sdist, librelane/steps/verilator.py and checker.py)

- `verilator --lint-only --Wall --Wno-fatal --top-module <DESIGN_NAME> _deps.vlt +define+SCL_sg13cmos5l_stdcell
  +define+__librelane__ +define+__pnr__ +define+PAD_sg13cmos5l_io +define+USE_POWER_PINS <files>`.
  `LINTER_DISABLE_WARNINGS` defaults to DECLFILENAME and EOFNEWLINE.
- Checkers: `ERROR_ON_LINTER_ERRORS` = True, `ERROR_ON_LINTER_TIMING_CONSTRUCTS` = True,
  **`ERROR_ON_LINTER_WARNINGS` = False**. Warnings are counted in `design__lint_warning__count` but do not fail the flow.
- tt-support-tools d66cf17 does not override any LINTER_* or ERROR_ON_LINTER_* variable (grep).

## Local run (Verilator 5.052 conda-forge; CI may use a different Verilator build)

Same command on `src/tt_um_dean_protocol_emulator.v src/pemu_core.v`: exit 0, 0 errors, 0 timing constructs, 7 warnings:

| warning | count | source |
|---|---|---|
| COMBDLY | 2 | Hardcaml `always @*` + `<=` for the wide muxes (64-entry read, opcode mux) |
| UNUSEDSIGNAL | 5 | Hardcaml name aliases, `vdd`, constant bit-slices |

Consequence: COMBDLY (open decision 7) does **not** block the TT flow under the default configuration. It remains a
simulation-semantics style issue. Icarus RTL and gate-level replays match (test/README, log below). Not fixed: decision 7 is yours.

## Replay results on this commit

- RTL (`cd test && make`): 7/7 pass (6 spec-trace scenarios, 13,828 cycles; comparator negative control).
- Local gate-level preview (`make GATES=yes` on a Yosys SG13CMOS5L mapping of the whole wrapper, `flow/map/map_cmos5l.sh top`,
  PDK 2bbec755 functional models): 7/7 pass. Not the LibreLane netlist; CI gl_test is the real check.
- DUT negative control: with the wrapper's reset synchroniser bypassed, 4/6 scenarios fail (random_1..3, reset_then_reload).

## Template defect found

Template b86a2a7 `test/Makefile` (GL branch) lists `sg13cmos5l_stdcell.v` and `sg13cmos5l_io.v` only. At PDK 2bbec755 the stdcell
models instantiate UDPs (`ihp_dff_r` in all 8 reset flops, `ihp_mux2`, `ihp_latch`, ...) defined only in
`sg13cmos5l_udp.v`. Without it Icarus fails with "Unknown module type: ihp_mux2" (reproduced locally). Our Makefile now also
compiles `sg13cmos5l_udp.v`. If CI reports duplicate primitive definitions, the CI PDK differs from ours and this line should go.
