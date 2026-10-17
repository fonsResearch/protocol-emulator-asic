# Source-document change log

Every change to a frozen document in doc/ is recorded here. Frozen documents are the ISA, the interface and SRAM contracts, and the protocol documents. Each entry notes who approved the change.

| Version | Date | Change | Reason | Approved by |
|---|---|---|---|---|
| v0 | 2026-09-27 | Initial freeze: ISA (32-entry imem), interface, UART monitor document | Vertical slice | User; the open decisions were delegated to agent judgment |
| v0.1 | 2026-09-27 | Instruction memory depth 32 -> 64; `pc` 5 -> 6 bits; JMP/DJNZ target `arg[5:0]`; `load_addr` 6 bits; new `doc/sram_interface.md` (synchronous-read SRAM contract for RM_IHPSG13_1P_64x16_c2) | User chose SRAM-shaped instruction memory now (option B). 64 words is the smallest IHP single-port macro. The timing contract (ISA section 5) is unchanged | User |
| v1 | 2026-10-17 | New frozen documents: `doc/isa/isa_v1.md` (two lanes, tick steps, load gate, blocking instructions, byte serializer), `doc/interface_v1.md` (pin map, host SPI port, register map; monitor registers reserved for v1.1), `doc/contracts/language_v1.md` (tick time base, require-when, delayed observables, guarded branch, FIFO streams). Pre-freeze review fixes: low-speed J/K polarity (J = D- high), CRC field sent MSb first and inverted, SENDC separates CRC-covered data from SYNC/PID, coding state reset after EOP. v0/v0.1 documents stay for the slice | Architecture decisions in `doc/decisions/arch_v1_options.md` | User delegated approval to the agent |
