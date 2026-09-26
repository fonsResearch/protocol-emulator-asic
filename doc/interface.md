# Interface contract v0 (shared by spec and RTL)

Status: APPROVED v0.1 (2026-09-27), together with `doc/isa/isa_v0.md`. Pin assignments apply to the vertical slice only.

## 1. Core boundary

The core sits inside the hand-written wrapper `src/tt_um_dean_protocol_emulator.v`.

- **Reset:** the core sees `rst_sync_n`, which is asserted asynchronously and released synchronously by the wrapper's 2-flop synchroniser. While `rst_sync_n` = 0, all core registers except `imem` hold their reset values (ISA section 2).
- **`ena`:** ignored.

## 2. Pin map (slice)

| Pin | Direction | Function |
|---|---|---|
| `ui_in[7]` | in | RUN. 1 = execute, 0 = halt / load mode |
| `ui_in[6]` | in | WSTB, program-load write strobe (load mode only) |
| `ui_in[5:0]` | in | unused in v0 |
| `uio_in[7:0]` | in | Load data byte (load mode); `IN` data (run mode) |
| `uo_out[7:0]` | out | `out` register (ISA section 2) |
| `uio_out[7:0]` | out | constant 0 in v0 |
| `uio_oe[7:0]` | out | constant 0 in v0; all `uio` pins are inputs |

## 3. Input synchronisation

Every input the core uses (`ui_in[7]`, `ui_in[6]`, `uio_in[7:0]`) passes through a 2-flop synchroniser inside the core: `s1 <- pin` and `s2 <- s1` at every edge. Consequently:

- During cycle c, `s2` holds the pin value sampled at edge e_{c-1}.
- `running` during cycle c equals `s2(RUN)` during cycle c. The halted/running rule in ISA section 3 uses this value.
- The synchroniser flops (`s1`, `s2`, and the extra WSTB stage used for edge detection) reset to 0 while `rst_sync_n` = 0. After reset is released, `running` is therefore 0 for at least the first 2 cycles.
- Formal and simulation models assume each asynchronous input is stable around the sampling edge, so no metastability is modelled. This is an assumption; it is stated in every proof report.

## 4. `IN` sampling

An `IN` executing in cycle c loads `sr` <- `s2(uio_in)` during cycle c, which is the `uio_in` value sampled at edge e_{c-1}.

## 5. Program load (only when `running` = 0)

State: `load_addr` (6 bits), `load_hi` (1 bit), `load_lo` (8 bits). These are held at 0 during every cycle in which `running` = 1 and after reset, so each load session starts at address 0.

1. A write event happens in cycle c if `s2(WSTB)` = 1 during cycle c and was 0 during cycle c-1 (rising edge of the synchronised strobe).
2. On a write event with `load_hi` = 0: `load_lo` <- `s2(uio_in)`, and `load_hi` <- 1.
3. On a write event with `load_hi` = 1: `imem[load_addr]` <- {`s2(uio_in)`, `load_lo`} (high byte from this event, low byte from the previous one); `load_addr` <- `load_addr` + 1; `load_hi` <- 0.
4. Host timing requirement: `uio_in` must be stable from at least 3 cycles before each WSTB rising edge until 3 cycles after it. WSTB must stay high at least 3 cycles and low at least 3 cycles.
5. A word is therefore sent low byte first. Addresses auto-increment from 0, and more than 64 words wrap around to address 0.

## 6. Observables used by verification

- **Pin trace (S2):** per cycle, (`uo_out`, `uio_out`, `uio_oe`) and the raw input pins (`ui_in`, `uio_in`).
- **Proof observation relation:** the spec and RTL must agree on `uo_out`, `uio_out` and `uio_oe` in every cycle, given the same raw input pin sequence and the same `imem` contents at the start of the run.
