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

## v2 builds (pemu_core_v1m + two SRAM macros): E4/E5 by induction

```
flow/equiv/prep_cut_v1m.sh <ci-artifacts-dir> <work>          # SRAM-cut sources + liberty cell models
flow/equiv/run_e5_induct.sh <work> flow/equiv/maps/<map>.json e5 fin_cut.v   # E5, about 2 min
flow/equiv/run_e5_induct.sh <work> flow/equiv/maps/<map>.json e4 syn_cut.v   # E4
```

`<ci-artifacts-dir>` holds GDS_logs (src/, runs/wokwi/06-yosys-synthesis/) and tt_submission of a TT
CI run. Method: Yosys `equiv_make` + `equiv_induct -seq 2` (no `equiv_simple` before it), gold
bit-blasted and `opt_merge`d. A per-build map (`equiv_aug.py`) renames netlist nets whose name hint is
a false pair and adds reachable-state invariants; every map entry is a proof obligation. The result is a
proof only when `equiv_status` reports all pairs proven. `run_equiv_v1m.sh` (ABC dprove/PDR on the
same cut) stays for its negative-control recipes; it was UNDECIDED on these netlists.

| build | map | E4 | E5 |
|---|---|---|---|
| v2-min, e218611, 33 MHz (run 41442167676; 30 MHz netlist identical) | `maps/v2min_e218611.json` | proven, 2,285/2,285 | proven, 2,285/2,285 |
| v2inc1 + T, 82dd594, 33 MHz (run 41887577418; timing fails, slow WNS -1.99 ns) | `maps/v2inc1T_82dd594.json` | proven, 2,549/2,549 | proven, 2,549/2,549 |

Details, controls and the premise of the claim: log/ci_results_v2.md section 5.
