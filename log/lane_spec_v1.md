# Lane specification v1 (S1 v1): results, 2026-10-17

Executable specification of one ISA v1 lane (doc/isa/isa_v1.md including section 10, v1.0.1).

## Components

| file | role |
|---|---|
| spec_v1/src/isa1.ml | instruction type, encoding, assembler |
| spec_v1/src/lane_model.ml | reference interpreter: one lane, 8-deep host TX/RX FIFOs, byte serializer (NRZI, stuffing, CRC5/CRC16, EOP, D+/D- pair) |
| spec_v1/src/lane_circuit.ml | spec-as-circuit (Hardcaml), written independently from the model as next-state functions |
| spec_v1/src/programs_v1.ml | reference programs (UART 8N1 TX) |
| spec_v1/bin/emit_lane.ml | Verilog of the lane spec with a ROM program |
| formal/src/ag_v1.ml | assume-guarantee harnesses on the v1 lane |

## Model vs circuit (spec_v1/test/test_lane_diff.ml)

Setup:
- 300 programs × 2,000 cycles = 600,000 cycles. Odd seeds use random legal programs; even seeds use CRC-framed programs with all pins owned and push-pull.
- Stimulus: random tick pattern, RUN, load flag, reset, pins, host FIFO traffic, blame and clear_fault.
- All 13 outputs are compared every cycle.

Results:
- **Mismatches: 0.** All coverage counters were hit: serializer busy, SE0, stuffing, timeouts, POP, PUSH, and each fault cause.
- **Planted circuit mutants:** each produced mismatches.

| mutant | mismatching cycles |
|---|---|
| stuffing after 5 ones | 63,779 |
| blocking timeout one step early | 2,731 |
| ready ignores pending stuff bit | 15,949 |
| CRC16 polynomial 0x8004 | 32,960 |
| CRC5 polynomial 0x04 | 34,315 |
| open-drain polarity inverted | 126,146 |
| POP sees same-cycle host push | 3,404 |

With random programs only (before the CRC-framed family was added), the CRC16 mutant survived (0 mismatches) and the ready mutant was detected in only 4 cycles. Random programs rarely build a CRC-protected frame on an observable pin.

## Known-answer vectors (spec_v1/test/test_lane_vectors.ml)

| check | result | reference |
|---|---|---|
| CRC-16/USB over "123456789", recovered from the pin (LSb-first data, CRC inverted MSb-first) | 0xB4C8, data round-trips | catalogue check value 0xB4C8 |
| CRC-5/USB over "123456789" | 0x19 | catalogue check value 0x19 |
| Low-speed pair: SYNC 0x80, 0xFF, EOP | `KJKJKJKK KKKKKJJJJ 00J` | SYNC = KJKJKJKK; one stuffed bit after six ones counted from SYNC; EOP = SE0 SE0 J |

## Synthesis (estimate)

Lane spec with the UART TX ROM program, Yosys 0.69 + ABC with sg13cmos5l_stdcell_typ_1p20V_25C:
- 2,003 cells, 279 flip-flops, 29,431 µm² (2.4% of the 8x4 core area, 1,208,173 µm²).
- This is the spec circuit, not the driver RTL (plan step 5). The instruction memory will be an SRAM macro there.

## Assume-guarantee on the v1 lane (formal/src/ag_v1.ml)

Setup:
- Contract: uart_tx_v01 with d = 4, without the progress watcher. Progress on the v1 lane depends on the host keeping the TX FIFO non-empty, which is a stream assumption (contract language v1, plan step 6).
- Free inputs: tick, reset, ui_in, uio_in, host FIFO push/data/pop, blame_in, clear_fault.
- Line = !uio_oe[0] | uio_out[0], i.e. the pad with the pull-up (physical assumption).
- Engine: ABC dprove via formal/prove_one.sh. Counterexamples come from bmc3 and are replayed in cyclesim.

| harness | expected | result | depth | latches / ANDs | wall s |
|---|---|---|---|---|---|
| u_v1_uart_tick_d4 | PASS | PASS | - | 225 / 3,185 | 10 |
| n1_v1_uart_tick_d4 | PASS | PASS | - | 226 / 3,186 | 12 |
| u_v1_uart_noassume_neg_d4 | FAIL | FAIL, replay ok | 8 | 222 / 3,157 | 0 |
| u_v1_uart_badprog_neg_d4 | FAIL | FAIL, replay ok | 12 | 225 / 3,185 | 0 |

## Limits

- The data content of frames is not checked by any contract yet. That needs streams (contract language v1, monitor engine v1).
- The lane spec takes host-side FIFO inputs directly. The SPI host port and its clock-domain crossing are not modelled (plan step 5).
