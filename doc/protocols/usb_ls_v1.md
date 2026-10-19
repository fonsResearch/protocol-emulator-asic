# USB low-speed TX, v1 (contract source document, step domain)

Status: v1 draft (2026-10-19), plan step 7. The contract `Library_v1.usb_ls_tx` and the proof-side
reference encoder are written from this document only; the firmware is written afterwards
(procedural isolation; later changes go through `log/disagreements.md`).

User decisions:
- 2026-10-18: scope is one DATA packet (SYNC, PID, payload, CRC16, EOP), transmit only.
- 2026-10-19: the guarantee is split. The on-chip monitor checks the line format [C]; the packet
  contents (NRZI, bit stuffing, CRC16, payload) are proved in the A2 harness against an
  independent reference encoder [P].
- 2026-10-19: D+ = uio0, D- = uio1 (pair mode, `pair_base` = 0).
- 2026-10-19: host framing = PID byte, length N, N payload bytes; one status byte per packet.
- 2026-10-19: P = 39 and bit_period = 1, so one lane step is one bit (40 cycles at 60 MHz,
  1.5 Mb/s).
- 2026-10-19 (O1): TX FIFO underrun during a packet is handled by the firmware: abort the packet
  and report it, so no host-stream assumption is needed.
- 2026-10-19 (O2): N > 8: push status 1 and halt; nothing is sent on the line.

Source: USB 2.0 specification (sections 7.1, 8.3-8.4). Check status 2026-10-19: rows marked
(checked) were confirmed against the USB 2.0 specification text (EOP, section 7.1) or two
independent secondary sources (USB 2.0 UTMI specification v1.05; application notes); rows
marked (memory) are still from memory:

| item | value used |
|---|---|
| low-speed bit rate | 1.5 Mb/s (+-1.5 %) (checked) |
| low-speed line states | J = D+ low, D- high; K = D+ high, D- low; SE0 = both low; idle = J (checked) |
| NRZI | a 0 bit toggles the line state, a 1 bit keeps it (checked) |
| bit stuffing | after six consecutive 1 bits a 0 is inserted (so at most 6 bit times without a transition); applies from SYNC through CRC, not to EOP (checked; the SYNC-through-CRC range from memory) |
| SYNC | 8 bits 00000001 (LSB first), on the line KJKJKJKK (checked: NRZI of 0x80) |
| PID | 4-bit PID plus its ones complement, LSB first (checked); DATA0 = 0xC3, DATA1 = 0x4B as bytes (memory) |
| data field | 0-8 bytes for low speed, LSB first (memory) |
| CRC16 | x^16 + x^15 + x^2 + 1, initial all ones, ones complement sent, MSB of the CRC first (memory; matches the lane spec check value CRC-16/USB 0xB4C8 over "123456789") |
| EOP | SE0 for 2 bit times, then J for 1 bit time, then idle (checked, USB 2.0 section 7.1) |
| packet abort | a run of 7 or more consecutive 1 bits (no transition) is a bit-stuff error that receivers treat as an error (checked). An intentional bit-stuff error is documented as the high-speed end-of-packet; an explicit low-speed rule allowing a transmitter abort was not found (open) |

Marking: **[C]** = checked by the package contract on chip; **[P]** = proved in the A2 harness
only (not monitored on chip); **[O]** = checked only by co-simulation and the sigrok USB decoder.

## 1. Pins and notation

- D+ = uio0, D- = uio1, push-pull, driven by the serializer in pair mode (`cfg.pair` set) while
  it is active and by `out`/`oe` otherwise.
- Observables per step: the chip's own outputs `dp`, `dm` (= `uio_out` bits 0, 1) and `oe0`, `oe1`
  (`uio_oe` bits 0, 1), masked by OWN. The monitor observes the chip outputs, not the pads.
- One step = one bit (P = 39, bit_period = 1).
- Line state per step: J = (dp, dm) = (0, 1); K = (1, 0); SE0 = (0, 0); (1, 1) is illegal (SE1).
- Driven: `oe0` = `oe1` = 1.
- Start-up convention (amended 2026-10-19 while writing the contract, before any firmware): the
  program's first two instructions are `OUT 0x02` (J) and `OEN 0x03`. Each takes one step and is
  visible from the next step, so after a restart the outputs are the reset values in the first
  step and J undriven in the second; G1 and G3 apply from the third step.

## 2. Host interface

### 2.1 Framing (TX FIFO)

- byte 0: PID byte, written by the host with its check nibble (DATA0 = 0xC3, DATA1 = 0x4B); the
  host owns DATA0/DATA1 toggling;
- byte 1: N, the payload length, 0 <= N <= 8;
- bytes 2 .. N+1: payload, sent LSB first.

The firmware sends SYNC (`SEND`), the PID byte (`SEND`), resets the CRC (`CRCI`), sends the
payload (`SENDC`), the CRC (`CRCS`) and the EOP (`EOP`), then pushes one status byte.

### 2.2 Results (RX FIFO)

- One status byte per packet: 0 = sent; 1 = N > 8 (nothing sent, the lane halts); 2 = aborted
  because the TX FIFO was empty when the next payload byte was due.

### 2.3 Underrun abort [choice: agent, to be reviewed]

Before each payload byte the firmware branches on TX FIFO empty (ISA branch condition 5). If it
is empty, the firmware waits until the serializer is idle (`SER IDLE`), pushes status 2 in the next
step (the first step of the abort), keeps J on the line through `out`/`oe` for at least 8 steps
(at least 7 bits without a transition whatever the last NRZI level was) and then sends `EOP`.
The push comes first because it marks the abort for the monitor: contract language v1 has only
lower-bound elapsed tests, so a J run of 8 or more steps can be allowed only after an observable
marker (amended while writing the contract, 2026-10-19, before any firmware). Stuffing cannot be switched off by the lane (`cfg` is host-only) and the lane
does not know the current NRZI level, which is why the abort drives J rather than continuing the
last state. The test happens just before the POP, so a POP never blocks inside a packet.

## 3. Guarantee (violation = fail)

- G1 Driven [C]: from the first step of SYNC to the end of the EOP, both pins are driven.
- G2 Legal states [C]: SE1 never occurs while driven.
- G3 Idle [C]: between packets the line is J (or both pins released).
- G4 SYNC [C]: a packet starts with K J K J K J K K, one state per step.
- G5 Transitions [C]: from SYNC to the last CRC bit, the line state stays the same for at most 7
  consecutive steps (the bit that switched to it plus at most six 1 bits; a stuffed 0 follows).
  Exception: after the abort push (2.3) the line is J until the EOP's first SE0 step, which comes
  8 to 16 steps after the push step.
- G6 EOP [C]: a packet ends with exactly 2 SE0 steps followed by 1 J step; SE0 never appears
  elsewhere.
- G7 Contents [P]: for a packet that is not aborted, the NRZI-decoded, unstuffed bit sequence
  between SYNC and EOP equals the PID byte, the N payload bytes popped from the TX FIFO, and the
  CRC16 over the payload, as computed by the reference encoder (USB 2.0 coding order: CRC over
  data, then stuffing, then NRZI). For an aborted packet, the bits before the abort run are a
  prefix of that sequence. This is a property of the A2 harness, not of the on-chip monitor. It
  is checked by an independent low-speed **receiver** circuit in the harness
  (`formal/src/usb_check.ml`: NRZI decode, unstuffing, byte comparison with the popped bytes,
  byte count and CRC16 at the first SE0), which is equivalent to comparing against the
  reference encoder and easier to align in time. The pure OCaml encoder
  (`protocols_v1/src/usb_ref.ml`) is the oracle for co-simulation and the contract tests.
- G8 Progress [C]: once the PID byte is popped, the EOP ends within a bound of B steps
  (B = 8 + 8 + 8N + 16 + stuffed bits + 3; the contract uses the bound for N = 8).
- G9 Status [C for the push, P for the value]: exactly one status push per packet: within 8 steps
  after the EOP's J step (value 0), or, for an aborted packet, at the start of the abort (value 2)
  and none after it. For N > 8: status 1, no line activity, the lane halts.

## 4. Assumption (host behaviour; violation = blame)

- H1 Valid PID [O]: the PID byte is a DATA PID with a correct check nibble.
- No length or stream assumption: N > 8 is handled by the firmware (O2), and an underrun aborts
  the packet (O1).
- The header (PID byte and N) is popped before SYNC; whether a POP of the header may block (the
  line is idle J then, so blocking is harmless) is a firmware detail.

## 5. Items to check before the contract is frozen

- The USB 2.0 facts in the table above (from memory).
- The abort form (2.3): whether a transmitter may abort with a bit-stuff error followed by EOP,
  and the required run length.
- Monitor budget: met. `Library_v1.usb_ls_tx`: 5 units, 10/14 predicates, 7/7 windows, 11/15
  codes. Predicates have at most 3 literals, so G1 (driven) and G2 (no SE1) are separate
  watchers. Contract tests on reference waveforms: `protocols_v1/test/test_usb.ml`.
