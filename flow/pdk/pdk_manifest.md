# SG13CMOS5L PDK subset manifest (2026-10-16)

Fetched by `tools/fetch_pdk.sh` into `.toolchain/pdk` (gitignored). Used only for local mapping
estimates and netlist equivalence; the GDS is built by the TT GitHub action, which installs the full PDK itself.

## Pinned revisions (facts, read 2026-10-16 via git ls-remote / clone)

| source | ref | commit | changed since 2026-09-26? |
|---|---|---|---|
| TinyTapeout/ttihp-verilog-template | cmos5l | b86a2a7 | no |
| TinyTapeout/tt-gds-action | ihp-cmos5l | 3412659 (2026-09-14, "fix: install ihp-sg13cmos5l from the merged IHP-Open-PDK tree #52") | no |
| TinyTapeout/tt-support-tools | ihp-sg13cmos5l | d66cf17 | no |
| IHP-Open-PDK (IHP_PDK_REV in install_sg13cmos5l.sh) | - | 2bbec755dc67ca3db0261c3d6163e15735d66710 | no |
| LibreLane (action default `librelane-version`) | - | 3.1.0.dev3 | - |

- The organisers' email says the GDS-action CMOS5L install problem was fixed "a few weeks ago". The fix is
  3412659, the head we already use (the workflow references the moving branch `@ihp-cmos5l`).
- No 8x4 CMOS5L template branch exists yet (template heads: `cmos5l`, `main`). info.yaml stays 6x4.
  The tooling side (tile_sizes.yaml in tt-support-tools d66cf17) already accepts 8x4.

## LibreLane PDK settings relevant to our flow (facts, from libs.tech/librelane at 2bbec755)

- STA corners: nom_fast_1p32V_m40C, nom_slow_1p08V_125C, nom_typ_1p20V_25C; DEFAULT_CORNER = typ;
  **TIMING_VIOLATION_CORNERS = "\*typ\*"** (only typ violations fail the flow; slow is reported, not enforced).
- Synthesis-excluded cells: lgcp_1, sighold, slgcp_1, sdfbbp_1, dfrbp_2.
- Tie cells: tiehi/tielo; diode cell antennanp; CLOCK_UNCERTAINTY 0.25 ns; IO_DELAY_CONSTRAINT 20 (% of period).
- Site 0.48 x 3.78 um. VDD/GND pins VPWR/VGND at 1.20 V.
- `libs.tech/librelane/IHP_rcx_patterns.rules` is a symlink outside the fetched subset; not needed locally.

## SRAM model provenance

- rtl/macros vendored `RM_IHPSG13_1P_64x16_c2.v` is byte-identical to the PDK file at 2bbec755.
- rtl/macros vendored `RM_IHPSG13_1P_core_behavioral.v` is byte-identical to the PDK file at 2bbec755.
- `sg13cmos5l_sram` is a symlink to `ihp-sg13g2/libs.ref/sg13g2_sram`; files below are the resolved copies.

## Files (sha256, first 16 hex digits)

| file | bytes | sha256 |
|---|---|---|
| `ihp-sg13cmos5l/SOURCES` | 63 | `6b33873ea62c0711…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/verilog/sg13cmos5l_io.v` | 6610 | `204e15c480c16215…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram/doc/RM_IHPSG13_1P_64x16_c2.txt` | 16137 | `081efefc479ad5c0…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram/gds/RM_IHPSG13_1P_64x16_c2.gds` | 428032 | `0cc794e39c7c6006…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram/lef/RM_IHPSG13_1P_64x16_c2.lef` | 49080 | `c4f569509aabce95…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram/lib/RM_IHPSG13_1P_64x16_c2_fast_1p32V_m55C.lib` | 24240 | `9f67d502554b015a…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram/lib/RM_IHPSG13_1P_64x16_c2_slow_1p08V_125C.lib` | 24260 | `17c7ba8a5ea84c2a…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram/lib/RM_IHPSG13_1P_64x16_c2_typ_1p20V_25C.lib` | 24241 | `4969c236a1fd96f2…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram/verilog/RM_IHPSG13_1P_64x16_c2.v` | 3992 | `63a682d02cc35a69…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram/verilog/RM_IHPSG13_1P_core_behavioral.v` | 2796 | `5aa61ac427a9c725…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram/verilog/RM_IHPSG13_1P_core_behavioral_bm_bist.v` | 3951 | `d0a6258f8e9c93d1…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/cdl/sg13cmos5l_stdcell.cdl` | 86965 | `6354feb07a2e5a0f…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/doc/ReleaseNotes.txt` | 6074 | `007cfb772ec4894d…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/doc/sg13cmos5l_stdcell.celllist` | 1569 | `9bf3d94c1fa1283f…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/doc/sg13cmos5l_stdcell_fast_1p32V_m40C.pdf` | 880209 | `0b6b7b2e2932acaa…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/doc/sg13cmos5l_stdcell_fast_1p65V_m40C.pdf` | 880925 | `62705f585ca83b5f…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/doc/sg13cmos5l_stdcell_slow_1p08V_125C.pdf` | 880624 | `8f90a7b1e251ce71…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/doc/sg13cmos5l_stdcell_slow_1p35V_125C.pdf` | 881593 | `2634c6a6a652cab9…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/doc/sg13cmos5l_stdcell_typ_1p20V_25C.pdf` | 880209 | `a7dd2fff8de091d1…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/doc/sg13cmos5l_stdcell_typ_1p50V_25C.pdf` | 880615 | `b91fd28dc64a14c5…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/gds/sg13cmos5l_stdcell.gds` | 625660 | `54fd3679e868e1e5…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lef/sg13cmos5l_stdcell.lef` | 189974 | `c47c436758ae8728…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lef/sg13cmos5l_tech.lef` | 21454 | `3edd5a1ad31e8307…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_fast_1p32V_m40C.lib` | 1721703 | `af12d75a72d19648…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_fast_1p65V_m40C.lib` | 1715733 | `7cfb04711be1163b…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_slow_1p08V_125C.lib` | 1716327 | `3ee222c580ba33ac…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_slow_1p35V_125C.lib` | 1714229 | `121a828abfb4ad14…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib` | 1720579 | `34163f3e7de9f854…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p50V_25C.lib` | 1717793 | `bd3dc635904542ac…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/spice/sg13cmos5l_stdcell.spice` | 119050 | `7dd7f87104bf1c53…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/verilog/sg13cmos5l_stdcell.v` | 83886 | `b0adbc84c8f78feb…` |
| `ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/verilog/sg13cmos5l_udp.v` | 13046 | `5491a3edf7468792…` |
| `ihp-sg13cmos5l/libs.tech/librelane/config.tcl` | 6137 | `e519dbab28573f2a…` |
| `ihp-sg13cmos5l/libs.tech/librelane/sg13cmos5l_io/config.tcl` | 1069 | `86f1c93ff0d3e18c…` |
| `ihp-sg13cmos5l/libs.tech/librelane/sg13cmos5l_stdcell/config.tcl` | 3421 | `9ffb30a2547a5e4f…` |
| `ihp-sg13cmos5l/libs.tech/librelane/sg13cmos5l_stdcell/latch_map.v` | 650 | `646d71de00d45e9e…` |
| `ihp-sg13cmos5l/libs.tech/librelane/sg13cmos5l_stdcell/mux2_map.v` | 179 | `9a4f60cdea075ef2…` |
| `ihp-sg13cmos5l/libs.tech/librelane/sg13cmos5l_stdcell/mux4_map.v` | 263 | `078ce20f0982de15…` |
| `ihp-sg13cmos5l/libs.tech/librelane/sg13cmos5l_stdcell/pnr_exclude.cells` | 95 | `2f54a4f8fb71ca60…` |
| `ihp-sg13cmos5l/libs.tech/librelane/sg13cmos5l_stdcell/synth_exclude.cells` | 95 | `2f54a4f8fb71ca60…` |
| `ihp-sg13cmos5l/libs.tech/librelane/sg13cmos5l_stdcell/tracks.info` | 188 | `03c55e783934e42f…` |
| `ihp-sg13cmos5l/libs.tech/librelane/sg13cmos5l_stdcell/tribuff_map.v` | 134 | `43fa0f921650f857…` |
