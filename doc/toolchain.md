# Toolchain v2: assembler, contract compiler, examples

Plan v5 step 10. Two command-line tools over the libraries the proofs and RTL tests use (no
second encoder, no second compiler):

| tool | source | does |
|---|---|---|
| `pemu_asm` | `toolchain/bin/pemu_asm.ml`, `toolchain/src/asm.ml` | text assembler, disassembler, lint for ISA v1 lane firmware |
| `pemu_cc` | `toolchain/bin/pemu_cc.ml`, `toolchain/src/cc.ml`, `toolchain/src/cprint.ml` | contract library listing, printed view, compile and admission check, window retuning |

Build: `dune build ./toolchain`; the executables are `_build/default/toolchain/bin/pemu_asm.exe`
and `pemu_cc.exe` (`tools/pemu` wraps both, see section 6).

## 1. Decisions (agent, under the 2026-10-27 delegation; override any of them)

- T1. Tools in OCaml, linking `Isa1.encode`, `Compile`, `Library_v1` and `Rom_lib` directly, so a
  tool cannot disagree with the proved encoder and compiler.
- T2. Assembly syntax = the mnemonics and operand order of `doc/isa/isa_v1.md` section 5.
- T3. Contracts stay an OCaml embedded DSL (decision Q1, 2026-10-17). `pemu_cc` does not parse
  contract text. Its printed view is DSL source that compiles back to the same contract
  (section 5, test P1).
- T4. The shipped chip has logic-ROM contracts and the option-D window override (interface v2.1);
  loadable contracts did not route (`log/increments_v2.md` section 2). The host-facing output of
  the contract compiler is therefore a ROM package index, its remap, and, for a variant, a window
  table, refused unless the variant is window-equivalent (section 3.2).

## 2. Assembler (`pemu_asm`)

```
pemu_asm asm FILE.s [-f hex|json|list] [-o OUT] [--own N] [--od N] [--werror]
pemu_asm disasm FILE         # hex words (one per line) or JSON with "words"
pemu_asm shipped DIR         # the shipped firmware (Programs_v1) as commented .s files
```

Exit status: 0 ok, 1 assembly error, 2 lint warnings with `--werror`, 3 usage.

### 2.1 Syntax

- One statement per line: `[label:] MNEMONIC operands`. Mnemonics and operand names are case
  insensitive; labels and `.equ` names are case sensitive.
- Comments start with `;` or `#`.
- Numbers: decimal, `0x..`, `0b..`, `0o..`, `_` separators. A value is a number, `.equ` name or
  label, combined with `+` and `-` (left associative, no parentheses). `ADDI r, -1` is taken
  modulo 256.
- Directives:
  - `.equ NAME value`
  - `.word value`: a raw 16-bit word.
  - `.own`, `.od`, `.cfg`, `.cfg2` byte: the lane configuration written to the JSON output, and
    used by the lint when `--own` / `--od` are not given.

| mnemonic | operands | notes |
|---|---|---|
| `JMP t`, `DJNZ t` | target | label or 0..255 |
| `BR c, t` | condition, target | `always z nz t nt tx_empty tx_nempty rx_full ser_ready ser_busy lc_nz`, or 0..15 (11..15 reserved) |
| `OUT v`, `OEN v` | byte | |
| `PIN p, a` | pin 0..7, `out_lsb out_msb in_lsb in_msb` | |
| `WAIT k` | 0..4095 | k + 1 steps |
| `WTP p, c` | pin, `low high rising falling` | |
| `LDI d, v` | `r0..r3 sr lc to_lo xo`, byte | |
| `MOV d, s` | `r0..r3 sr lc out oe`, `r0..r3 sr lc pins ser_status` | |
| `CMP s, v` | `r0..r3 sr lc pins`, byte | |
| `ADDI d, v` | `r0..r3 sr lc`, byte | |
| `POP x`, `PUSH x` | `r0..r3 sr` | lc and codes 6, 7 rejected (ISA section 10 item 8) |
| `SER SEND x`, `SER SENDC x`, `SER PERIOD x` | `r0..r3 sr` | |
| `SER CRCI`, `SER CRCS`, `SER EOP`, `SER IDLE` | none | |
| `NOP`, `HALT`, `CLRT` | none | |

### 2.2 Disassembler

A word decodes to an instruction only if `Isa1.encode` of that instruction gives the word back
(canonical words). Other words are shown as `.word`: reserved opcode 0xF, reserved SYS codes,
SER code 7, FIFO codes 2 and 3, and nonzero unused fields. Branch, jump and DJNZ targets get labels
`L<addr>`. 14,752 of the 65,536 words are canonical.

### 2.3 Lint

| rule | check |
|---|---|
| L1 | owned open-drain pins: the first instruction is `OUT` with those bits set. `out` resets to 0, which pulls them low (ISA section 10 item 1). |
| L2 | control targets inside the program |
| L3 | `BR` condition 11..15 (reserved, never taken) |
| L4 | `OUT` / `OEN` bits outside `own` (ignored by the pin mux) |
| L5 | raw `.word` |
| L6 | the last instruction jumps or halts (otherwise execution runs into unloaded memory) |

The lint is a static check of the listed properties, not a proof of the program. A package's
firmware is verified against its contract by the A2 proofs (`log/protocols_v2.md`), not by the
assembler.

## 3. Contract compiler (`pemu_cc`)

```
pemu_cc list                       # ROM library of the tape-out build, admission per package
pemu_cc show PKG                   # printed DSL view
pemu_cc compile PKG [--p N]        # validate, compile, table summary, admission at P
pemu_cc retune ROM_INDEX VARIANT   # option-D window table, if window-equivalent
pemu_cc json                       # package table for the host package
pemu_cc print-library              # the printed view of the whole ROM library as an OCaml module
```

PKG is a ROM index, a ROM package name, or a variant `family:k=v,...` of a `Library_v1` family:
`uart_tx:d,pin`, `uart_rx:d,m,pin`, `spi_ctl:cpol,cpha,h`, `spi_tgt:cpol,cpha,h_min,g`,
`i2c_ctl:l,h,tsu,thold`, `i2c_tgt:h_min,l_min,hd`, `usb_ls_tx`. Booleans are 0/1.

### 3.1 Admission

On the tape-out build (5 slots, `lane_pipe`) the engine admits RUN for a lane with an enabled
package only if P >= slots = 5 (`Mon_engine`, `min_p`). `Rom_lib.admissibility_violations`
checks the unpipelined rule P >= slots - 1. Every shipped package has P >= 5 (smallest: I2C target,
P = 5), so the two agree on the library, but the static function is weaker than the hardware for
P = 4. `pemu_cc` uses the hardware rule.

### 3.2 Window retuning

The option-D override replaces the 7 window values of a ROM package (WIN_CTL/WIN_LO/WIN_HI,
`doc/contracts/monitor_isa_v1.md` section 8). `pemu_cc retune R V` compiles the variant V and the
ROM package R and accepts V only if the two compiled programs (`Mprog.t`) are equal in remap,
predicate bank, code table and unit programs. Only the window values may differ, and each must
fit 12 bits. The override then turns the chip's monitor program into exactly the compiled V.

Examples (expect test P2): `uart_tx:d=6,pin=0` on ROM 0 gives windows `0 2 6 62 0 0 0 0`;
`i2c_tgt:h_min=20,l_min=24,hd=20` on ROM 6 is accepted. Refused: a pin change (remap), `uart_rx`
d = 10 and SPI mode 1 (unit programs), `i2c_ctl` l = 7 (its window table would need an 8th
distinct value).

### 3.3 What a retuned contract does not inherit

The A2 results of `log/protocols_v2.md` are proofs about the shipped parameters. A retuned
variant is a different contract: its unconditional A2 (U) has not been run, and `pemu_cc retune`
says so. The witness and mutation campaigns (`log/witness_v2.md`, `log/campaign_v2.md`) are
also about the shipped contracts only. To claim a retuned package, run its A2 harness
(`formal/src/ag_pkg.ml`) with the variant and the matching firmware.

## 4. Examples (`toolchain/examples/`)

| file | lane | checked by |
|---|---|---|
| `uart_tx_d4.s` | UART TX uio0, 4 steps/bit | ROM 0 at P = 64; assembles to the shipped image |
| `uart_tx_d6.s` | UART TX uio0, 6 steps/bit | ROM 0 retuned (section 3.2) at P = 42; Psim run clean and decoded (test E2) |
| `uart_rx_d8.s` | UART RX uio1, 8 steps/bit | ROM 1 at P = 32; assembles to the shipped image |
| `blink.s` | square wave on uio2 | unmonitored (package disabled) |

`pemu_asm shipped DIR` writes all shipped firmware (UART, SPI, I2C controller Fm/Sm, I2C target,
USB-LS TX) as disassembled `.s` files with their lane configuration.

## 5. Verification (`toolchain/test/test_toolchain.ml`, part of `dune build @runtest`)

| test | property |
|---|---|
| D1 | for all 65,536 words: decode w = Some x implies encode x = w |
| R1 | every shipped program: decode of each word = the source instruction; disassemble -> assemble gives identical words |
| L1 | lint is clean on all shipped firmware with its lane configuration |
| A1 | assembler error and lint cases (range, operand classes, unknown names, duplicates, reserved conditions, raw words) |
| P1 | the printed view of the ROM library (generated at build time by `pemu_cc print-library`) compiles, and is `Lang.equal` to `Rom_lib.v2_inc5 ()` |
| P2 | retune accept/refuse cases of section 3.2 |
| E1 | the hand-written examples assemble without error or warning; three equal the shipped images |
| E2 | the retuned d = 6 transmitter runs in Psim under its compiled contract with no firing and sends the host bytes |

Not covered here: chip-level runs of the toolchain output are in the host package tests
(`host/`, section 6 of `doc/host.md`).

## 6. Wrapper and reproduction

`tools/pemu asm ARGS` and `tools/pemu cc ARGS` run `pemu_asm` / `pemu_cc` from any directory
(building the toolchain on first use). `tools/reproduce.sh quick` runs the toolchain tests, the
CLIs, the host-asset check and the MicroPython check; the other tiers of that script are listed in
its header.
