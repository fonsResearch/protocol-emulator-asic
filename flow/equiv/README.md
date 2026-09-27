# flow/equiv

`flow/equiv/run_equiv.sh [timeout-s]` (repo root, tools/env.sh sourced, src/*.v generated).

| check | claim | result 2026-09-27 |
|---|---|---|
| E1 | pemu_core (behavioural SRAM) == pemu_core_macro + unmodified IHP RM_IHPSG13_1P_64x16_c2 functional model (-DFUNCTIONAL), outputs equal every cycle, arbitrary inputs | PASS, dprove, 5 s |
| E1 neg | same, IHP model with write-through removed (`dr_r<= dr_r`) | FAIL (as required) |
| E2 | pemu_core == Yosys `synth -flatten` generic netlist | PASS, dprove, 3 s |
| E2 neg | netlist with uo_out[0] inverted | FAIL (as required) |
| E3 | generic netlist replays the 2715-cycle spec-derived vectors (Icarus + Yosys simcells) | 0 errors |

Initial state: every FF init 0 before any opt; both memories 0 (equal); SRAM output registers
(`rtl_imem_dout`, IHP `dr_r`) free and independent, selected structurally (the flip-flops
driving the named wire, then all wires on their Q ports). Guard: 32 free init bits.

Not covered here:
- the real SG13CMOS5L netlist. It is produced by the Tiny Tapeout GitHub Action (tt-gds-action
  @ihp-cmos5l). The gate-level test there runs test/ on it after the repo is pushed; a
  formal check of that netlist against src/*.v needs the IHP cell models;
- the TT wrapper tt_um_dean_protocol_emulator, which does not instantiate a core yet;
- the IHP model's timing (`specify`) and A_DLY checks, which are ignored under -DFUNCTIONAL.
