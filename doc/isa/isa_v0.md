# ISA v0 (vertical-slice ISA)

Status: DRAFT, awaiting user approval. Nothing in spec/ or rtl/ may be written against this document until it is approved.

Scope: the smallest ISA that can:
- transmit UART 8N1 at any integer bit period of 3 cycles or more,
- support one timing-preserving program transform (timed QED),
- sample one input byte.

It is not the competition ISA. Every item in section 8 is an open decision; the values used in the body are the proposals.

This document, together with `doc/interface.md`, is the only source for the spec (S1) and RTL contexts. It is written so that two implementers working separately produce machines with identical pin traces, cycle for cycle.

## 1. Time base and notation

- `clk` rising edges are numbered e_0, e_1, e_2, and so on.
- Cycle c is the interval from edge e_c to edge e_{c+1}.
- A register has value v during cycle c if v was written at edge e_c.
- An instruction that "executes in cycle c" has its state updates written at edge e_{c+1}, so they are visible during cycle c+1. For a multi-cycle instruction, c is its last cycle.
- Pins are driven directly from architectural registers, with no extra output flop. A pin effect of an instruction executing in cycle c is visible on the pin during cycle c+1.

## 2. Architectural state

| Name | Width | Reset value | Description |
|---|---|---|---|
| `pc` | 5 | 0 | Program counter (32-entry instruction memory) |
| `out` | 8 | 0x00 | Output register; drives `uo_out[7:0]` |
| `sr` | 8 | 0x00 | Shift register |
| `lc` | 8 | 0x00 | Loop counter |
| `imem[0..31]` | 16 each | undefined | Instruction memory; not cleared by reset |
| `running` | 1 | 0 | Execution enable, derived from the RUN pin (see `doc/interface.md`) |

A WAIT in progress also has hidden state (cycles remaining). Only its observable effect is specified.

All arithmetic is modulo 2^width of the destination, so `pc` increments modulo 32.

## 3. Execution model

- The machine is single-issue and in order.
- The number of cycles an instruction takes never depends on data or input values.
- A cycle with `running` = 0 is a **halted** cycle. At the end of it: `pc` <- 0, `out` <- 0, `sr` <- 0, `lc` <- 0, and any WAIT in progress is cancelled. `imem` is unchanged.
- In a cycle with `running` = 1 and no WAIT in progress, the machine starts executing `imem[pc]`.
- The first cycle with `running` = 1 after one or more halted cycles starts `imem[0]`.

## 4. Instruction encoding

Instructions are 16-bit words: `op = w[15:12]`, `arg = w[11:0]`. Bits marked "must be 0" are ignored by the machine, so behaviour never depends on them. Assemblers must emit 0 there.

| op | Mnemonic | Operand | Cycles | Effect, written at the end of the instruction's last cycle |
|---|---|---|---|---|
| 0x0 | `JMP t` | `t = arg[4:0]`; `arg[11:5]` must be 0 | 1 | `pc` <- t |
| 0x1 | `OUT v` | `v = arg[7:0]`; `arg[11:8]` must be 0 | 1 | `out` <- v; `pc` <- pc+1 |
| 0x2 | `OUTB p` | `p = arg[2:0]`; `arg[11:3]` must be 0 | 1 | `out[p]` <- `sr[0]`, other bits of `out` unchanged; `sr` <- `sr >> 1` (logical shift, 0 in); `pc` <- pc+1 |
| 0x3 | `LDI v` | `v = arg[7:0]`; `arg[11:8]` must be 0 | 1 | `sr` <- v; `pc` <- pc+1 |
| 0x4 | `IN` | `arg` must be 0 | 1 | `sr` <- sampled `uio_in` (`doc/interface.md` section 4); `pc` <- pc+1 |
| 0x5 | `WAIT k` | `k = arg[11:0]`, 0..4095 | k+1 | No architectural change until the end of the last cycle, then `pc` <- pc+1 |
| 0x6 | `LDC v` | `v = arg[7:0]`; `arg[11:8]` must be 0 | 1 | `lc` <- v; `pc` <- pc+1 |
| 0x7 | `DJNZ t` | `t = arg[4:0]`; `arg[11:5]` must be 0 | 1 | `lc` <- lc-1; if (lc-1) != 0 then `pc` <- t, else `pc` <- pc+1 |
| 0x8-0xF | reserved | ignored | 1 | `pc` <- pc+1 (behaves as NOP) |

Notes:
- The all-zero word is `JMP 0`, so an all-zero memory spins at address 0 with no pin activity.
- `LDC n` followed by a loop closed by DJNZ runs the body n times for n in 1..255, and 256 times for n = 0.
- Every instruction except WAIT takes exactly 1 cycle, and a taken branch costs nothing extra.
- `WAIT 0` behaves as a 1-cycle NOP.
- If `running` drops during a WAIT, the halt rule cancels the WAIT.

## 5. Timing contract (normative)

These are the properties the RTL must satisfy and is proven against (claim A1):

1. **Duration.** Every instruction occupies exactly the number of cycles in section 4, regardless of data and inputs.
2. **Output latency.** An `OUT` or `OUTB` executing in cycle c changes `uo_out` during cycle c+1, not earlier.
3. **Output stability.** `uo_out` changes only at the edge ending a cycle in which an `OUT` or `OUTB` executes, or the edge ending a halted cycle, where it becomes 0.
4. **Input latency.** An `IN` executing in cycle c loads the `uio_in` value sampled at edge e_{c-1} (`doc/interface.md` section 4).

## 6. Reference program: UART 8N1 transmit

Bit period D cycles, D >= 3. TX is `uo_out[0]`, idle high. Other `uo_out` bits stay 0.

```
 0: OUT  0x01     ; idle high
 1: IN            ; sr <- byte to send
 2: LDC  8
 3: OUT  0x00     ; start bit; executes in cycle s, pin low from s+1
 4: WAIT D-2      ; cycles s+1 .. s+D-1
 5: OUTB 0        ; executes in cycle s+D; start bit lasted D cycles
 6: WAIT D-3      ; D-2 cycles
 7: DJNZ 5        ; 1 cycle; next OUTB exactly D cycles after the previous one
 8: OUT  0x01     ; stop bit, exactly D cycles after the last OUTB
 9: WAIT D-2      ; D-1 cycles
10: JMP  1        ; then IN, LDC: stop/idle lasts D+3 cycles before the next start bit
```

Resulting pin timeline:

| Segment | Duration |
|---|---|
| Start bit | D cycles |
| Each data bit, LSB first | D cycles |
| Stop bit plus inter-frame idle | D + 3 cycles (>= 1 bit period) |

Known-bad variant, kept as a negative test for the UART monitor: swap lines 2 and 3 (LDC after the start bit). The start bit then lasts D+1 cycles.

## 7. Timed-QED transform used in the slice

Transform T replaces the counted loop at addresses 5-7 (`OUTB 0; WAIT D-3; DJNZ 5`, executed 8 times) with 8 unrolled copies of `OUTB 0; WAIT D-2`. All other lines are unchanged, including `LDC 8`, which is now dead.

Timing argument: each unrolled copy takes 1 + (D-1) = D cycles. A loop iteration takes 1 + (D-2) + 1 = D cycles.

Claim checked on the RTL alone, with no spec involved: for every `uio_in` input sequence, program P and program T(P) produce identical `uo_out` traces, cycle for cycle. T(P) needs 5 + 16 + 3 = 24 words, which is why the slice memory has 32 entries.

## 8. Open decisions (proposal shown in the body)

1. **Instruction memory depth.** 32 entries (proposed; needed for T(P) in section 7), or 16 entries with a 4-iteration QED variant.
2. **Reserved opcodes.** NOP (proposed; fully specified, so formal completeness stays simple), or trap.
3. **`out` reset/halt value.** 0x00 (proposed). A UART receiver on `uo_out[0]` sees this as a break condition while the machine is halted; 0xFF, or a separately programmable halt value, avoids that.
4. **Memory timing.** v0 assumes combinational instruction read (flip-flop memory). A later synchronous-read SRAM must preserve section 5, for example with prefetch. That is an RTL obligation and does not change the ISA.
