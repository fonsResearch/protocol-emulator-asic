# Interface contract v1 (shared by spec and RTL)

Status: DRAFT for freeze (2026-10-17), with `doc/isa/isa_v1.md`. Monitor-engine programming registers (section 7) are reserved here and specified at plan step 6 as interface v1.1. Choices made in this draft are marked **[choice]**.

## 1. Boundary and reset

- The design is `tt_um_dean_protocol_emulator`: a hand-written wrapper around the Hardcaml-emitted core.
- `rst_n` is synchronised by the wrapper's 2-flop synchroniser into `rst_sync_n`: asserted asynchronously, released synchronously, as in v0.1.
- While `rst_sync_n` = 0, every register except the instruction memories and the program-store contents holds its reset value.
- `ena` is ignored. The organisers state that deselection powers the design down, so programs must be reloaded after it.
- Clock target: 60 MHz (decision A10).

## 2. Pin map

| pin | dir | function |
|---|---|---|
| `ui_in[0]` | in | host SPI CS_n |
| `ui_in[1]` | in | host SPI SCK |
| `ui_in[2]` | in | host SPI MOSI |
| `ui_in[7:3]` | in | unused in v1 (reserved) |
| `uo_out[0]` | out | host SPI MISO |
| `uo_out[1]` | out | verdict: fail flag (sticky) |
| `uo_out[2]` | out | verdict: blame flag (sticky) |
| `uo_out[4:3]` | out | lane 0 `xo[1:0]` |
| `uo_out[6:5]` | out | lane 1 `xo[1:0]` |
| `uo_out[7]` | out | any lane faulted |
| `uio[7:0]` | in/out | protocol pins, shared by the lanes under ownership masks (ISA section 4) |

`uio_oe[i]` = 0 for every pin no running lane owns and drives, so idle levels come from external pull-ups.

## 3. Input synchronisation

- Every input used (`ui_in[2:0]`, `uio_in[7:0]`) passes through a 2-flop synchroniser (`s1` <- pin, `s2` <- s1 every cycle; reset 0).
- During cycle c, `s2` holds the pad value sampled at edge e_{c-1}.
- Lanes and monitors read only `s2` values.
- Proofs assume each asynchronous input is stable around the sampling edge (physical assumption PH1).

## 4. Host SPI port

- Mode 0 (CPOL 0, CPHA 0), MSB first, CS_n active low. SCK is oversampled: the port acts on `s2(SCK)` edges in the core clock.
- **Host timing requirement.** This is an assumption, monitored by the built-in `host_spi` blame contract (section 7):
  - SCK high and low each at least 4 cycles;
  - MOSI stable from 2 cycles before to 2 cycles after each rising SCK edge;
  - CS_n set-up and hold of at least 4 cycles around the first and last SCK edge.
  - At 60 MHz this allows SCK up to 7.5 MHz [arithmetic].
- **Transaction.** The first byte is {R/W (1 = read), addr[6:0]}; then data bytes. The address auto-increments after each data byte, except for the port registers (marked P), which keep their address. For reads, MISO shifts out the addressed register from the second byte on; the value is sampled at the last SCK rising edge of the previous byte.
- **MISO** changes after falling SCK edges observed in `s2` (latency up to 3 cycles plus pad delay), and is 0 while CS_n is high.

## 5. Register map (7-bit address)

| addr | name | access | content |
|---|---|---|---|
| 0x00 | ID | R | 0xA1 [choice] |
| 0x01 | CTRL | R/W | bit0 RUN_L0, bit1 RUN_L1; bit4 CLR_VERDICT (write 1), bit5 CLR_FAULT_L0, bit6 CLR_FAULT_L1 (write 1) |
| 0x02 | STATUS | R | bit0/1 running L0/L1, bit2/3 loaded L0/L1, bit4/5 faulted L0/L1, bit6 fail, bit7 blame |
| 0x03 | FAULT | R | L0 cause [3:0], L1 cause [7:4]: 0 none, 1 FETCH_BOUND, 2 BLAME, 3 HALT |
| 0x10 + 16L + 0 | OWN | R/W | ownership mask (rejected if it overlaps the other lane's mask) |
| +1 | OD | R/W | open-drain mask |
| +2, +3 | P_LO, P_HI | R/W | prescaler divisor P (16 bits) |
| +4 | LEN | R/W | program length in words, 1..255 (0 = no program); writing it clears `loaded` |
| +5 | CFG | R/W | bit0 release_on_blame, bit1 pair, bit2 msb_first, bit3 nrzi, bit4 stuff, bit5 crc_en, bit6 crc16 |
| +6 | CFG2 | R/W | ser_pin [2:0], pair_base [6:4] |
| +7 | PROG_START | W | any write: load address <- 0, `loaded` <- 0 |
| +8 | PROG_DATA | W, P | instruction bytes, low byte then high byte; each completed word is written at the load address, which then increments |
| +9 | TXF | W, P | push a byte into the lane's TX FIFO (dropped if full; overflow flag set) |
| +10 | RXF | R, P | pop a byte from the lane's RX FIFO (0 if empty) |
| +11 | FIFO_ST | R | TX level, RX level, overflow and underflow flags |
| +12 | PC | R | lane `pc` (debug) |
| 0x40-0x7F | monitor | - | reserved for the monitor engine and verdict block (section 7) |

L is 0 or 1. Configuration registers of a lane (OWN, OD, P, LEN, CFG, CFG2, PROG_*) accept writes only while that lane is halted; writes while it runs are ignored.

FIFO depth: 8 bytes each direction per lane [choice].

## 6. Program load and the load gate (decision V4)

1. `PROG_START` resets the load address to 0 and clears `loaded`. Writing `LEN` also clears `loaded`; so does reset.
2. Each word written increments the load address. When the address reaches `LEN` (≥ 1), `loaded` <- 1. Words beyond `LEN` are written but do not affect `loaded`.
3. Invariant (to be proved): if `loaded` = 1, then every `imem[a]` with a < `LEN` was written since the last reset or `PROG_START`.

A lane runs only if `loaded` = 1, and it faults on a fetch at `pc` ≥ `LEN` (ISA section 3). Together these remove the instruction-memory initial-state assumption (PH5).

## 7. Monitor engine and verdict (reserved; specified at plan step 6)

To be specified as interface v1.1:
- **Verdict block:** fail and blame flags, first-fail and first-blame cause codes, 32-bit cycle timestamps, the lane attribution of the first blame, and clear.
- **ROM contract selection** per lane: the shipped protocols' guarantee and assumption watchers, plus the built-in `host_spi` assumption contract (always on).
- **Loadable monitor store:** slot address and data ports, the per-watcher observable remap table (so contracts are relocatable to the owned pins), the lane attribution bit, and the per-package parameter table.
- **Proof scope rule:** a package's theorem covers exactly the monitor programs, remap and parameter values it was proved with. The host loader writes them as part of the package.

## 8. Observables used by verification

- **Pin trace:** per cycle, `uo_out`, `uio_out` and `uio_oe`, plus the raw input pins.
- **Host-interface events:** TX FIFO writes and RX FIFO pushes per lane, with their data. These are the contract streams.
- **Observation relation for A1:** spec and RTL agree on all of the above in every cycle, given the same raw input sequence and the same imem contents at the start of the run.
