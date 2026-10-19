# Core v1 through the Tiny Tapeout CMOS5L flow (plan step 8)

Branch `v1-tt`. User decisions 2026-10-19: all 15 ROM packages in the first run (trim only if it
does not close), no rename, CI on a separate branch, floorplan C. Clock 60 MHz (decision A10).

## 1. Prepared and checked locally (before the first CI run)

| item | check | result |
|---|---|---|
| 8x4 tile in the TT tools | tt-support-tools `ihp-sg13cmos5l`: `tile_sizes.yaml` 8x4 = 1724.16 x 710.64 (d66cf179), `def/tt_block_8x4_pgvdd.def` present | present (GitHub API, 2026-10-19) |
| SRAM views in CI | PDK 2bbec755 (`install_sg13cmos5l.sh`): `sg13cmos5l_sram` -> `sg13g2_sram` symlink; 1P 256x16 bm_bist gds/lef/cdl/lib/verilog present | present |
| core Verilog | `emit_lane_rtl.exe top_macro_mon_liball` -> `tools/fix_combdly.py` (12,599 assignments) -> `src/pemu_core_v1m.v` | Yosys `equiv_*` EQUIVALENT (842 s); no X literals |
| ROM library refactor | `rtl_v1/src/rom_lib.ml` shared by emitter and vector exporter | lib10 and liball Verilog byte-identical before/after |
| TT top synthesis | Yosys + ABC, typ, `hierarchy -check`, exactly the `info.yaml` sources | 450,489 um2 std cells, 3 macros; ~40 % of core area minus macros [estimate, no routing growth] |
| pin-level replay (RTL) | `test/test.py` on `v1_rom_uart`, `v1_loadable_l1`, `v1_reset_mid` (57,671 cycles; vectors from `rtl_v1/bin/dump_tt_vectors_v1.exe`, Hardcaml cyclesim + behavioural SRAM + wrapper reset model) against the Verilog wrapper with the IHP 256x16 models | 0 mismatches; comparator negative control detects its injected flip |
| PDN geometry, floorplan C | `flow/pdn/test_floorplan_v1.py` (real 256x16 LEF, config.json obstructions/placements, plugin loop emulated in all 6 instance orders) | 9/9 pass: C1-C4 hold, 2 VPWR + 2 VGND full-height stripes per macro; negatives (macro shifted one site, no obstructions) fail as expected |
| crossing the VDD!/VDDARRAY! bar | `check_sram_bar_gds.py` on the 256x16 GDS (blob 77d647dd), 4 aligned VPWR footprints | all CLEAR (nearest Metal4 2.97-3.16 um); injected-metal control BLOCKED |
| 64x16 PDN tests (regression) | `flow/pdn/test_macro_stripes.py` | 21/21 pass |

Agent choices to review: FS orientation for all three macros (extends the 2026-10-17 64x16
decision); y placements 41.58 / 207.90 / 41.58 (47.5 um pin channel); vector scenarios.

## 2. To be measured by the first CI run (nothing below is known yet)

- GDS / precheck / gate-level replay pass or fail; the GL replay of 57,671 cycles is slower than RTL [runtime not estimated].
- Utilisation after placement and routing; this replaces the 1.34x growth estimate behind the ~503k budget.
- Setup and hold slack at 16.67 ns in typ / slow / fast, in particular the SRAM fetch path (estimate <= 12.95 ns slow before wiring) and A_ADDR hold (up to 0.85 ns).
- A_DOUT max capacitance (0.064 pF limit) on all three macros; post-GRT repair margin 30 % is carried over from core-macro.
- `design__macro_stripe_violation__count`, IR drop (only 2 stripe pairs per macro; 7 of 38 pairs removed), LVS, KLayout DRC, antenna.
