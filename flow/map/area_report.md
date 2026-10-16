# SG13CMOS5L mapping estimate: flop-memory vs IHP-macro core (2026-10-16)

Script: `flow/map/map_cmos5l.sh <flop|macro>` (Yosys 0.69, PDK 2bbec755 typ liberty `sg13cmos5l_stdcell_typ_1p20V_25C`,
PDK mux/latch maps, LibreLane `synth_exclude.cells` as dont-use, tie cells). Inputs: `src/pemu_core.v`, `src/pemu_core_macro.v`
as committed (Hardcaml v0.17.1 output). The macro is a black box with area from `RM_IHPSG13_1P_64x16_c2_typ_1p20V_25C.lib`.

**Status: estimate.** This approximates LibreLane's synthesis step only. It has no placement, CTS, resizer buffering,
fill/tap/decap, or macro halo/PDN overhead. The TT CI numbers (step 6) replace these.

## Area (cells mapped; the wrapper's 2 reset-synchroniser flops are not included)

| | flop-memory core | IHP-macro core |
|---|---|---|
| std cells | 3,991 | 502 + 1 SRAM macro |
| flops (all `sg13cmos5l_dfrbpq_1`) | 1,119 | 79 |
| instruction storage | 50,148 um^2 (1024 flops) | 15,240 um^2 (macro, liberty area; LEF 236.80 x 64.36 um) |
| other flops | 4,652 um^2 | 3,870 um^2 |
| mux2 cells | 10,300 um^2 | 671 um^2 |
| other logic | 21,072 um^2 | 3,439 um^2 |
| **total** | **86,172 um^2** | **23,221 um^2** |
| fraction of 6x4 core area (902,417 um^2) | 9.5% | 2.6% |
| fraction of 8x4 core area (1,208,173 um^2) | 7.1% | 1.9% |

Core area = die (tt-support-tools `tile_sizes.yaml`) minus the template margins (6 sites left/right at 0.48 um,
1 row top/bottom at 3.78 um). The 6x4 value matches the 902,417 um^2 a competitor reports from a local LibreLane run.

Facts from this run:
- The flop variant's area is 70% instruction storage plus mux2 cells;
  1024 storage flops at 49.0 um^2 each.
- Per instruction word, flop storage costs 784 um^2 against 238 um^2 for the 64x16 macro
  (macro area only; halo and PDN are excluded). The ratio grows if imem is enlarged later: the 256x16 macro is 28,127 um^2 (cmos5l_constraints.md).
- The SG13CMOS5L stdcell liberty has **no flop without reset** (`dfrbp`, `dfrbpq`, `sdfbbp` only; `sdfbbp_1` and `dfrbp_2`
  are dont-use). Every no-reset register, including all 1024 imem bits, maps to `dfrbpq_1` with RESET_B tied high.
  With `hilomap -singleton` that is one tie-high cell driving more than 1000 pins; the TT flow's resizer must buffer it.
  Not a functional issue; noted because it shows up in netlist equivalence (step 7) and in fanout repair.
- No async-set flop is used (no `sdfbbp`). The core uses synchronous clear (`rst_sync_n`), so its reset logic is in the D path.

## Timing (estimate only; no wires, no fanout buffering)

ABC `stime` on the mapped combinational network between register boundaries:

| | typ 1.20 V 25 C | slow 1.08 V 125 C |
|---|---|---|
| flop-memory core, longest logic path | 6.15 ns | 13.7 ns |
| macro core, longest logic path | 1.52 ns | 2.36 ns |
| SRAM clock-to-DOUT (liberty table, typ) | about 2.97 ns | not read |

- The LibreLane PDK config sets `TIMING_VIOLATION_CORNERS = "*typ*"`, so only the typ corner fails the flow (fact). The slow corner is
  reported but not enforced.
- Both variants look comfortably inside the 20 ns template period at typ (estimate). The flop variant's slow-corner logic
  path, at 13.7 ns before wire and buffer delay, is the one to watch if the clock is raised; that path is the 64:1 x 16 read mux.
- For the macro variant, the SRAM's DOUT feeds instruction decode in the same cycle, so the macro path is roughly
  clock-to-DOUT plus decode, about 4.5 ns typ (estimate).
- OpenSTA was not installed (`conda search` failed with a plugin error), so there is no real STA locally.

## Implications (no choice made; decision 5 is yours)

- Area does not decide decision 5 at the current ISA: both variants use under 10% of the 6x4 core.
  It becomes relevant if imem grows or if multiple lanes or engines are added (the email lists concurrency as a plus).
- The macro variant is 3.7x smaller in mapped area (62,951 um^2 less at this ISA), but adds macro integration overhead (halo, PDN straps, placement) that this estimate does not measure.
