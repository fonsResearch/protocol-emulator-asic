# ISA v1 (driver lanes)

Status: FROZEN v1 (2026-10-17). The user delegated approval to the agent; it was frozen after a consistency review (USB fixes in section 6, see `doc/CHANGES.md`). Changes go through `doc/CHANGES.md`. Architecture decisions: `doc/decisions/arch_v1_options.md`. Pin and host interface: `doc/interface_v1.md`.

This document and `doc/interface_v1.md` are the only sources for the spec (S1) and RTL contexts. They are written so that two implementers working separately produce identical pin traces, cycle for cycle.

Design choices made in this draft within the decided architecture are marked **[choice]**. They are open to change before freeze.

## 1. Time base

- Clock edges e_0, e_1, ...; cycle c runs from e_c to e_{c+1} (as in v0.1).
- **Ticks.** Each lane L has a prescaler with divisor P_L (16 bits, host-set, sampled while the lane is halted). The lane's tick is 1 in cycle c when its prescaler counter equals P_L; the counter then returns to 0. Consecutive ticks are exactly P_L + 1 cycles apart. The first tick after the lane starts running is in the cycle the counter first reaches P_L, counting from 0 at the start of running.
- **Lane steps.** A lane's architectural state changes only at the end of a cycle in which its tick is 1. Such a cycle is a *step* of the lane. Every timing statement below is in steps.
- Input synchronisers run every cycle (`doc/interface_v1.md` section 3). In a step, the lane reads the synchronised values of that cycle.
- An instruction "executes in step s" when its state updates are written at the end of step s. A pin effect of a step-s instruction is visible from the cycle after step s.

## 2. Architectural state (per lane; two lanes, L0 and L1)

| name | width | reset | written by | description |
|---|---|---|---|---|
| `pc` | 8 | 0 | lane | program counter (256-word instruction memory) |
| `out` | 8 | 0 | lane | drive values for uio pins |
| `oe` | 8 | 0 | lane | drive enables for uio pins (push-pull pins only) |
| `xo` | 2 | 0 | lane | the lane's two spare push-pull outputs (interface section 2) |
| `sr` | 8 | 0 | lane | shift register |
| `lc` | 8 | 0 | lane | loop counter |
| `r0`..`r3` | 8 each | 0 | lane | general registers |
| `to` | 12 | 0 | lane | timeout for blocking instructions, in steps |
| `Z`, `T` | 1 each | 0 | lane | compare-equal flag; timeout flag |
| wait state | hidden | - | lane | remaining WAIT or blocking-instruction count |
| serializer | see section 6 | 0 | lane | byte serializer with line coding |
| `own`, `od`, `P`, `len`, `cfg` | see interface | - | host only | ownership mask, open-drain mask, divisor, program length, configuration |
| `imem[0..255]` | 16 | undefined | host only | instruction memory (SRAM macro, not cleared by reset) |

All arithmetic is modulo 2^width.

## 3. Execution model

1. **Running.** A lane runs in a step when all of the following hold:
   - the host's RUN bit for the lane is 1 (synchronised);
   - the lane's `loaded` flag is set: a program of `len` words has been written since the last reset, interface section 5 (the **load gate**, decision V4);
   - the lane is not faulted.
   Otherwise the lane is halted.
2. **Halted step.** At the end of a halted step: `pc`, `out`, `oe`, `xo`, `sr`, `lc`, `r0`..`r3`, `to`, `Z`, `T`, the wait state and the serializer return to reset values.
   - `oe` = 0 means a halted lane drives nothing: pins idle at their pull-ups.
   - On open-drain pins, `out` = 0 with `od` = 1 is defined as "released" (section 4), so a halted lane releases them too.
3. **Fetch bound.** If a running lane's `pc` ≥ `len` at the start of a step, the lane faults with cause `FETCH_BOUND` instead of executing (decision V4). A faulted lane is halted until the host clears the fault.
4. **One instruction per step.** WAIT and the blocking instructions occupy several steps (section 5). The number of steps an instruction takes depends only on its operands, the lane state, and the synchronised inputs and FIFO states it waits on. Section 5 defines the exact count for every instruction.
5. **Blame release (decision V1).** If the lane's `cfg.release_on_blame` bit is set and the monitor engine reports a blame attributed to this lane, the lane faults with cause `BLAME` at the end of that cycle's step (or of the next step if that cycle is not a step).

## 4. Pins

- A lane affects uio pin i only if `own[i]` = 1. The host keeps the two lanes' masks disjoint; the interface rejects overlapping writes.
- For an owned pin i:
  - push-pull (`od[i]` = 0): `uio_out[i]` = `out[i]`, `uio_oe[i]` = `oe[i]`;
  - open-drain (`od[i]` = 1): `uio_out[i]` = 0, `uio_oe[i]` = NOT `out[i]`. Writing 1 releases the pin, writing 0 pulls it low; `oe[i]` is ignored.
- Unowned pins: `uio_oe[i]` = 0.
- **Pair mode** (USB, `cfg.pair` set): owned pins `pair_base` and `pair_base`+1 are D+ and D-, driven by the serializer (section 6) whenever it is active; otherwise by `out`/`oe` as above.
- Input pins: `pin(i)` denotes the synchronised value of `uio_in[i]` in the current step's cycle, whether or not the pin is owned.

## 5. Instructions (16 bits: op = w[15:12], arg = w[11:0])

Fields that are not used must be 0. The machine ignores them; assemblers emit 0.

| op | mnemonic | operands | steps | effect at the end of the last step |
|---|---|---|---|---|
| 0x0 | `JMP t` | t = arg[7:0] | 1 | pc <- t |
| 0x1 | `BR c, t` | c = arg[11:8], t = arg[7:0] | 1 | if cond(c) then pc <- t else pc <- pc+1 (conditions below) |
| 0x2 | `OUT v` | v = arg[7:0] | 1 | out <- v; pc+1 |
| 0x3 | `OEN v` | v = arg[7:0] | 1 | oe <- v; pc+1 |
| 0x4 | `PIN p, a` | p = arg[2:0], a = arg[5:4] | 1 | a=0: out[p] <- sr[0], sr <- sr >> 1 (LSB first out). a=1: out[p] <- sr[7], sr <- sr << 1 (MSB first out). a=2: sr <- {pin(p), sr[7:1]} (LSB first in). a=3: sr <- {sr[6:0], pin(p)} (MSB first in); pc+1 |
| 0x5 | `WAIT k` | k = arg[11:0] | k+1 | pc+1 |
| 0x6 | `WTP p, c` | p = arg[2:0], c = arg[5:4] | see below | wait for pin condition c on pin p: 0 = low, 1 = high, 2 = rising, 3 = falling. T <- timed out; pc+1 |
| 0x7 | `LDI d, v` | d = arg[10:8], v = arg[7:0] | 1 | d in {r0, r1, r2, r3, sr, lc, to_lo, xo}: d <- v (to_lo writes to[7:0] and clears to[11:8]; xo writes xo <- v[1:0]); pc+1 |
| 0x8 | `MOV d, s` | d = arg[10:8], s = arg[6:4] | 1 | d in {r0..r3, sr, lc, out, oe}; s in {r0..r3, sr, lc, pins, ser_status}: d <- s; pc+1 |
| 0x9 | `CMP s, v` | s = arg[10:8], v = arg[7:0] | 1 | s in {r0..r3, sr, lc, pins, -}: Z <- (s == v); pc+1 |
| 0xA | `ADDI d, v` | d = arg[10:8], v = arg[7:0] | 1 | d in {r0..r3, sr, lc}: d <- d + v; Z <- (result == 0); pc+1 |
| 0xB | `FIFO a, x` | a = arg[11:10], x = arg[2:0] | see below | a=0 `POP x`: x <- next byte of the host TX FIFO. a=1 `PUSH x`: append x to the host RX FIFO. x in {r0..r3, sr}. Blocking; T <- timed out; pc+1 |
| 0xC | `SER a, x` | a = arg[11:9], x = arg[2:0] | see section 6 | serializer operations |
| 0xD | `DJNZ t` | t = arg[7:0] | 1 | lc <- lc-1; if lc-1 ≠ 0 then pc <- t else pc+1 |
| 0xE | `SYS a` | a = arg[3:0] | 1 | 0 = NOP; 1 = HALT (lane stops: cause HALT, pins released); 2 = CLRT (T <- 0); 3..15 reserved (NOP); pc+1 except HALT |
| 0xF | reserved | | 1 | NOP; pc+1 |

**Conditions for `BR`** (c):
- 0: always
- 1: Z
- 2: not Z
- 3: T
- 4: not T
- 5: TX FIFO empty
- 6: TX FIFO not empty
- 7: RX FIFO full
- 8: serializer ready
- 9: serializer busy
- 10: lc ≠ 0
- 11-15: reserved, never taken

**Blocking instructions** (`WTP`, `POP` on an empty FIFO, `PUSH` on a full FIFO, `SER` while busy, section 6):
- The instruction's first step evaluates its condition. If the condition holds, the instruction completes in that step: duration 1, T <- 0.
- Otherwise it completes in the first later step where the condition holds (T <- 0), or after `to` steps without it (T <- 1, and for POP and PUSH no data is moved).
- `to` = 0 means no timeout. This is the only unbounded wait, and contracts must cover it (language section 7).
- `WTP` rising/falling compare the pin's value in this step with its value in the lane's previous step.

## 6. Serializer (transmit; decision on line coding)

State:
- `shift[8]`, `bitcnt[4]`;
- `bit_period` (in steps, 8 bits, loaded by `SER PERIOD`), `bit_timer`;
- `nrzi_level`, `ones[3]`, `crc[16]`;
- mode bits from `cfg`: msb_first, nrzi, stuff, crc_en, crc16 (else crc5), pair.

Operations (`SER a, x`):

| a | name | effect |
|---|---|---|
| 0 | `SEND x` | blocking until ready. Load the byte from x; the serializer emits 8 bits, one per bit period, LSB or MSB first (`cfg.msb_first`). With nrzi: a 0 bit toggles the line level, a 1 bit keeps it. With stuff: after six consecutive 1 bits (counted after any previous stuffed bit), a 0 bit is inserted and NRZI-coded like any other bit. Does not update `crc` (for SYNC and PID) |
| 1 | `CRCI` | crc <- all ones |
| 2 | `CRCS` | blocking until ready. Send the ones complement of `crc` (5 or 16 bits), most significant bit first regardless of `cfg.msb_first` (USB 2.0 section 8.3.5), through the same stuffing and NRZI coding |
| 3 | `EOP` | blocking until ready. Drive SE0 (both pair pins low) for 2 bit periods, then J for 1 bit period, then idle (ready) |
| 4 | `PERIOD x` | bit_period <- x |
| 5 | `IDLE` | blocking until ready (all bits sent) |
| 6 | `SENDC x` | as `SEND x`, and with `cfg.crc_en` each data bit (never a stuffed bit) updates `crc`: CRC16 x^16+x^15+x^2+1 or CRC5 x^5+x^2+1, data in transmission order |
| 7 | reserved | NOP |

Line value of a bit: push-pull on owned pin `cfg.ser_pin`, or a J/K pair in pair mode. Low-speed polarity: J = D+ low, D- high; K = D+ high, D- low; idle is J; SE0 = both low. Coding order per USB 2.0: CRC over data bits, then bit stuffing, then NRZI.

Coding state reset: `nrzi_level` <- J and `ones` <- 0 at the end of every `EOP` and whenever the lane is halted.

Ready means the serializer is not shifting and has no pending bit. `ser_status` = {busy, crc_ok placeholder 0, bitcnt}.

## 7. Timing contract (normative; claim A1)

1. **Duration.** Every instruction occupies exactly the steps given in section 5.
2. **Output latency.** An instruction executing in step s changes pins from the cycle after step s, and serializer outputs change only at bit-period boundaries counted in steps.
3. **Output stability.** Pin outputs change only at the end of steps.
4. **Input latency.** A lane reading a pin in step s reads the pad value sampled at edge e_{s-1}, through the 2-flop synchroniser.
5. **Lane independence.** Neither lane's architectural state depends on the other lane's state, except through pins it reads. Owned outputs are disjoint.

## 8. Reference programs (to be written at plan step 7)

UART TX/RX, SPI controller/target modes 0-3, I2C controller/target, USB-LS TX. Each comes with a guarantee and assumption contract in `doc/contracts/`.

## 9. Open points inside this draft (for review)

1. **Divisor width.** 16 bits [choice]. At 60 MHz, 9,600 baud is 6,250 cycles per bit: d = 10, P = 624.
2. **Rate error.** Rates are d x (P+1) cycles; 115,200 baud at 60 MHz is 520.8 cycles, so the nearest is 520 = 8 x 65 (+0.16%). There is no fractional divider in v1 (decision A4).
3. **CRC5 vs CRC16 coverage.** USB tokens (CRC5) are sent by hosts, not devices, so a USB-LS device TX needs only CRC16 for data packets. CRC5 is kept for host-emulation demos [choice].
4. **No ALU beyond ADDI/CMP** [choice]. Checksums other than CRC are not supported in hardware.

## 10. Clarifications v1.0.1 (normative)

No encoding changes. These points resolve ambiguities found while writing the executable lane specification (`spec_v1/`). Where this section and an earlier section differ, this section governs. `spec_v1/src/lane_model.ml` (reference interpreter) and `spec_v1/src/lane_circuit.ml` (spec-as-circuit) implement exactly these semantics. `spec_v1/test` checks them against each other.

1. **Open-drain polarity** (v1.0.2, user decision; replaces the v1.0.1 wording). For an owned pin with `od[i]` = 1: `uio_out[i]` = 0, `uio_oe[i]` = NOT `out[i]`. Writing 1 releases the pin and writing 0 pulls it low, as section 4 states; section 3.2's remark about `out` = 0 releasing is withdrawn. While a lane is not live it drives nothing (item 2). From its first step on, a program must set the open-drain pins it owns to 1 unless it means to pull them low. Package assumption contracts and the assembler lint check this.
2. **Live gating.** A lane drives its owned pins only if it executed in its most recent step (`live`). Otherwise `uio_oe` = 0 on all of its pins, whatever `od` is. A lane that faults in step s drives nothing from the cycle after step s.
3. **Faults.**
   - A fault raised in a step (`FETCH_BOUND`, `HALT`, `BLAME`) resets the execution state at the end of that step.
   - A `BLAME` step does not execute its instruction.
   - Blame with `cfg.release_on_blame` is latched until a running step consumes it. A blame latched while the lane is halted makes the lane fault at its first running step.
   - Host `clear_fault` clears the fault, the cause and the blame latch. It wins over a blame arriving in the same cycle, and loses to a fault raised by a step in the same cycle.
4. **Blocking instructions** (WTP, POP, PUSH, SER SEND/SENDC/CRCS/EOP/IDLE).
   - The first step evaluates the condition. On success the action happens in that step and `T` <- 0.
   - If the condition is false with `to` = 0, the lane waits indefinitely.
   - If the condition is false with `to` != 0, the instruction times out at step `to`+1: `T` <- 1, no action, `pc` advances.
   - `to` is 8 bits in v1 (LDI `to_lo`).
5. **Serializer ready.**
   - Ready includes the step in which the last bit of the current item ends: data bit, pending stuffed bit, or the J of an EOP. Consecutive SEND/SENDC/CRCS/EOP are therefore contiguous on the line.
   - The shift register is 16 bits wide (CRCS with CRC16).
   - `ser_status` (MOV source 7) = {7'b0, busy}. Both it and BR condition 9 read busy after this step's serializer advance. BR condition 8 (ready) is evaluated before it.
6. **Stuffing count.** The count of consecutive ones carries across byte boundaries, from SEND (SYNC, PID) into SENDC bytes and into CRCS. It resets at the end of EOP and on halt. This matches USB, where stuffing applies from the SYNC field on.
7. **FIFOs** (depth 8, per lane, host TX/RX).
   - The lane pops or pushes only in executing steps. The host side acts every cycle.
   - A host push is accepted only if the level at the start of the cycle is below 8. A push to a full FIFO is dropped, even if the lane pops in the same cycle.
   - A lane pop never sees a byte pushed by the host in the same cycle. A host pop removes the head present at the start of the cycle.
   - Reset empties both FIFOs.
8. **Register operands 6, 7** in POP/PUSH/SER select `r0`. The assembler rejects them, and the load gate (decision V4) may reject them in a later revision.
9. **Reset.** While `rst_sync_n` = 0, nothing executes and no stream event is reported. Outputs reflect the state at the start of the cycle.
10. **Program length.** `len` is 8 bits, so a program is at most 255 words, and word 255 is never fetched.

## 11. Clarifications v1.0.2 (normative, user decisions 2026-10-17)

1. **Halted cycles** (replaces "halted step" in section 3.2). At the end of every cycle in which the lane is not running (section 3.1), the execution state returns to reset values and `live` <- 0. This happens whether or not the cycle is a tick, so a lane that stops releases its pins from the next cycle. A step that raises a fault does the same (section 10, item 3). Not affected: the FIFOs, the fault flag and cause, and the blame latch.
2. **Prescaler while halted.** The prescaler counter is held at 0 in every cycle in which the lane is not running. Ticks occur only while running, and the first tick after running starts comes in the cycle when the counter first equals P (P = 0: the first running cycle). Section 1 reads this way.
3. **Fetch** (RTL, informative). The instruction memory is read with next-pc addressing, so the timing contract (section 7) holds with P = 0. Because of item 1, `pc` = 0 throughout every halted interval, including program loads.
4. **Open-drain polarity**: section 10, item 1, as amended.
