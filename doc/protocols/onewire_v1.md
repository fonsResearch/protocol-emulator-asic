# 1-Wire controller (held-out protocol, plan step 11)

Held-out package: written after the RTL freeze, against the frozen ISA v1, lane spec and contract
language v1, with zero RTL changes. Procedural isolation (user decision 2026-11-11): this document
and the contract (`flex_v2/src/flex_lib.ml`, `onewire_ctl`) are committed before the firmware.
Later contract changes only through a logged disagreement (`log/flexibility_v2.md`).

Scope (user decision 2026-11-11): unconditional A2 on the frozen lane spec, compile and fit check
against the monitor ISA, and unmonitored firmware runs on the chip RTL and gate level. The shipped
chip has no slot for this contract (ROM library only), so it is not monitored on chip.

## 0. Sources

Standard-speed timing, DS18B20 datasheet (Maxim / Analog Devices), AC electrical characteristics,
1-Wire interface, checked 2026-11-11 against several copies of the datasheet:

| parameter | symbol | min | max |
|---|---|---|---|
| time slot | tSLOT | 60 us | 120 us |
| recovery time | tREC | 1 us | |
| write-0 low time | tLOW0 | 60 us | 120 us |
| write-1 low time | tLOW1 | 1 us | 15 us |
| read data valid | tRDV | | 15 us (from the falling edge that starts the slot) |
| reset time high | tRSTH | 480 us | |
| reset time low | tRSTL | 480 us | (960 us in one revision) |
| presence-detect high | tPDHIGH | 15 us | 60 us |
| presence-detect low | tPDLOW | 60 us | 240 us |

The device samples a write slot 15 to 60 us after the master's falling edge. Data are LSB first.
Not used here: overdrive speed, parasite power and strong pull-up, ROM search.

## 1. Pins, steps, host framing

- DQ = uio2, open drain (`own` = `od` = 0x04). The line is pulled up externally. The lane pulls it
  low with `out[2]` = 0.
- Divisor P = 29 at 30 MHz: one step = 30 cycles = 1 us. The contract counts steps, so A2 holds for
  every P (C1). The microsecond reading below assumes P = 29.
- Host TX framing: an op byte, then its data. Op 0 = reset; the lane pushes the presence sample
  (bit 7 = 0 when a device answered). Op 1 = write the next TX byte (8 write slots). Op 2 = read a
  byte (8 read slots; the byte is pushed).
- Observables: `drv` = Drive 2 (the chip pulls DQ low; chip-driven), `line` = Uio_in 2 (the
  synchronised bus level; environment). WF1: fail checks require only `drv`. WF2: blame checks
  require only `line`, with `drv` in conditions and guards.

## 2. Rounding

Fail bounds are rounded strict: the chip may be required to do more than the datasheet asks.
Blame bounds are rounded lenient by 1 step for the synchroniser and step quantisation (language
v1 C7): the device is blamed only when it certainly broke the datasheet.

## 3. Pull classes

A pull is a maximal run of steps with `drv`, starting at step s0; L is its length in steps and
r = s0 + L its release step. The monitor ISA cannot branch on elapsed time (section 6), so the
contract separates pull classes at fixed time points after s0:

| class | release r | use | datasheet |
|---|---|---|---|
| short | s0 + 1 .. s0 + 13 | write-1, read start | tLOW1 <= 15 |
| write-0 | s0 + 61 .. s0 + 118 | write-0 | tLOW0 60 - 120 |
| reset | s0 + 480 or later | reset | tRSTL >= 480 |

A write-0 is followed by at least 64 released steps, so the bus is released through s0 + 124
for every write-0. This is stricter than the datasheet (tREC >= 1 us) and makes a write slot about
130 us long. It lets the device watcher ignore the line between s0 + 13 and s0 + 118 of a long pull
without missing a legal chip pull.

## 4. Guarantees (watcher `master`, fail, codes 0x11-0x14)

| code | violation | datasheet |
|---|---|---|
| F11 | a pull released in s0 + 14 .. s0 + 60 | tLOW1 <= 15; tLOW0 >= 60 |
| F12 | a pull still held at s0 + 118 and released before s0 + 480 | tLOW0 <= 120; tRSTL >= 480 |
| F13 | after a reset release r: a pull in r + 1 .. r + 480 | tRSTH >= 480 |
| F14 | after a short pull: a pull starting in s0 + 14 .. s0 + 60; after a write-0 release r: a pull in r + 1 .. r + 63 | tSLOT >= 60, tREC >= 1 (stricter, section 3) |

Fail bounds are strict: write-0 is limited to 118 steps (datasheet 120), write-0 recovery to 64
steps (datasheet 1). Known gap: after a short pull, a second pull that starts and ends inside
s0 + 1 .. s0 + 12 is not detected (the watcher waits blind until s0 + 13; the language has no
negated elapsed term to watch that interval).

## 5. Assumptions (watcher `device`, blame, codes 0x21-0x25)

| code | violation | datasheet |
|---|---|---|
| B21 | the line is low while the chip has not pulled since the last completed slot or presence check | only the master starts slots |
| B22 | after a reset release r: the line is low at r + 2 .. r + 14 | tPDHIGH >= 15 |
| B23 | after a reset release r: no presence low by r + 63 | tPDHIGH <= 60 (lenient 3); a device is attached (assumption of this package) |
| B24 | the presence low lasts fewer than 47 or more than 480 steps | tPDLOW 60 - 240 (lenient 13 / 240) |
| B25 | after a short pull: the line is still low at s0 + 74; after a write-0: the line is still low at s0 + 179 | tRDV, tSLOT (the device's read-0 ends within the slot) |

The line is read from r + 2 on after every chip release: at P = 0 the input synchroniser lags the
bus by up to 2 steps, and a low seen in those steps is the chip's own pull. The device is not
watched between s0 + 13 and s0 + 118 of a long pull. B24 is lenient by up to 240 steps because
the monitor's window table holds 7 values per package: 2, 13, 47, 58, 61, 361, 480.

Not checked by the contract: that the device answers a read with correct data; that it does not
pull during a write-1 slot; CRC8 of ROM and scratchpad. These are data-integrity properties of the
device and are left to the host.

## 6. Language findings

- A branch condition is a plain bank predicate: `if_ (el n)` is rejected by the compiler in every
  position (probes in `flex_v2/test/test_lang_probe.ml`). The register and elapsed modifiers attach
  only to a requirement or an expect predicate. Classification by duration therefore needs fixed
  time points plus a guard (master) or a blind skip (device), and the derived timing discipline of
  section 3.
- One guard per watcher: the device watcher's guard is used for B21, so its classification uses
  `skip` and a branch on `drv` instead of a guard.
- The window table (7 values) bounds precision: B24's upper bound is 480 instead of 241.
- Monitor size: 2 units, 20 instructions, 9 check codes, 7 window values
  (`flex_v2/test/test_onewire_contract.ml`).
