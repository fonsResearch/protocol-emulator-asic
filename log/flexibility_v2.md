# Flexibility v2: held-out protocols (plan step 11)

Question: can a protocol the chip was not built for be specified, compiled, and run on the frozen
v2 chip (ISA v1, lane spec, contract language v1, monitor ISA) with zero RTL changes?

## 1. Claim and scope (user decisions, 2026-11-11)

Claimed, per held-out protocol: the contract is **expressible** in contract language v1, it
**compiles** to the monitor ISA and **fits** its limits (units, instructions, predicates, 7 window
values, codes; the reference interpreter and the compiled program on the monitor model agree), and
the firmware **runs on the chip RTL and on the gate-level netlist** with the expected bus behaviour.

Not claimed:
- on-chip monitoring: the shipped chip has no slot for a loadable contract (ROM library only), so
  every held-out run is unmonitored; the contract's verdicts come from Psim on the same scenarios;
- A2 (assume-guarantee proof on the lane spec): dropped by the user on 2026-11-11 after the
  1-Wire U proof (ABC dprove, project default) ran about 40 min without a result; it was stopped
  and the harnesses were removed;
- the other planned protocols (WS2812 driver, SWD host): dropped by the user on 2026-11-11. The
  result is one held-out protocol, 1-Wire.

Isolation (user decision): procedural. Order in git: datasheet facts and contract (commit
4b6a9a6), then firmware and Psim peer (e95d472), then chip runs (31542b9). No contract change after
the firmware was written, so no disagreement was logged.

## 2. 1-Wire controller (doc/protocols/onewire_v1.md)

DS18B20 standard-speed timing; DQ = uio2 open drain; P = 29 at 30 MHz (one step = 1 us).

| item | result |
|---|---|
| contract | `flex_v2/src/flex_lib.ml` `onewire_ctl`: 2 watchers (master: fail 0x11-0x14; device: blame 0x21-0x25) |
| compile and fit | 2 units, 20 instructions, 9 check codes, 7 window values (2, 13, 47, 58, 61, 361, 480): the window table is full |
| fit, traces | 18 hand-made step traces (`flex_v2/test/test_onewire_contract.ml`): every check fires on its intended violation, class boundaries exact (write-0 L 118 clean / 119 F12; recovery 64 clean / 63 F14); Interp and Mmodel agree in every step |
| firmware | `flex_v2/firmware/onewire_ctl.s`, 34 words, assembler lint clean (`--werror`) |
| Psim (lane spec + Interp + Mmodel) | READ ROM and a scratchpad round trip (write, reset, read with CRC8) clean; 5 device faults blamed with the intended code (B22 presence after 5 us, B23 no presence, B24 presence 30 us, B25 read-0 held 80 us, B21 spontaneous low); 5 firmware mutants fail with the intended code (F12 reset 401, F11 write-0 28, F14 write recovery 53, F14 read slot 46, F13 reset recovery 378); Interp vs Mmodel 0 mismatches in every run (`flex_v2/test/test_onewire_psim.ml`) |
| chip RTL (OCaml top, shipped configuration: lane pipe, verdict pipe, param_windows, ROM v2inc5), unmonitored | 8 scenarios (2 clean, 4 device faults, 2 mutants): monitor inputs, pads, pins and RX bytes identical to Psim cycle by cycle (`flex_v2/test/test_onewire_chip.ml`) |
| cocotb board, host package | 3 scenarios with the host driver `host/pemu/onewire.py` and a Python device written from the datasheet (`test/demo/peers.py` OneWireDevice): READ ROM `28 5A 3C 11 07 00 00 97` (CRC ok), scratchpad `91 01 55 0A 3F FF 0F 10 45` (CRC ok), no device: presence false; pass on RTL Verilog |
| gate level | the same 3 scenarios on the sign-off netlist (run 42426292730 final/nl): pass; RTL and GL records identical, including every DQ edge (148, 264, 2 edges; `test/demo/compare_flex.py`) |

## 3. Language findings

1. **No branch on elapsed time.** A branch condition is a plain bank predicate; the unit-local
   modifiers (register, elapsed) attach only to a requirement or an expect predicate
   (`monitor_v1/src/compile.ml`). `if_ (el n)` is rejected in every position (probes in
   `flex_v2/test/test_lang_probe.ml`). Duration classes (1-Wire: short slot, write-0, reset) need
   fixed time points: a guard on release inside a window (master) or a blind `skip` and a branch
   on the line (device).
2. **The workaround costs strictness.** The contract requires more than the datasheet: write-0
   low at most 118 us (datasheet 120) and at least 64 us released after a write-0 (datasheet 1 us),
   so the device watcher can ignore the line between s0 + 13 and s0 + 118 of a long pull. The
   firmware's write slot is 130 us instead of about 70 us.
3. **One guard per watcher.** The device watcher's guard is taken by B21 (spontaneous low), so its
   classification uses `skip` instead.
4. **Seven window values.** The table is full; B24's upper bound is 480 steps instead of 241 (lenient).
5. **No negated elapsed term.** After a short pull, a second pull that starts and ends inside
   s0 + 1 .. s0 + 12 is not detected (documented gap).
6. **Synchroniser lag.** With free ticks (P = 0) the input synchroniser lags the bus by up to 2
   steps; a device check must not read the line in the first 2 steps after a chip release.
7. Single-modifier rule: one elapsed or register modifier per instruction; `expect` with an
   elapsed predicate after a `hold` works, combined forms do not.

## 4. Host-side findings

- A host write to a full TX FIFO is dropped silently. The 1-Wire driver waits for TX room before
  every push (`OneWire._wait_room`); the generic `Pemu.tx_push` does not check (doc/host.md).
- Timeouts must cover writes still queued in TX (about 1 ms per 1-Wire byte).

## 5. Reproduce

    dune build @flex_v2/test/runtest
    cd test/demo && DEMO_OUT=$PWD/results/rtl_flex make COCOTB_TEST_MODULES=test_flex FST=
    # gate level: add GATES=yes GL_NETLIST=<final nl> PDK_ROOT=<repo>/.toolchain/pdk, DEMO_OUT=.../gl_flex
    python3 compare_flex.py results/rtl_flex results/gl_flex
