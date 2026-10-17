# SRAM macro power delivery (branch core-macro)

| file | role | verified how |
|---|---|---|
| `../../librelane_plugin_pemu_pdn.py` | LibreLane plugin, step `Pemu.MacroColumnStripes`, inserted after `OpenROAD.GeneratePDN` via `meta.substituting_steps` | LibreLane 3.1.0.dev3 (pip) discovers it from the repo root, registers it, places it after GeneratePDN; full config loads (PDK placeholders for files outside the local subset) |
| `macro_stripes_geom.py` | geometry: which tile stripes may be bridged onto which macro power columns; property check C1-C3 | `test_macro_stripes.py`: 13 tests on the real 64x16 LEF, incl. negative controls (unpowered, misplaced by one site, stripe across the VDD/VDDARRAY OBS bar, wrong polarity, uncarved grid) |
| `odb_macro_stripes.py` | odb glue run by `openroad -python`; draws the bridges, re-checks, fails the step on any violation; metrics `design__macro_stripe_violation__count`, `design__macro_stripe_bridged__count`; report `macro_stripes.json` in the step dir | **not executed yet** (no OpenROAD here); first exercised in CI |
| `check_macro_stripes_def.py` | same property on a final DEF, no OpenROAD | DEF round-trip tests (pass, unpowered, stripe over bar) |
| `check_sram_bar_gds.py` | GDS evidence for crossing the VDD!/VDDARRAY! Metal4 OBS bar: no Metal4 (50/0) or Via3 (49/0) under the stripe footprint | run on PDK 2bbec755: both aligned VPWR footprints CLEAR, nearest Metal4 3.16 um; injected-metal control reports BLOCKED (exit 1) |
| `pdn_cfg.tcl` | LibreLane default PDN config minus the macro grid (PDN-0233 on the single-layer tile) | diff against LibreLane 3.1.0.dev3 source: only the trailing macro-grid block removed |

Run the tests: `PEMU_SRAM_LEF=<lef> python -m pytest flow/pdn/test_macro_stripes.py` (defaults to the
`tools/fetch_pdk.sh` location; tests skip when the LEF is absent).

Property (fails the step if violated, re-checkable on the final DEF):
- C1: inside the macro, every VPWR/VGND Metal4 shape lies within same-polarity pin rectangles (never over OBS);
- C2: no VPWR shape overlaps a VSS! column, no VGND shape overlaps a VDD!/VDDARRAY! column;
- C3: VDD!, VDDARRAY! and VSS! are each touched by at least one same-polarity stripe;
- C4: every VPWR/VGND pin box reaches within 10 um of the top and bottom die edges (Tiny Tapeout pin check).

Mode since 2026-10-17 (`PEMU_STRIPE_FULL_SPAN`, `PEMU_STRIPE_CROSS_PIN_GAPS`): the 4 misaligned stripe pairs over the macro
are removed by `PDN_OBSTRUCTIONS`; the 2 aligned pairs are made full height across the macro (one stripe box, one pin box
each), crossing the VDD!/VDDARRAY! bar, which C1 then accepts as a same-polarity pin gap. Tests: 21.

Not covered by this property: IR drop and electromigration (OpenROAD.IRDropReport), LVS (Netgen.LVS), DRC.
With the macro at x = 3.36 only two VPWR/VGND pairs feed it, both on the left bit-cell array; whether that is
enough is decided by the IR-drop report, not here.
