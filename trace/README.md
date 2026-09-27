# trace (S2 timed pin-trace format)

`src/pin_trace.ml` (library `pemu_trace`) stores one record per clock cycle. Each record holds the input pins applied in that cycle (`rst_n`, `ui_in`, `uio_in`, sampled at the edge that ends the cycle) and the output pins observed *during* the cycle (`uo_out`, `uio_out`, `uio_oe`, before that edge).

Text format v1, one line per cycle, with a header:

    # pemu-trace v1: cycle rst_n ui_in uio_in uo_out uio_out uio_oe
    0 0 00 00 00 00 00

API:
- `to_string` / `of_string`, `write_file` / `read_file`
- `replay ?rst_port ?skip sim trace` drives any Cyclesim whose ports use the interface names and returns the first output mismatch. `rst_port` defaults to `rst_sync_n` for the core; use `rst_n` for the TT wrapper. `skip` exempts early cycles, for example cycle 0 before the first reset edge.

Tests: the text round trip is exact; a spec-derived trace replays on the RTL with no mismatch; a corrupted sample is reported at the correct cycle.

This format is the common currency for simulation, formal counterexamples, gate-level replay and captured silicon traces.
