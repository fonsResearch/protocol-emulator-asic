# Protocol packages v1: results (plan step 7, in progress)

Status 2026-10-18: UART and SPI done; I2C and USB-LS TX pending. The source documents are in `doc/protocols/`. The contracts are `monitor_v1/src/library_v1.ml`, the firmware `spec_v1/src/programs_v1.ml`, the co-simulation `protocols_v1/`, and the A2 harnesses `formal/src/ag_pkg.ml`. All rows below are measured; times are wall-clock seconds on the local machine (11 CPUs, up to 6 jobs in parallel).

A2 claim per package (unconditional, ticks free, so it holds for every divisor P):
- **U:** no fail fires unless a blame has fired in the same or an earlier cycle.
- **N1 cover:** a guarantee event (push) is reachable with no fail and no blame. Expected FAIL means reachable; the witness is replayed in cyclesim.
- **Negatives:** mutants and contracts with assumptions removed must FAIL, with the witness replayed.

Host-stream assumptions are harness constraints: the RX FIFO is never full (all receive-side packages), and the SPI target's POP at pc 2 never meets an empty TX FIFO.

## UART 8N1 (doc/protocols/uart_v1.md)

| harness | expected | engine | result | depth | latches | s | replay |
|---|---|---|---|---|---|---|---|
| a2_uart_tx_d4_u | PASS | dprove | PASS | | 248 | 9 | |
| a2_uart_tx_d4_n1_cover_neg | FAIL | bmc | FAIL | 3 | 249 | 0 | ok |
| a2_uart_tx_d4_badstart_neg | FAIL | bmc | FAIL | 10 | 248 | 0 | ok |
| a2_uart_rx_d8_u | PASS | dprove | PASS | | 239 | 681 | |
| a2_uart_rx_d8_n1_cover_neg | FAIL | bmc | FAIL | 80 | 240 | 4 | ok |
| a2_uart_rx_d8_late_neg | FAIL | bmc | FAIL | 81 | 239 | 17 | ok |
| a2_uart_rx_d8_noassume_neg | FAIL | bmc | TIMEOUT (1800 s, 200 frames) | | 220 | 1800 | see below |

Assumption necessity (receiver-only contract) is shown by a directed witness on the same harness netlist (`formal/bin/witness.exe uart_rx_stop`, tick every cycle):
- With the second start edge 5 cycles into the first frame's stop bit, `bad` rises at cycle 175.
- With the full contract, `bad` stays 0 for all nine offsets.

This agrees with the co-simulation sweep. There the receiver-only contract fails without blame for stops of 0.55-0.63 bit (F4B), and the full contract blames first (B33). The witness depth explains the BMC timeout.

Spec-free oracle (libsigrokdecode 0.5.3 `uart`): RX at nominal and ±2.5 % baud and TX at nominal, 64 bytes each, agree with the lane.

## SPI (doc/protocols/spi_v1.md; controller h = 2, target h_min = 3, g = 6)

| harness | expected | engine | result | depth | latches | s | replay |
|---|---|---|---|---|---|---|---|
| a2_spi_ctl_m0_u | PASS | dprove | PASS | | 346 | 65 | |
| a2_spi_ctl_m1_u | PASS | dprove | PASS | | 346 | 59 | |
| a2_spi_ctl_m2_u | PASS | dprove | PASS | | 346 | 77 | |
| a2_spi_ctl_m3_u | PASS | dprove | PASS | | 346 | 60 | |
| a2_spi_ctl_m0..m3_n1_cover_neg | FAIL | dprove | FAIL | 41-42 | 347 | 6-19 | ok (*) |
| a2_spi_ctl_m0_lsbin_neg | FAIL | dprove | FAIL | 42 | 346 | 23 | ok |
| a2_spi_ctl_m1_lsbmosi_neg | FAIL | dprove | FAIL | 10 | 345 | 0 | ok (*) |
| a2_spi_tgt_m0_u | PASS | dprove | PASS | | 310 | 898 | |
| a2_spi_tgt_m1_u | PASS | dprove | TIMEOUT | | 310 | 3601 | covered by symmetry lemma |
| a2_spi_tgt_m2_u | PASS | dprove | PASS | | 310 | 1438 | |
| a2_spi_tgt_m3_u | PASS | dprove | PASS | | 310 | 279 | |
| a2_spi_tgt_m0..m3_n1_cover_neg | FAIL | dprove | FAIL | 60 | 311 | 25-37 | ok (*) |
| a2_spi_tgt_m0_nomov_neg | FAIL | dprove | FAIL | 18 | 310 | 7 | ok |
| a2_spi_tgt_m3_nomov_neg | FAIL | dprove | FAIL | 21 | 310 | 11 | ok |
| a2_spi_tgt_m0_noassume_neg | FAIL | dprove | FAIL | 5 | 291 | 0 | ok (*) |
| a2_spi_tgt_symi_m3_m1 | PASS | ind k=4 | PASS | | 1018 | <1 | (PDR also proves it in 6.4 s) |
| a2_spi_tgt_symi_m2_m0 | PASS | ind k=4 | PASS | | 1018 | <1 | |
| a2_spi_tgt_symi_m3_m1_cs_neg | FAIL | bmc | FAIL | 3 | 1018 | 0 | ok |
| a2_spi_tgt_symi_m3_m1nomov_neg | FAIL | bmc | FAIL | 20 | 1018 | 105 | ok |

(*) The batch first reported REPLAY MISMATCH for these rows. That was a tool-flow defect: the replay binary predated the SPI harnesses and failed on harness lookup. After rebuilding, all were replayed again; every one reproduces `bad` at the reported frame. Batch runs must now build `emit_formal.exe` and `replay_cex.exe` together.

### U for target mode 1 via the CPOL symmetry lemma (user decision)

The direct dprove for mode 1 timed out (3601 s). The lemma `a2_spi_tgt_symi_m3_m1` runs the mode-3 package (copy A) and the mode-1 package (copy B) on shared free inputs. Copy B sees uio5 (SCLK) inverted. It proves that, up to the first blame, both copies have the same observations in every cycle: the U verdict, monitor fire and role vectors, owned pin outputs, stream events and data, and the fault flag.

U for mode 1 follows. After a blame, `bad` is 0 in both copies. Before it, bad_B(x) = bad_A(x xor 0x20), and xor is a bijection on input sequences, so U(m3) (proved directly) implies U(m1). The m2/m0 lemma gives a second proof of mode 0.

The lemma is not inductive as stated. Every register that holds a past SCLK value resets to 0 in both copies, so the copies are complementary only once those registers hold a sample taken after reset. The proof therefore carries an explicit invariant:
- **Register pairing.** The 88 registers of each copy are paired by creation order; there are no memories. Bit pairs of the flipped pin are complementary where a shadow flag says they hold a warm sample, and equal elsewhere. The shadows cover the two lane and two monitor synchroniser stages, the lane's `prev_pins` (via `Lane_circuit.taps`: exec and step_reset), and the monitor history slot of SCLK. All other bits are equal.
- **Early-state facts.** A cold `prev_pins` implies lane pc <= 2. A cold stage-2 synchroniser implies lane pc <= 1, and, with no blame yet, no monitor step since restart. No cold history entry exists without an earlier blame. The reason: a monitor step during synchroniser warm-up sees CS = 0, and B5 blames. The bookkeeping holds: `seen = min(stc, 4)`, and `stc = 0` implies every unit is in its reset state.

Random simulation of the invariant (`formal/bin/syminv.exe`) found no violation. Both negative controls fail with replayed witnesses, so the miter is not vacuous:
- flipping CS instead of SCLK (depth 3);
- copy B replaced by the mode-1 MOV-less mutant (depth 20).

### Co-simulation and oracle

- **Nominal.** All four modes, both roles: bytes correct in both directions, no firings, interpreter = monitor model.
- **Sweeps.** Target tco (controller lane) and controller half period and MOSI delay (target lane): clean inside the accepted range, blame outside it, and U holds in every run.
- **D2** (`log/disagreements.md`). A1/B6 originally let consistently late peers deliver stale bits without blame. They were strengthened; the accepted range is unchanged.
- **Oracle.** The libsigrokdecode `spi` decoder agrees on all 16 byte streams (4 modes × 2 roles × MOSI/MISO, 64 bytes each). Decoding with the wrong CPHA mismatches (1/64 bytes). Decoding with the wrong CPOL still agrees, because the data is stable over the whole bit, so CPOL is covered only by the contracts' idle-level checks (G2/G3, B1).

### Notes

- A lane that runs within 2 cycles of reset release makes the SPI target monitor blame B5. The synchroniser still shows CS = 0, so the initial CS-high check fails. In the chip, RUN is set through the host port, which takes far longer than 2 cycles, so this is not reachable in normal use [estimate, to be confirmed with the interface proof].
