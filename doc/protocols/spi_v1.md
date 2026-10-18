# SPI, v1 (contract source document, step domain)

Status: v1 (2026-10-18), plan step 7. Contracts `Library_v1.spi_ctl` and `Library_v1.spi_tgt` are written from this document only. Firmware is written afterwards (user decision: procedural isolation). Changes after firmware exists go through `log/disagreements.md`.

User decisions (2026-10-18): pin map A, one byte per CS assertion, ROM parameter sets controller h = 2 and target h_min = 3 in all four modes.

## 1. Line format (common convention)

- Four wires: CS (active low), SCLK, MOSI (controller to target) and MISO (target to controller). Data is 8 bits per byte, most significant bit first. Full duplex: one byte goes each way per byte time.
- Mode (CPOL, CPHA):
  - CPOL is the SCLK level while idle.
  - The *leading* edge of each clock pulse leaves the idle level; the *trailing* edge returns to it.
  - CPHA = 0: both sides sample on leading edges and change data on trailing edges. The first bit is valid before the first leading edge.
  - CPHA = 1: both sides change data on leading edges and sample on trailing edges.
- Source: the de facto convention of the Motorola SPI block guides. SPI has no single normative standard.
- v1 framing: one byte per CS assertion, so 16 SCLK edges while CS is low.

## 2. Pins and time base

| signal | uio | controller lane | target lane |
|---|---|---|---|
| CS | 4 | push-pull output | input |
| SCLK | 5 | push-pull output | input |
| MOSI | 6 | push-pull output, driven by the serializer | input |
| MISO | 7 | input | push-pull output (`MOV out, sr`, so sr[7] goes to uio7) |

The same map serves both roles. A controller on one lane and a target on the other can share the pads (on-chip loopback).

Times are in steps of the lane that owns the package. For a chip output, "X in step s" is the value the lane drives during step s; for an input, it is the synchronised value the lane reads in step s. Both are the values its monitor sees. An instruction executing in step s changes outputs from step s+1 on (ISA section 7).

## 3. Controller (chip drives CS, SCLK, MOSI)

Parameters: CPOL, CPHA, half period h ≥ 2 steps.

Definitions:
- p is a step in which the lane pops byte b from the host TX stream.
- c is the first step after p in which CS is 0.
- Segment j (j = 0..16) is the steps c + jh .. c + (j+1)h - 1.
- Edge j (j = 0..15) is the SCLK change at the start of segment j+1. Even j are leading edges, odd j are trailing edges.
- The sampling step of bit k (k = 0..7) is S_k = c + (2k+1)h for CPHA = 0, or c + (2k+2)h for CPHA = 1.

**Guarantee (violation = fail).**
- G1 Select: c - p is in 1..4, and SCLK = CPOL in step c.
- G2 Clock: in segment j, CS = 0 and SCLK = CPOL xor (j mod 2). CS = 1 in step c + 17h. No pop in steps c+1 .. c + 17h.
- G3 Idle: from step c + 17h until the next pop, CS = 1 and SCLK = CPOL.
- G4 MOSI: MOSI = b[7-k] in steps c + 2kh + 1 .. c + (2k+2)h for CPHA = 0, or c + (2k+1)h + 1 .. c + (2k+3)h for CPHA = 1. So MOSI changes one step after the shifting edge.
- G5 MISO capture: the lane pushes exactly one byte r to the host RX stream, in a step of c + 17h .. c + 17h + 3. r[7-k] = MISO in step S_k. There is no other push between c and that push.
- G6 Drive: from the first pop on, oe = 1 on CS, SCLK and MOSI in every step.

**Assumption (target behaviour; violation = blame).**
- A1 (amended, D2): MISO is constant in steps S_k - 1 .. S_k + h - 1, i.e. it changes only in the half period after the shifting edge and before the step preceding the sampling step. (Original v1 text: MISO does not change in step S_k only. That text let a target with a clock-to-output delay above about one step deliver consistently stale bits without blame.)

**Host-stream assumption (outside the monitor).** The host RX FIFO is not full at the push.

**Note on progress.** A frame starts only when the host TX stream is non-empty. The monitor cannot observe the host FIFO, so progress is not a contract item (as for UART TX).

**Real time [estimate].** With divisor P, one step is (P+1)/60 MHz. At P = 7 and h = 2, SCLK = 60 MHz / (2 · 2 · 8) = 1.875 MHz.

## 4. Target (environment drives CS, SCLK, MOSI)

Parameters: CPOL, CPHA, minimum half period h_min ≥ 3 steps, CS-high minimum g = 6 steps.

Definitions:
- A frame starts at a step c in which CS reads 0 and read 1 in the previous step, while the target is idle.
- e_1 < e_2 < ... < e_16 are the first 16 steps after c in which SCLK differs from its value in the previous step. Odd i are leading edges, even i are trailing edges.
- The sampling edge of bit k is S_k = e_{2k+1} for CPHA = 0, or e_{2k+2} for CPHA = 1.
- r is the first step after e_16 in which CS reads 1.

**Assumption (controller behaviour; violation = blame).**
- B1: SCLK = CPOL in step c.
- B2: SCLK does not change in steps c+1 .. c + h_min - 1, nor in steps e_i + 1 .. e_i + h_min - 1 for i < 16. CS stays 0 from c until e_16.
- B3: each wait for the next edge, and for r after e_16, lasts at most 4095 steps.
- B4: SCLK does not change between e_16 and r.
- B5: CS is 1 in steps r .. r + g - 1, and in the first g steps after the lane starts.
- B6 (amended, D2): MOSI is constant from step S_k - 1 until the next shifting edge (CPHA = 0: e_{2k+2}; CPHA = 1: e_{2k+3}, or r after the last bit); it may change in the step of that edge. (Original v1 text: constant in S_k - 1 .. S_k + 1 only, which let a controller that changes MOSI late deliver stale bits without blame.)

**Guarantee (violation = fail).**
- H1 Byte ready: after the push of the previous frame (or the start), the lane pops byte b from the host TX stream in a step before c. No push occurs, and CS does not fall, before or in the step of that pop.
- H2 MISO: MISO = b[7-k] in steps S_k - 1 and S_k.
- H3 Capture: the lane pushes exactly one byte q, in a step of e_16 + 2 .. e_16 + 4. q[7-k] = MOSI in step S_k + 1. There is no other pop or push between the pop of H1 and that push.
- H4 Drive: from the first pop on, oe = 1 on MISO in every step. MISO is not tri-stated while CS is high (v1 limitation: single-target buses only).

**Host-stream assumptions (outside the monitor).** The host TX FIFO is not empty when the lane pops for a frame, and the RX FIFO is not full at the push.

**Physical meaning [estimate].** The controller samples MISO at its own edge, which reaches the target's view up to one step plus the 2-cycle synchroniser later. H2 covers the step before the observed edge for that reason. With P_t the target divisor, h_min = 3 steps accepts controller half periods of at least 3(P_t + 1) cycles plus synchroniser jitter; at P_t = 7 that is SCLK up to about 2.5 MHz.

## 5. Parameter sets for the ROM library (user decision)

Compiled resource use (`monitor_v1/test/test_library.ml`): controller 5 units, 12/15 codes, 11/14 predicates, 5/7 windows; target 5 units, 12-13/15 codes, 14/14 predicates, 6/7 windows. Codes label check families (language v1.1, C10).

| package | role | CPOL | CPHA | timing |
|---|---|---|---|---|
| `spi_ctl_m0..m3` | controller | mode bits | | h = 2 |
| `spi_tgt_m0..m3` | target | mode bits | | h_min = 3, g = 6 |

## 6. Composition (for the oracle campaign)

A controller (h, P_c) on lane 0 and a target (h_min, P_t) on lane 1 sharing the pads meet each other's assumptions as follows [claim, to be argued at step 7]:
- the controller's G1-G4 imply the target's B1-B4 and B6 if h(P_c + 1) ≥ h_min(P_t + 1) + 2;
- B5 needs CS high for at least g target steps between frames, so the controller's host must space its frames;
- the target's H2 implies the controller's A1.
