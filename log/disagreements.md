# Disagreement log

Every mismatch between spec (S1), RTL, and monitors (S3) is recorded here before any fix. See isolation_rules.md.

| ID | Date | Check | Artifacts disagreeing | Counterexample (S2 trace path) | Triage | Fix commit |
|---|---|---|---|---|---|---|
| D1 | 2026-09-27 | formal a1_rom_d3 / a1_rom_d4 (pdr) | spec ROM variant (`Spec_circuit.create ~rom`, ignores load writes) vs RTL ROM SRAM model (`Sram.behavioural_rom`, kept write-through) | frame 6: two WSTB pulses load a word to address 0 while halted; the RTL's A_DOUT takes DIN by write-through, the spec keeps rom[0] | formal-only model inconsistency, not a design bug: the two ROM variants disagreed on whether load writes are visible. Resolved by making the ROM SRAM ignore writes entirely, matching the spec's ROM semantics. | 42c37b7 |
| D2 | 2026-10-18 | co-simulation `protocols_v1/test/test_spi.ml` (target clock-to-output sweep; controller MOSI-delay sweep) | SPI assumption contracts (`Library_v1.spi_ctl` A1, `spi_tgt` B6, committed 0481d6b before firmware) vs protocol meaning | controller lane, target peer tco = 20 and 24 cycles at P = 7: pushed bytes differ from the peer's bytes with no firing; target lane, controller peer MOSI delay >= 56 cycles at hp = 40: same | contract defect (assumption too weak), not a firmware or monitor bug. A1/B6 only forbade a change at the sampling step (and S+1), so a peer late by more than about one step delivered stale bits consistently; lane and monitor agree, so no fail, and no blame. Fix: data line constant from S_k - 1 until the next shifting edge (controller: S_k - 1 .. S_k + h - 1). Accepted timing range unchanged (tco <= 8 and MOSI delay <= 30 still clean); the silent cases now blame (B92, B62). | 9a73a1c |

Tool-flow defects (the checked model differed from the design; no design disagreement) are
listed in formal/README.md: init set after opt, alias-named init attributes, duplicate SRAM
names in replay, PDR traces taken as first failures, unbounded dprove, proc_rom with kept
registers, CEC result parsing.
