# Build-path report: both core variants through the Tiny Tapeout CMOS5L flow (2026-10-17)

Style as in log/slice_report.md: **fact** = from a run whose logs are in `ci-artifacts/` or the repo; **estimate** = judgement.
Flow for all runs: tt-gds-action `ihp-cmos5l` 3412659, tt-support-tools d66cf17, LibreLane 3.1.0.dev3, IHP-Open-PDK 2bbec755, 6x4 tile, 20 ns.

## 1. Measured results (facts)

| | flop-memory core (main @ d7eb344, run 39022291276) | IHP-macro core (core-macro @ 0f4d84e, run 3) |
|---|---|---|
| TT precheck (all 9 checks) | pass | pass |
| gate-level cocotb (LibreLane netlist, PDK UDP models; 6 spec-trace scenarios, 13,828 cycles + comparator control) | 7/7 | 7/7 (with IHP SRAM functional model) |
| RTL == synthesis netlist / final netlist (E4 / E5, ABC dprove, liberty cell semantics) + 2 negative controls | PASS / PASS, controls fail at frames 0 and 8 | PASS / PASS (SRAM as IHP model on both sides), controls fail at frames 0 and 8 |
| LVS / routing DRC / antenna | 0 / 0 / 0 | 0 / 0 / 0 |
| DRC sign-off | Magic DRC 0 (template) | KLayout DRC 0 in flow; Magic DRC off (its 7,817 errors in run 1 were all SRAM-internal) |
| std-cell area / utilisation | 121,313 um^2 / 13.4% | 11,939 um^2 / 1.35%, plus 15,240 um^2 SRAM macro |
| of which logic / repair buffers / clock | 94,024 / 24,447 (1,866, of which 1,202 hold) / 2,814 um^2 | 8,444 / 2,894 (202, of which 154 hold) / 601 um^2 |
| flops | 1,121 | 81 |
| setup WNS typ / slow / fast (ns) | 12.75 / 8.52 / 15.20 | 14.24 / 10.72 / 15.29 |
| hold WNS (ns, worst corner) | 0.110 | 0.126 |
| max slew / max cap violations | 0 / 0 | 0 / **1** (A_DOUT[5], 0.065-0.069 pF vs 0.064 pF; post-GRT repair queued for run 4) |
| max fanout violations | 70, all CTS leaf buffers | 5 |
| IR drop worst | 0.154 mV | 0.195 mV (no stripes over x 54-279 um, see section 3) |
| power, default activity (*estimate quality*) | 4.0 mW | 0.43 mW |
| lint warnings (non-fatal) | 7 | 12 |
| summed step runtime | 53 min | 6.8 min |
| CI runs needed to reach green | 1 | 3 (Magic DRC on SRAM; SRAM pin overload with N orientation; TT full-height power-pin rule) |

## 2. Verification chain per variant

- Flop core: spec ==(A1, zero-init) RTL ==(E4/E5) final SG13CMOS5L netlist. Every link is our own logic and proven by dprove with a negative control.
  Gate-level replay agrees independently, using the PDK's Verilog UDP models instead of liberty semantics.
- Macro core: spec ==(A1) pemu_core ==(E1) pemu_core_macro + IHP functional model ==(E5m) final netlist + IHP model.
  The SRAM enters every claim only as IHP's functional model; its silicon behaviour and timing are outside the proofs. Power delivery to it
  is covered by the step's C1-C4 property check, the GDS bar check (`flow/pdn/check_sram_bar_gds.py`), LVS and IR drop.
- Both: instruction memory has no reset, so power-up contents are arbitrary in either variant. The zero-init assumption (decision 2) is the same.

## 3. Deviations from the Tiny Tapeout template

- Both: `test/Makefile` GL branch adds `sg13cmos5l_udp.v` (template bug: the stdcell models need its UDPs; CI confirms it is needed and accepted).
- Macro only, in `src/config.json`:
  - MACROS; PDN grid changed (VPITCH 44.96, VSPACING 3.52, VOFFSET 6.15) and PDN_OBSTRUCTIONS on 4 stripe pairs;
  - custom PDN_CFG plus the `Pemu.MacroColumnStripes` plugin (about 600 lines + 21 tests);
  - ERROR_ON_PDN_VIOLATIONS 0, ERROR_ON_ILLEGAL_OVERLAPS 0 (6 overlaps, all at GDS-verified bar crossings);
  - RUN_MAGIC_DRC 0 / RUN_KLAYOUT_DRC 1; RUN_POST_GRT_DESIGN_REPAIR 1 (run 4).
  - Several of these values sit in the template's "do not change" section.

## 4. Decision 5 options brief (no choice made)

| | (a) flop-memory core | (b) IHP macro core |
|---|---|---|
| status | green, template-conformant except one Makefile line | green except 1 small max-cap item (fix queued); flow carries a custom plugin |
| area now | 13.4% of the 6x4 core | 3.0% incl. macro |
| area to grow imem (*estimate* from mapped cells) | about 50,000 um^2 of flops per 64 words, plus read mux and hold buffers; 256 words ~ 220,000 um^2 (~25% of 6x4) | 256x16 macro 28,127 um^2 LEF area; the PDN/stripe work must be redone for a new macro (different columns) |
| timing | 8.52 ns slack at slow; the 64:1 read mux is the long path | 10.72 ns slack at slow; DOUT pins are the electrical limit (weak driver, 0.064 pF) |
| verification | every link in the chain is our logic, proven | adds the SRAM-model link (E1) and a physical-integration property layer (C1-C4, GDS check) that is itself novel |
| flow risk (*estimate*) | low; standard template flow | the plugin depends on LibreLane internals (OdbpyStep, substituting_steps). The organisers allow re-hardening winners with a newer flow, which could break it; also 3 template-section changes |
| power (*estimate*) | ~4 mW, dominated by 1,121 clocked flops | ~0.4 mW (A_MEN tied high, so the SRAM is always enabled) |

## 5. Things the build path exposed that touch deferred decisions

- Decision 7 (COMBDLY): non-fatal under LibreLane defaults (`ERROR_ON_LINTER_WARNINGS` False); no action forced.
- Decision 2 (arbitrary initial memory): unchanged, and it applies to both variants (no-reset flops, SRAM power-up undefined).
- Decision 6 (halt output 0x00 as UART break): not touched by the build path.
- Organiser email (judging leads with flexibility): unaffected by decision 5 at the current ISA; it matters for how far imem and the ISA grow.

## 6. Go/no-go criterion C (silicon path) in log/slice_report.md

Now met for both variants: wrapper + core through the TT CMOS5L flow, precheck green, gate-level replay green, netlist equivalence proven.
Pads, chip-level timing and silicon remain unverifiable before the shuttle.
