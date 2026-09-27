# monitors (S3 protocol monitors)

`src/uart_tx_monitor.ml` (library `pemu_monitors`) is the UART 8N1 TX monitor from `doc/protocols/uart.md`: bit period `b` cycles, tolerance 0. It has two implementations:
- `Model`: pure OCaml, using the absolute frame offset k.
- `create ~b` / `circuit ~b`: a Hardcaml circuit using (bit index, phase) counters, which avoids a divider for non-power-of-two `b`. Ports: `clock`, `clear`, `line` -> `bad`, `frame_done`, `frame_data[7:0]`, `timeout`.

The outputs describe the current cycle's observation:
- `bad`: this cycle violates the rules, or an earlier cycle did (sticky).
- `frame_done`: this cycle is offset 10b-1 of a frame with no violation.
- `frame_data`: the decoded byte, valid when `frame_done` is high.
- `timeout`: the line has been low for more than 10b consecutive cycles (sticky).

Rules implemented, all taken from the document:
- Frames start on the first low cycle after the line has been seen idle.
- Within a frame, the line may change only at multiples of b.
- The line is low for offsets 0..b-1 and high for 9b..10b-1.
- Monitoring waits for the line to go high first.

Tests (`test/`):
- Well-formed frames decode at b = 3, 4, 7 with gaps of 0-5 cycles.
- Each negative case raises `bad` at the hand-predicted cycle: start bit b+1 and b-1, an off-grid glitch, stop bit low, line stuck low (with timeout).
- Circuit and model agree on 500 random corrupted sequences (0 mismatches).
- Integration: the monitor on RTL `uo_out[0]` decodes the reference program's bytes with no violation, and flags the known-bad variant.

The integration test also shows `timeout` during reset/program load, because the halted core drives `uo_out = 0x00`, a line break. This is the known v0 halt-value issue (ISA v0.1 section 8.3).
