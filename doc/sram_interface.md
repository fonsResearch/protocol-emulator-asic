# Instruction-memory SRAM interface (RTL-facing contract)

Status: APPROVED v0.1 (2026-09-27). This is read by the RTL context. The spec context does not need it, because the ISA timing contract is independent of how memory is built.

## Target macro

`RM_IHPSG13_1P_64x16_c2`: IHP single-port SRAM, 64 words x 16 bits, no BIST or byte mask. LEF footprint 236.80 x 64.36 um (15,240 um^2).

Source: IHP-Open-PDK at rev 2bbec755dc67ca3db0261c3d6163e15735d66710, `ihp-sg13g2/libs.ref/sg13g2_sram/`. `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram` is a symlink to that directory. Unmodified Verilog models (Apache-2.0, IHP PDK Authors) are vendored in `rtl/macros/RM_IHPSG13_1P_64x16_c2/`.

## Ports

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `A_CLK` | in | 1 | Clock; all operations on the rising edge |
| `A_MEN` | in | 1 | Memory enable. When 0, no read or write happens and `A_DOUT` holds |
| `A_WEN` | in | 1 | Write enable |
| `A_REN` | in | 1 | Read enable |
| `A_ADDR` | in | 6 | Address |
| `A_DIN` | in | 16 | Write data |
| `A_DLY` | in | 1 | Must be tied to 1 (the model stops simulation otherwise) |
| `A_DOUT` | out | 16 | Read data register output |

## Behaviour at each rising edge of `A_CLK`

This is the functional model, `SRAM_1P_behavioral`.

1. If `A_MEN` = 1 and `A_WEN` = 1: `mem[A_ADDR]` <- `A_DIN`. If `A_REN` = 1 as well, `A_DOUT` <- `A_DIN` (write-through); otherwise `A_DOUT` holds.
2. Otherwise, if `A_MEN` = 1 and `A_REN` = 1: `A_DOUT` <- `mem[A_ADDR]`.
3. Otherwise, `A_DOUT` holds its previous value.

Consequences for the RTL:

- **Read latency is one edge.** The address presented during cycle c gives `A_DOUT` valid during cycle c+1. To execute `imem[pc]` in cycle c+1 with no penalty, the RTL has to present the *next* `pc` as `A_ADDR` during cycle c.
- **Holding `A_DOUT` has two routes.** It can be held by deasserting `A_REN` or `A_MEN`, for example during WAIT. Alternatively, keep re-reading the same address; that also leaves `A_DOUT` unchanged, because nothing writes while running.
- **Initial contents are undefined.** `A_DOUT` is X after power-up until the first read. The core must not execute before a read has completed. The halted cycles with `running` = 0, plus the reset of `pc` to 0, give room to issue the read of address 0 before the first running cycle. The RTL has to show this explicitly.
- **Program load uses the same single port while halted.** A write needs `A_MEN` = 1 and `A_WEN` = 1. Use `A_REN` = 0 during writes, unless write-through is deliberately wanted.

## Modelling rules

- **Hardcaml cyclesim and formal:** the RTL instantiates the macro through a Hardcaml module with exactly the ports above. Two implementations of that module exist:
  1. **Behavioural model** in Hardcaml: a register array implementing the three rules above. It is used in cyclesim and in formal, where memory contents are symbolic or loaded.
  2. **Macro instantiation**, a black box for synthesis, bound to `RM_IHPSG13_1P_64x16_c2`.
- **Obligation:** the Hardcaml behavioural model must be checked against the vendored PDK Verilog model (FUNCTIONAL define) by simulation, and preferably by a formal equivalence check on the functional model. Until then, any claim about the macro path rests on the behavioural model alone.
- **Out of scope for functional verification:** timing checks in the non-FUNCTIONAL model (`specify` blocks). Setup and hold at the macro are an STA obligation.
