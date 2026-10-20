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

## 3. CI run 1 (v1-tt 177fdd0; sources in the artifacts match the commit)

The GitHub run page crashed the user's browser tab; the GDS logs were downloaded with the gh CLI
(`ci-artifacts/v1-tt/GDS_logs`). Precheck and gate-level results were not part of the download.

- The flow stopped at step 22 of 27, `Pemu.MacroColumnStripes` (exit on violations). Nothing after
  PDN ran: no placement, routing, timing, utilisation or IR-drop numbers yet.
- Macro bridging worked as designed: `core.u_imem_l0` and `core.u_imem_l1` bridged 4 stripes each
  (0 violations); `core.u_lstore_l1` skipped 4 (already full height from the macro above), 0 violations.
- The only violations: C4 (TT pin rule) on one VGND box, x 1719.315-1720.365 um (1.05 um wide),
  y 33.8-162.76 um, in the 8.48 um channel between the lane-0 macro (x 1476.0-1712.8) and the right
  core edge (1721.28). pdngen drew it there; the log gives no reason. Most likely channel repair next
  to a macro (pdngen halo 10 um in this config) [inference]. The local stripe model did not predict it.
- `PSM-0069` in error.log: GeneratePDN's own check, before the step bridges the macros (as on core-macro).

Fix (user decision 2026-10-19): lane-0 macro one stripe pitch left, x = 1431.04 (same column alignment,
pairs k = 32, 33; obstructions k = 34-36; 53.44 um to the core edge, where pair k = 37 runs full width).
New test `test_no_narrow_channel_to_core_edge` (fails on x = 1476.0 with an 8.48 um gap; passes now);
floorplan tests 10/10.

## 4. CI run 2 (v1-tt 8d90d04; GitHub run log logs_106540443244, job cancelled at the 6 h limit)

No artifacts (a cancelled job uploads none); evidence is the job log.

| step (UTC 2026-10-19/20) | duration |
|---|---|
| synthesis -> PDN (Pemu.MacroColumnStripes: 4/4/skip 4 bridged, **C4 0 violations on 63 pin boxes**) | 20:02-20:06 |
| placement, CTS | 20:06-20:10 |
| ResizerTimingPostCTS | 22 min |
| GlobalRouting | 19 min; final usage 56.81 %, overflow 1,421 (max H 7 / V 6) after 50 congestion iterations, continued only because of `-allow_congestion`; wirelength 3.60 m |
| RepairDesignPostGRT | 67 min |
| antenna repair, diodes | 3 min |
| DetailedRouting | started 22:08, cancelled 01:59: iteration 0 -> 45,342 violations (74 min), 1 -> 27,023 (64 min), 2 -> 24,951 (65 min), 3 at 70 % with 14,858 |

- Signal layers Metal2-Metal4 only (tt-support-tools IHPTech `project_top_metal_layer = "Metal4"`; GRT log
  "max routing layer Metal4"); Metal4 also carries the PDN stripes. Derated resources M2 197,497 / M3 241,815 / M4 195,266.
- The floorplan fix of run 1 is confirmed: the stray strap is gone.
- Interpretation [inference]: global demand fits, but local hotspots leave about 25k detailed-routing violations;
  at ~1 h per iteration the route cannot finish inside GitHub's 6 h job limit without reducing congestion.
  The hotspot locations are unknown (no artifacts).

Run 3 changes (user decisions 2026-10-19): `PL_TARGET_DENSITY_PCT` 60 -> 48 (only design-side change);
fail-fast guard `DRT_OPT_ITERS` 1 (iterations 0 and 1 per OpenROAD master `FlexDR::main`; the CI OpenROAD
version is not printed in the log, so this reading is unverified for CI). Correction: in run 2 detailed routing
started 2 h 10 min after the job start (19:59 -> 22:08), not ~4 h as first stated.
