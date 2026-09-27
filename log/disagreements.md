# Disagreement log

Every mismatch between spec (S1), RTL, and monitors (S3) is recorded here before any fix. See isolation_rules.md.

| ID | Date | Check | Artifacts disagreeing | Counterexample (S2 trace path) | Triage | Fix commit |
|---|---|---|---|---|---|---|
| D1 | 2026-09-27 | formal a1_rom_d3 / a1_rom_d4 (pdr) | spec ROM variant (`Spec_circuit.create ~rom`, ignores load writes) vs RTL ROM SRAM model (`Sram.behavioural_rom`, kept write-through) | frame 6: two WSTB pulses load a word to address 0 while halted; the RTL's A_DOUT takes DIN by write-through, the spec keeps rom[0] | formal-only model inconsistency, not a design bug: the two ROM variants disagreed on whether load writes are visible. Resolved by making the ROM SRAM ignore writes entirely, matching the spec's ROM semantics. | 42c37b7 |

Tool-flow defects (the checked model differed from the design; no design disagreement) are
listed in formal/README.md: init set after opt, alias-named init attributes, duplicate SRAM
names in replay, PDR traces taken as first failures, unbounded dprove, proc_rom with kept
registers, CEC result parsing.
