# Source-document change log

Every change to a frozen document in doc/ is recorded here. Frozen documents are the ISA, the interface and SRAM contracts, and the protocol documents. Each entry notes who approved the change.

| Version | Date | Change | Reason | Approved by |
|---|---|---|---|---|
| v0 | 2026-09-27 | Initial freeze: ISA (32-entry imem), interface, UART monitor document | Vertical slice | User; the open decisions were delegated to agent judgment |
| v0.1 | 2026-09-27 | Instruction memory depth 32 -> 64; `pc` 5 -> 6 bits; JMP/DJNZ target `arg[5:0]`; `load_addr` 6 bits; new `doc/sram_interface.md` (synchronous-read SRAM contract for RM_IHPSG13_1P_64x16_c2) | User chose SRAM-shaped instruction memory now (option B). 64 words is the smallest IHP single-port macro. The timing contract (ISA section 5) is unchanged | User |
