# rtl (synthesizable core)

This is the Hardcaml implementation of ISA v0.1, interface v0.1 and the SRAM contract (`doc/sram_interface.md`).

Independence note: written in the same context as the spec. See `isolation_rules.md`.

| File | Contents |
|---|---|
| `src/engine.ml` | `pemu_core`: synchronisers, program-load logic, fetch/execute, parameterised by the SRAM implementation |
| `src/sram.ml` | RM_IHPSG13_1P_64x16_c2 port list; `behavioural` (Hardcaml registers, words named `rtl_imem_<i>`) and `blackbox` (macro instance `u_imem`) |
| `bin/generate.ml` | Writes `src/pemu_core.v` (behavioural) and `src/pemu_core_macro.v` (macro) |
| `bin/dump_vectors.ml`, `macro_sim/` | Spec-derived vectors replayed through the emitted Verilog with Icarus, including the IHP model |
| `test/` | Cyclesim expect tests, waveform, halt/restart, and a cross-check against the spec interpreter |
| `macros/` | Unmodified IHP-Open-PDK Verilog models (Apache-2.0) |

## Microarchitecture: meeting the timing contract with a synchronous-read SRAM

- **Running cycles.** The SRAM address is `next_pc`, the combinationally computed pc of the next cycle, with REN=1. `A_DOUT` in the next cycle is therefore the instruction for that cycle. Every instruction takes 1 cycle (WAIT takes k+1), and taken branches cost nothing, as ISA section 5 requires.
- **WAIT.** `next_pc = pc`, so the same word is re-read and `A_DOUT` is unchanged.
- **Halted and reset cycles.** The SRAM reads address 0 every cycle, so the first running cycle sees `imem[0]`. A program-load write occupies the single port:
  - A write to address 0 uses write-through, so `A_DOUT` gets the new `imem[0]`.
  - A write elsewhere holds `A_DOUT`, which still has `imem[0]` from an earlier read.
  - This is sound for two reasons: write events cannot occur in consecutive cycles, and `load_addr` is 0 in the first halted cycle after running. Both the halt/restart test and the random cross-check exercise it.
- **Critical path (estimate, not yet measured by STA).** SRAM `A_DOUT` goes through opcode decode, the DJNZ `lc-1 != 0` compare and the next-pc mux, and ends at the SRAM `A_ADDR` setup. That path includes the macro's clock-to-output and address setup times, which come from the macro's Liberty file (not yet checked).

## Reset

`rst_sync_n` comes from the wrapper's 2-flop synchroniser (asynchronous assert, synchronous release). The core uses it as a **synchronous clear**. Consequences:
- The pins are undefined from power-up until the first clock edge with reset low.
- Every core flop is a plain D flop with clear logic, so the sg13cmos5l library's missing async-set-only flop never matters.
- The SRAM contents and `A_DOUT` are not reset.

## Verilog-conversion and synthesis concerns

1. **COMBDLY.** Hardcaml emits wide muxes as `always @*` blocks with `<=` (see `LINT.md`). Functionally fine; it is a style warning.
2. **Uninitialised state in formal.** SRAM words and `A_DOUT` have no reset. Proofs must start from a reset sequence, with explicit assumptions about memory contents.
3. **SRAM X before first read.** In silicon, `A_DOUT` is X until the first read. This is covered by the at-least-2 halted cycles after reset (synchroniser latency) during which address 0 is read.
4. **Macro timing.** In the macro's non-FUNCTIONAL model, setup and hold on `A_ADDR`, `A_WEN` and `A_REN` are STA obligations. The next-pc-to-`A_ADDR` path is the likely critical path.
5. **Area.** The behavioural variant (`pemu_core.v`) implements 1024 memory bits as flip-flops. It is for simulation and formal only; the taped-out variant must be `pemu_core_macro.v`. That variant is not yet wired into the TT wrapper or `info.yaml`.
6. **Naming.** Hardcaml auto-names internal wires `_NNN`, so the names change between generator runs. Formal harnesses must reference only named signals (`pc`, `running`, `rtl_imem_<i>`, and so on).

## Test results (at commit time)

- UART D=4 matches the spec interpreter cycle for cycle.
- Halt/restart, including a single-cycle RUN drop, matches.
- Random cross-check vs the spec interpreter: 300 programs, more than 475k cycles, 0 mismatches.
- Icarus replay of both Verilog variants: 0 errors (see `LINT.md`).
