# TT CI results (2026-10-17)

Source: artifacts in `ci-artifacts/` (user download). Run: https://github.com/fonsResearch/protocol-emulator-asic/actions/runs/39022291276
Commit d7eb344 (branch main, **flop-memory core**). RTL as hardened is byte-identical to the repo at d7eb344 (sha256 checked).
Flow: LibreLane 3.1.0.dev3, tt-support-tools d66cf179, IHP-Open-PDK 2bbec755, 6x4 tile, CLOCK_PERIOD 20 ns.
**core-macro: no artifacts received yet** (column below left empty).

All values are facts read from `runs/wokwi/final/metrics.csv`, `55-openroad-stapostpnr/`, `precheck_reports/`, `gatelevel_test_results/results.xml`, unless marked *estimate*.

| item | flop core (main @ d7eb344) | macro core (core-macro) |
|---|---|---|
| GDS job | Flow complete, 0 lines in error.log | - |
| precheck (KLayout DRC deck, pins, boundary, layers, cell names, zero area, pin labels) | all pass | - |
| gate-level cocotb (LibreLane netlist, PDK UDP models) | 7/7 pass (6 spec-trace scenarios, 13,828 cycles; comparator control) | - |
| RTL cocotb (test workflow) | not in the artifacts (status visible on GitHub only) | - |
| Magic DRC / illegal overlaps | 0 / 0 | - |
| LVS errors (device / net / pin) | 0 (0 / 0 / 0) | - |
| antenna violations (nets / pins); diodes inserted | 0 / 0; 5 | - |
| detailed-route DRC | 0 after 5 iterations (26, 12, 9, 2, 0) | - |
| std-cell area (excl. fill/decap) / utilisation of 902,417 um^2 core | 121,313 um^2 / 13.4% | - |
| of which logic (flops + comb + inv) | 94,024 um^2 (1,121 flops) | - |
| of which timing-repair buffers / clock tree | 24,447 um^2 (1866 buffers, 1202 of them hold) / 2,814 um^2 | - |
| setup WNS typ / slow / fast (ns, 20 ns period) | 12.747 / 8.516 / 15.196 | - |
| hold WNS typ / slow / fast (ns) | 0.290 / 0.612 / 0.110 | - |
| setup / hold TNS, all corners | 0 / 0 | - |
| max slew / max cap violations | 0 / 0 | - |
| max fanout violations | 70, all on CTS leaf clock buffers (17-18 sinks vs limit 8); no data net | - |
| clock skew worst setup / hold (ns, fast) | 0.309 / -0.354 | - |
| IR drop worst / avg (V) | 1.54e-04 / 1.74e-05 (VSRC_LOC_FILES not set: TT top-level feed positions unknown to PSM) | - |
| power total (W, default activity) | 4.01e-03 | - |
| power-grid violations (VPWR / VGND) | 0 / 0 | - |
| lint errors / warnings | 0 / 7 (2 COMBDLY, 5 UNUSEDSIGNAL; non-fatal by default) | - |
| disconnected pins | 7, 0 critical: ena, ui_in[5:0] (unused in the v0 pin map) | - |
| summed step runtime | 53 min (GitHub Actions limit 6 h) | - |

## Against the local estimate (flow/map/area_report.md)

- Logic area: 94,024 um^2 in CI vs 86,172 um^2 estimated (+9%). The estimate omitted resizer and CTS cells, which add 27,261 um^2 (+29% over logic).
- The 1,202 hold buffers are all `sg13cmos5l_dlygate4sd3_1`. Their sinks are mostly mux2 A0/A1 (521) and nor2 A (397) inputs: an inference
  that they sit on the short recirculating paths of the 1,024 instruction-memory flops, fixed against 0.35-0.46 ns clock skew at the fast corner.
  These buffers are a cost of the flop-memory variant (*estimate*: most would disappear with the macro).
- Slow-corner setup slack 8.52 ns leaves a register-to-register path of about 11.5 ns (*estimate* of headroom: about 87 MHz at the slow corner,
  about 138 MHz at typ from the 12.75 ns slack). Only typ is enforced (`TIMING_VIOLATION_CORNERS = *typ*`). A higher clock would also
  change resizer and IO-constraint behaviour, so these are not achievable-frequency claims.

## Open questions settled by this run

- The GL Makefile line adding `sg13cmos5l_udp.v` is accepted in CI (no duplicate-primitive error) and the GL job passes with it.
- Flop count is unchanged (1,121 `dfrbpq_1` in the local mapping of wrapper + core and in CI). Sequential equivalence of the final netlist (E5,
  log/equiv_cmos5l.md) holds regardless of whether flops were moved or merged.
- COMBDLY lint warnings do not fail the flow (as predicted from LibreLane source).
