# I2C, v1 (contract source document, step domain)

Status: v1 draft (2026-10-18), plan step 7. Contracts `Library_v1.i2c_ctl` and `Library_v1.i2c_tgt` are written from this document only; firmware is written afterwards (procedural isolation; later changes go through `log/disagreements.md`).

User decisions (2026-10-18):
- header framing for the controller;
- host-set target address;
- the target stretches SCL only while its TX FIFO is empty;
- START and STOP are detected only at byte boundaries;
- one status byte per controller transaction;
- SCL = uio2, SDA = uio3;
- Standard-mode and Fast-mode as separate packages.

Source: NXP UM10204 (I2C-bus specification). Timing minima, as verified against the specification tables on 2026-10-18:

| | Sm | Fm |
|---|---|---|
| fSCL max | 100 kHz | 400 kHz |
| tLOW | 4.7 µs | 1.3 µs |
| tHIGH | 4.0 µs | 0.6 µs |
| tHD;STA | 4.0 µs | 0.6 µs |
| tSU;STA | 4.7 µs | 0.6 µs |
| tSU;STO | 4.0 µs | 0.6 µs |
| tBUF | 4.7 µs | 1.3 µs |
| tSU;DAT | 250 ns | 100 ns |
| tHD;DAT | 0 | 0 |

The Sm tBUF value is from memory; the other values were checked against the specification's timing table.

Marking: **[C]** = checked by the package contract on chip; **[O]** = not expressible in the contract language v1.1 (monitor loops have static counts, so the header count N is not tracked), checked only by co-simulation and the sigrok oracle.

## 1. Bus, pins and notation

- SCL = uio2, SDA = uio3, both open-drain (`od` = 0x0C; ISA v1.0.2: `out` = 1 releases, 0 pulls low). Pin map follows Digilent Pmod Interface Type 6 (pins 3, 4), mapped to uio2/uio3 by the Tiny Tapeout PMOD convention.
- Each line is the wired-AND of all drivers through pull-ups.
- Notation per step:
  - `dSCL`, `dSDA` = the chip pulls the line low (`uio_oe` = 1); these are chip outputs;
  - `SCL`, `SDA` = the synchronised line values (inputs).
- **First-step convention:** the program sets both lines to released (`out` bits = 1) in its first step (assembler lint).
- **Conditions,** observed in steps:
  - START or repeated START (Sr): SDA = 1 → 0 while SCL = 1 in this and the previous step.
  - STOP (P): SDA = 0 → 1 while SCL = 1 in this and the previous step.
- **Cell:** one bit. It consists of a low phase (SCL = 0) followed by a high phase (SCL = 1). A byte is 8 data cells, MSB first, followed by an ACK cell (SDA low = ACK, high = NACK).
- **Bus idle:** SCL = SDA = 1.

## 2. Controller (chip = controller)

### 2.1 Host framing (TX FIFO)

A transaction consists of:
- a = byte 0: `addr << 1 | rw`;
- c = byte 1: bits 6:0 = N in 1..127, bit 7 = r (1: the next transaction starts with a repeated START instead of a STOP ending this one);
- for rw = 0, N data bytes.

The controller pops a and c before it issues the START or Sr of the transaction, and data byte k before its first data cell.

Host-stream assumptions (outside the monitor): N ≥ 1; the data bytes of a write are pushed eventually (the controller holds SCL low while it waits, which is legal for the clock owner); the RX FIFO is never full.

### 2.2 Results (RX FIFO)

- A read pushes the N data bytes, each after its 8th cell.
- Every transaction then pushes one status byte: 0 = all ACKs received, 1 = address NACK, 2 = data NACK.
- On any NACK the controller issues STOP, whatever r is. For a write, the remaining data bytes of the transaction are popped and discarded, so the stream stays aligned [O].

### 2.3 Timing parameters (steps; per package)

| package | P | step | L (low) | H (high) | Tsta (hold S) | Tsu_sta | Tsu_sto | Tbuf |
|---|---|---|---|---|---|---|---|---|
| `i2c_ctl_sm` | 59 | 1.000 µs | 5 | 5 | 5 | 5 | 5 | 5 |
| `i2c_ctl_fm` | 14 | 0.250 µs | 6 | 4 | 6 | 3 | 3 | 6 |

Each value is the UM10204 minimum divided by the step, rounded up. Then L + H ≥ 1/fSCL,max: Sm 10 µs, Fm 2.5 µs. Real time also includes the per-bit firmware overhead (low phase) and the line rise time, which only lengthen the phases.

### 2.4 Guarantee (violation = fail)

- G1 Clock [C]:
  - after each step in which dSCL becomes 1, dSCL stays 1 for at least L steps;
  - after a release (dSCL becomes 0), the first step with SCL = 1 starts the high phase, and dSCL stays 0 in that step and the next H - 1 steps.
  - Stretching: the time from release to SCL = 1 is unbounded (unbounded wait, WF4).
- G2 Data changes [C]:
  - dSDA changes only in steps where dSCL = 1 in that step and the previous one (hold ≥ 1 step after the SCL fall);
  - dSDA does not change in the step in which dSCL becomes 0 (setup ≥ 1 step).
  - Exception: the START, Sr and STOP conditions of G4.
- G3 Byte values [C]:
  - In the address cells and write-data cells, dSDA = NOT bit, MSB first, for the byte popped in order (a, then data bytes).
  - In ACK cells of the address and of written data, and in read data cells, dSDA = 0 (released).
  - In the ACK cell of a read byte, dSDA = 1 (ACK) or 0 (NACK). The position of the NACK (last byte) is [O].
- G4 Conditions [C]:
  - START only from bus idle;
  - after dSDA becomes 1 at a START or Sr, dSCL becomes 1 no earlier than Tsta steps later;
  - Sr: SDA released and the SCL high phase observed for at least Tsu_sta steps before dSDA becomes 1;
  - STOP: dSDA = 1 through the low phase, then SCL released; at least Tsu_sto steps after SCL is observed high, dSDA becomes 0; after a STOP, no START for at least Tbuf steps.
  - Whether a transaction ends with STOP or with Sr is [C] for the NACK case (always STOP) and [O] for the r flag.
- G5 Read data [C]: each pushed read byte has bit 7-k = SDA in the second step of the high phase of data cell k of that byte (D3). The status uses the ACK cells' SDA, also in the second high step.
- G6 Status [C]: the status push equals 1 if the address ACK cell saw SDA = 1, 2 if a write-data ACK cell saw SDA = 1, else 0. It occurs after the last cell of the transaction and before the next START or Sr.
- G7 Pops and pushes [C]: no pop between the START of a transaction and the first data cell of a data byte other than the pops listed in 2.1; no push other than the pushes of 2.2. The counts are [O].

### 2.5 Assumption (bus and target behaviour; violation = blame)

- A1 Single controller [C]: in any step where dSDA = 0 during an address cell, a write-data cell, or a START/Sr/STOP sequence, SDA = 1. No arbitration: multi-controller buses are out of scope.
- A2 Stable data [C]: SDA is constant during every high phase of read data cells and ACK cells.
- A3 SCL ownership [C]: once SCL = 1 in a high phase, SCL stays 1 until dSCL becomes 1. Targets may stretch only in low phases.
- A4 Idle at start [C]: SCL = SDA = 1 in the first 4 steps after the lane starts.

## 3. Target (chip = target)

### 3.1 Host interface

- At start the lane pops a config byte k: bits 6:0 = own address, bit 7 = 0.
- Write data received is pushed, one byte per data byte.
- Read data is popped, one byte per data byte. If the TX FIFO is empty when a byte is needed, the target stretches SCL until it is not.

The address is also patched into the program's compare immediates by the host tool when it loads the program (ISA v1 has no register-to-register compare). The firmware halts if the popped config byte differs from the patched value [O].

Host-stream assumption: the RX FIFO is never full.

### 3.2 Timing parameters (steps at P = 7, 0.1333 µs per step)

| package | h_min (SCL high) | l_min (SCL low) | hd (SCL high after S/Sr) |
|---|---|---|---|
| `i2c_tgt_sm` | 29 | 34 | 29 |
| `i2c_tgt_fm` | 4 | 9 | 4 |

Each value is the UM10204 minimum in steps, minus one step for synchroniser and tick quantisation.

### 3.3 Assumption (controller behaviour; violation = blame)

- B1 Timing [C]:
  - every SCL high phase lasts at least h_min steps;
  - every SCL low phase not extended by the target lasts at least l_min steps, counted from the step in which SCL becomes 0;
  - after a START or Sr, SCL stays 1 for at least hd steps.
- B2 Data changes [C]: SDA changes only while SCL = 0, except START/Sr/STOP conditions.
- B3 Byte boundaries [C]: START, Sr and STOP occur only in the high phase of the first cell after an ACK cell, or from bus idle. A condition elsewhere is a blame.
- B4 No contention [C]: in steps where the target releases SDA during its read-data cells, SDA = 1.
- B5 Idle at start [C]: SCL = SDA = 1 in the first 4 steps after the lane starts.

### 3.4 Guarantee (violation = fail)

- H1 Passive [C]: before the config pop and between transactions not addressed to it, the target releases both lines (dSCL = dSDA = 0).
- H2 Address [C]:
  - the address byte is the 8 SDA values in the first high-phase step of each cell after a START/Sr;
  - in the ACK cell, the target pulls SDA (dSDA = 1) iff bits 7:1 equal k[6:0], from the step after the observed SCL fall that ends the 8th cell until the observed SCL fall that ends the ACK cell;
  - otherwise it stays passive until the next START or Sr.
- H3 Write data [C]: for rw = 0, each data byte is pushed with bit 7-k = SDA in the first high-phase step of cell k, and ACKed as in H2.
- H4 Read data [C]:
  - for rw = 1, each data byte b is popped before its first cell's high phase;
  - in data cell k, dSDA = NOT b[7-k] from the step after the observed SCL fall that starts the cell through the end of its high phase;
  - in the ACK cell, dSDA = 0; a NACK ends the target's transmission (passive until the next condition).
- H5 Stretching [C]:
  - dSCL = 1 only in low phases, starting within 2 steps of the observed SCL fall;
  - only while a read byte is not yet available (between the fall and the pop of that byte);
  - dSCL = 0 again within 2 steps after the pop.

## 4. Amendments made while writing the contracts (2026-10-18, before any firmware)

These amendments keep the controller contract able to track transactions (the monitor cannot count N) and fit monitor ISA v1. The budget is 14 predicates, 7 windows and 15 codes per package. Branch conditions and samples must be plain predicates of observables, and each consuming statement can carry at most one mark, sample, match, expect and branch.

Controller:
1. **Stream order** [C].
   - The header bytes a and c are the first two pops after the end condition (STOP or Sr) of the previous transaction, or after reset. From idle they are popped before the START; after an Sr, during the hold time that follows it.
   - Data bytes of a write NACKed at the address or a data byte are popped and discarded before the STOP.
   - The status byte is pushed in steps E+2 .. E+8, where E is the step of the end condition, and before the next header pops.
   - Write data byte k is popped after the SCL pull that ends the preceding ACK cell, and before its first cell's release.
   - A read byte is pushed within 64 steps after the SCL pull that ends its 8th cell, and before the first high step of its ACK cell.
2. **Hold times.** Tsta and Tbuf share one value per package, the larger (Sm 5, Fm 6). Fm Tsta is therefore stricter than UM10204 (1.5 µs instead of 0.6 µs). One check then covers both: after a START/Sr, SCL stays released and SDA pulled; after a STOP, no START.
3. **Setup-time check.** The check (Tsu_sta = Tsu_sto = tsu) also applies to every SCL pull. This is redundant because tsu ≤ H.
4. **Bounds.**
   - Every high phase ends within 4095 steps of its first step [C].
   - The first START comes no earlier than Tbuf steps after the lane starts [C], via the setup-time check.
5. **Now [O]** (predicate budget):
   - "START only from bus idle" (a requirement on the line, which a fail check may not constrain);
   - A3 (SCL ownership in high phases);
   - A4 (idle at start);
   - stability of a target-driven ACK during the high phase.

   A2 stays [C] for read data cells.

Target:
6. **[O]:**
   - ACK iff the address matches the config byte (no register-to-register comparison, and branch conditions cannot read the register);
   - passivity before the config pop;
   - stretching only while a read byte is pending, and the 2-step stretch response.
7. **[C], one invariant:** while SCL is observed high, the target neither changes dSDA nor starts pulling SCL. This covers ACK and data stability in high phases, and the part of H5 that protects the bus.
8. **Ordering and check placement.**
   - A received byte is pushed before the first high step of its ACK cell.
   - B4 is checked in the second step of each read high phase.
   - B5 checks only SCL ([O] for SDA).
   - B3: SDA may change during a high phase only in the first cell of a byte. A high phase in the middle of a byte lasts at most 4095 steps (assumption). hd also applies after Sr.

Compiled resource use (`monitor_v1/test/test_library.ml`):

| package | units | instrs | preds | windows | codes |
|---|---|---|---|---|---|
| i2c_ctl Sm | 3 | 5+8+123 | 14/14 | 6/7 | 12/15 |
| i2c_ctl Fm | 3 | 5+8+123 | 14/14 | 7/7 | 12/15 |
| i2c_tgt Sm/Fm | 5 | 75+1+4+25+1 | 13/14 | 6/7 | 13/15 |
