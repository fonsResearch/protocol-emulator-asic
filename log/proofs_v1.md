# Driver lane RTL v1: verification results (plan step 5), 2026-10-17

Design: `rtl_v1/src/lane_rtl.ml`, `sram256.ml` and `prescaler16.ml`. Specification: `spec_v1/` (ISA v1 with clarifications v1.0.1 and v1.0.2). Engine: ABC dprove via `formal/prove_one.sh`. Counterexamples come from bmc3 and are replayed in cyclesim. Wall times are from this machine (11 cores, 18 GiB).

## RTL structure (facts)

- **Fetch.** Next-pc addressing of RM_IHPSG13_1P_256x16_c2_bm_bist (user decision). A_DOUT is the executing instruction, and P = 0 is allowed.
- **Program writes.** A write is accepted (`imem_wack`) only if the lane was not running in this cycle or the previous one. The SRAM does write-through exactly when the written address is the fetch address. Since `pc` = 0 in every non-running cycle (v1.0.2), A_DOUT = imem[pc] in every running cycle.
- **SRAM tie-offs.** A_DLY = 1, A_MEN = 1, A_BM = all ones, A_BIST_* = 0. A_BIST_EN = 0 also selects A_CLK in the macro's internal clock multiplexer.
- **Reset and clocking.** Synchronous clear on rst_sync_n for everything except the SRAM words and A_DOUT. One clock domain, no asynchronous set or reset.

## Simulation (cyclesim, `rtl_v1/test`)

- **Differential test.** 300 programs × 2,000 cycles = 600,000 cycles, RTL vs Lane_model. Every program enters through the write port. Random writes continue during the run phase (half of them to address 0), and each acknowledged write updates the model's memory. **0 mismatches.** All coverage counters were hit: acknowledged and refused writes, serializer, POP/PUSH, each fault cause.
- **Directed test.** Word 0 is rewritten in the last halted cycle; the first executed instruction is the new word.
- **RTL mutants (cyclesim):** 11/11 detected.

| mutant | mismatching cycles |
|---|---|
| no previous-cycle write gate | 4,063 |
| no write-through | 377, plus the directed test |
| fetch address = pc | 291,733 |
| stuffing after 5 ones | 36,666 |
| one SE0 in EOP | 131,152 |
| CRC5 alignment | 16,078 |
| ser_status = busy before advance | 57 |
| FIFO full at 7 | 588,040 |
| early timeout | 4,041 |
| open-drain oe from oe | 126,801 |
| blame latch over clear | 1,930 |

  The write-through mutant survived (0 mismatches) until the address-0 write bias and the directed test were added.
- **Waveform.** `test_rtl_waves.ml`: UART TX 0xA5 on the RTL (d = 3, tick every cycle).

## A1 for the lane (`formal/src/a1_lane.ml`)

Every lane input, including the write port, is free in every cycle. Environment assumption (PH6): reset is asserted in frame 0.

| harness | expected | result | depth | latches | wall s |
|---|---|---|---|---|---|
| a1_lane_full (monolithic, shared 256×16 array) | PASS | TIMEOUT | - | 4,760 | 3,600 |
| a1_lane_fetch (L1) | PASS | PASS | - | 258 | 0-1 |
| a1_lane_fetch_nowt_neg | FAIL | FAIL, replay ok | 2 | 258 | 0 |
| a1_lane_fetch_gate_neg | FAIL | FAIL, replay ok | 3 | 257 | 0 |
| a1_lane_dp (L2) | PASS | PASS | - | 673 | 89 |
| a1_lane_dp_timeout_neg | FAIL | FAIL, replay ok | 4 | 673 | 4 |
| a1_lane_spec_indep (L3) | PASS | PASS | - | 645 | 1 |
| a1_lane_spec_indep_neg | FAIL | FAIL, replay ok | 1 | 645 | 0 |

**Decomposition.**
- **L1 (fetch, RTL only).** Ghost registers follow the SRAM rules: the address of the word held in A_DOUT, and whether it is fresh (no write to it since it was read). Property: in every running cycle, the word is fresh and its address equals `pc`.
- **L2 (datapath).** The SRAM is abstracted to free read data. One constraint applies: re-reading the held address with no write since returns the held word. The spec executes A_DOUT; all observables must be equal.
- **L3 (spec only).** The specification's behaviour depends on its instruction word only in step cycles.

**Composition** (paper argument, two facts about SRAM semantics):
1. The real SRAM satisfies L2's read constraint.
2. If the held word is fresh, A_DOUT = mem[address].

Together with L1–L3, the RTL with the real SRAM is observably equal to the specification executing imem[pc].

**The first L2 attempt was too weak.** Without the read constraint, L2 failed at depth 3 (counterexample replayed). A lane waiting in a blocking instruction saw a different word at the same `pc`, which is unreachable in silicon. The constraint was added after that counterexample.

**Formal mutant check** (L1 and L2, 300 s each): 10/10 compiled mutants from the cyclesim list are killed.
- Fetch mutants fail L1; datapath mutants fail L2.
- `stuff5` (frame 14) and `fifo_full_7` (frame 75) are dprove FAILs with no bmc3 counterexample within 300 s, so they are not replayed.
- The text mutant without the previous-cycle gate did not compile (unused binding). It is covered by `a1_lane_fetch_gate_neg`.

**Open item.** The monolithic `a1_lane_full_nowt_neg` replays fine. On the first run, `a1_lane_gate_neg` failed at depth 3 with REPLAY MISMATCH: cyclesim saw `bad` at frame 2. The suspect is the replayer's alias choice for free-init bits with many aliases (up to 10) in the 4,096-bit array harness. Not yet resolved; the decomposed harnesses replay cleanly.

## Prescaler (`formal/src/presc16.ml`)

| harness | expected | result | depth | latches | wall s |
|---|---|---|---|---|---|
| presc16_lemma | PASS | PASS | - | 48 | 0 |
| presc16_lemma_neg (divisor 300 never ticks) | FAIL | FAIL, replay ok | 301 | 49 | 522 |

The lemma checks the counter against its definition: tick ⇔ gap = P, including hold-at-0 while halted and reset. It is not an independent oracle. A first version with a 17-bit saturating reference timed out at 900 s, because it needs the invariant cnt ≤ P.

## Synthesis (estimates)

Yosys 0.69 + ABC with sg13cmos5l_stdcell, macro as a black box (`rtl/macros/.../_bb.v`; ports checked against the model, 17/17):
- **Area.** 2,741 cells, 327 flip-flops, 38,276 µm² of standard cells per lane. With the 28,127 µm² macro this is about 66,400 µm² per lane. Two lanes are about 11% of the 8x4 core (1,208,173 µm²).
- **Delay, no wires.** Gate-level critical path 9.03 ns slow (1.08 V, 125 °C) and 5.47 ns typ. The fan-out cone of A_DOUT alone is 7.82 ns slow and 5.08 ns typ.
- **Fetch path.** Clock-to-DOUT (liberty: 5.13 ns slow, 3.06 ns typ) plus the cone gives at most 12.95 ns slow, against 16.67 ns at 60 MHz. Roughly 3.4 ns remain for wiring, skew and setup. Unverified until STA after place and route.
- **Hold.** A_ADDR hold up to 0.85 ns (slow) needs hold buffers on the next-pc path.

## Interface consequence (flagged, not yet in interface_v1.md)

The lane drops a program write in the first cycle after it stops running. The loader (interface section 6) must advance the load address only on `imem_wack`; otherwise `loaded` could rise with a word unwritten. Alternative: no gate in the lane, with the host block guaranteeing no write in that cycle. A1 would then need that guarantee as an assumption.
