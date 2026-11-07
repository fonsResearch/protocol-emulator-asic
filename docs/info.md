<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

A programmable protocol emulator with an on-chip assumption monitor.

- **Two driver lanes** run protocol firmware (ISA v1, 16-bit instructions) from their own
  256x16 SRAM. Each lane steps once per prescaler tick (divisor P), so every instruction has an
  exact time in steps. Each lane has an 8-byte TX and RX FIFO to the host, and owns a subset of the
  eight protocol pins `uio[7:0]` (ownership masks may not overlap).
- **A monitor engine** checks each lane's pins against a protocol package: a guarantee contract
  (what the chip must do) and an assumption contract (what the attached device must do). Package
  programs are compiled from the same contract source the proofs use. Five monitor units per lane
  are evaluated one per cycle, so a monitored lane needs P >= 4.
- **Verdict.** A guarantee violation sets *fail* (`uo[1]`); an assumption violation by the
  attached device sets *blame* (`uo[2]`). Both are sticky, with a cause code, unit and cycle stamp
  readable over the host port.
- **Shipped packages** (ROM, index: package): 0 UART TX (uio0), 1 UART RX (uio1), 2 SPI controller
  mode 0, 3 SPI target mode 0 (SPI on uio4-7), 4 I2C controller Fm, 5 I2C controller Sm, 6 I2C
  target Sm (I2C on uio2 = SCL, uio3 = SDA, open drain). Each ROM lane's timing windows can be
  replaced by a host-loaded table (WIN_CTL/WIN_LO/WIN_HI, doc/contracts/monitor_isa_v1.md section 8).
- Verification target: for each package, *fail* is never raised unless *blame* was raised
  earlier, under stated physical assumptions (doc/concept/assume_guarantee.md). This is proved on
  the specification; the link to the chip is being completed (log/proofs_v2.md).

Clock: 30 MHz for this build (v2 minimum + I2C controller + window tables + I2C target, increments 1-3). Timing is signed off at the slow corner, 1.08 V / 125 C, for the builds before the I2C target (setup slack +1.32 ns for increment 1, +3.64 ns with the window tables). This build (increment 3 with the pipelined monitor schedule, log/increments_v2.md sections 3.4-3.5) is signed off at the slow corner with setup slack +6.34 ns; the first increment-3 build without the pipelined schedule failed at -3.54 ns. The lane divisors are host registers, so a different clock only changes the divisor values. Divisors at 30 MHz (`Rom_lib.divisors_at`): UART TX P = 64 and UART RX P = 32 for 115200 baud, SPI controller/target P = 7, I2C controller Fm P = 7 (step 0.27 us, SCL 375 kHz), Sm P = 29 (step 1 us), I2C target Sm P = 5 (step 0.2 us; contract h_min 19, l_min 22, hd 19 steps). The monitor admits RUN only for P >= 5 (5 slots, pipelined schedule).

## How to test

All access is through the host SPI port on `ui[0]` CS_n, `ui[1]` SCK, `ui[2]` MOSI and `uo[0]`
MISO: mode 0, MSB first. SCK high and low at least 4 clock cycles each (up to about 3.75 MHz at 30 MHz).
The first byte is {R/W (1 = read), address[6:0]}; data bytes follow with an auto-incrementing
address.

1. Read address 0x00: ID = 0xA1.
2. Lane 0 setup (lane base 0x10): write OWN (0x10) = 0x01 (pin uio0), P (0x12, 0x13) = 7, 0. Write
   LEN (0x14) = number of instructions, PROG_START (0x17) = 0, then the instruction bytes, low
   byte first, to PROG_DATA (0x18).
3. Enable the UART TX package on lane 0: write 0x50 = 0x80 | 0 (package index 0), then the
   package's pin remap table to 0x60.
4. Push a byte to the TX FIFO (0x19), then set RUN_L0 in CTRL (0x01 = 0x01). The byte appears on
   uio0 as a UART frame.
5. Read STATUS (0x02) and VERDICT (0x40). A correct program leaves fail and blame at 0. Loading
   a faulty program (for example a long start bit) sets fail on `uo[1]`. CTRL bit 4 clears the
   verdict.

Full register map: doc/interface_v1.md (lanes) and doc/contracts/monitor_isa_v1.md section 8
(monitor).

## External hardware

A host that speaks SPI mode 0 on the `ui`/`uo` pins, for example the RP2350 on the demo board, and
the protocol peer under test (UART, SPI) on `uio[7:0]` through a Pmod. No other parts are
required.
