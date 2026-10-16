# IHP-macro variant: integration notes (2026-10-16, branch core-macro @ dc2dfc1)

Sources: Ken Pettit, "Dropping a real SRAM macro into your CMOS5L tile" (kdp1965.github.io/ihp-um-janestreet-prism,
2026-09-29, linked in the organisers' email); his repo kdp1965/ihp-um-janestreet-prism @ 05a68dc (2026-10-15, Apache-2.0);
PDK 2bbec755 LEF/datasheet for RM_IHPSG13_1P_64x16_c2; LibreLane 3.1.0.dev3 sdist. "Fact" = read from a source; "estimate" = mine.

## Done on core-macro (PDN-independent, tested locally)

| item | status |
|---|---|
| wrapper instantiates `pemu_core_macro` (instance `core`; SRAM is `core.u_imem` in the flattened netlist) | fact (Yosys flatten); LibreLane naming to be confirmed in CI |
| A_DLY tied 1, A_MEN tied 1 (always enabled), no BIST/BM ports on this macro | fact (generated Verilog; datasheet requires DLY=1) |
| `src/sram_64x16_bb.v`: `(* blackbox *)` header under `ifndef SIM` (walkthrough pattern) | ports equal PDK model and LEF (checked) |
| test/Makefile: vendored SRAM model in RTL and GL builds, `-DSIM -DFUNCTIONAL` for RTL | RTL replay 7/7; local GL preview (Yosys mapping, SRAM black box + model) 7/7 |
| info.yaml source_files: wrapper, pemu_core_macro.v, sram_64x16_bb.v | done |
| `src/config.json` | MACROS (gds/lef/cdl/3 libs, `core.u_imem` at (3.36, 321.30) N), PDN grid 44.96/3.52/2.1/6.15, custom PDN_CFG, PDN_MACRO_CONNECTIONS, halos 2.0/0.48, ERROR_ON_PDN_VIOLATIONS 0. Magic DRC stays on, KLayout DRC stays off (template), no illegal-overlap waiver, no ROUTING_OBSTRUCTIONS (LEF OBS covers 99.8-99.9% of Metal1-3; Metal4 is OBS + power columns) |
| power step | `Pemu.MacroColumnStripes` (user decision 2026-10-16: own minimal step), see flow/pdn/README.md |

Note (estimate): A_MEN is tied high, so the macro is enabled every cycle (reads address 0 while halted). This costs dynamic power
and does not affect function. Gating MEN would be an RTL change and is not made.

## Facts that constrain the PDN

- TT CMOS5L tile PDN: Metal4 vertical stripes only (`FP_PDN_MULTILAYER` 0). Template sets VPITCH 50, VWIDTH 2.1; the PDK sets
  VSPACING 2.0, VOFFSET 10. These are in the template's "DO NOT CHANGE" section.
- The macro's supplies are Metal4 columns, 2.81 um wide. Left array: VDD at 5.665 + 11.24k, VSS at 11.285 + 11.24k (k = 0..7).
  The middle band is irregular. The right array is about 0.67 um off-phase. VDD! covers y 0-38.8 and VDDARRAY! covers 45.5-64.4 on the same columns.
  Signal pins: 43 on Metal2, bottom edge (orientation N).
- With the template grid, VPWR to VGND spacing is 4.1 um against the macro's 5.62 um, so one tile stripe pair cannot land on a VDD/VSS column pair.
- Ken's repo, fact as he states it: "pdngen carves its stripes around macros", so the stock single-layer TT PDN does not reach the macro pins. He uses
  a custom `PDN_CFG` without the per-macro grid (the stock one fails with PDN-0233) plus a LibreLane plugin step
  `Project.ExtendPowerStripes` (426 + 727 lines of Python) inserted via `meta.substituting_steps`. His README says
  `tt_tool.py --harden`, and so the stock TT GDS action, picks the plugin up from the repo root. His own CI instead
  publishes locally hardened views through `tt-gds-action/custom_gds`, because his 8x4 template is not upstream.
- His grid numbers (pitch 44.96, spacing 3.52, width 2.1, offset 6.15, macro at x = 3.36 + 11.24i) carry over exactly to
  the 64x16, because the left-array column pitch and offset are identical.
- Sign-off with stripes across the macro: Magic flags overlaps with the LEF OBS bar at the VDD/VDDARRAY break. He sets
  `RUN_MAGIC_DRC` 0, `ERROR_ON_ILLEGAL_OVERLAPS` 0 and `RUN_KLAYOUT_DRC` 1 with the CMOS5L precheck deck. LVS needs the CDL view as `spice`.
- His walkthrough also offers a "no stripe step" route (VPITCH 11.24 with plain pdngen). That contradicts the README statement above,
  so it is unverified until a run shows it.

## Not yet checkable locally

No OpenROAD/LibreLane runs here (no Docker/Nix in the sandbox, no remote compute configured). Every PDN option needs a real harden
run (GitHub CI after a push, or local hardening on your machine) to see whether the macro gets power. The walkthrough states that an
unpowered macro can pass DRC and LVS, so the acceptance checks are: the PSM/IR-drop step reports no floating net, and a geometric
check that every Metal4 stripe crossing the macro lies within a column of matching polarity (VPWR on VDD!, VGND on VSS!). That check
can be scripted against the final DEF; it is proposed here and not written yet.
