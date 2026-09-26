# Interface contract (shared by spec and RTL)

Status: placeholder. Filled in together with doc/isa/isa_v0.md, which requires user approval.

Will define:
- Pin mapping of `ui_in`, `uo_out`, `uio_*` to emulator lanes and the host/program-load port.
- Program-load protocol (how instruction memory is written after reset).
- Reset behaviour at the core boundary (the core sees `rst_sync_n` from the wrapper).
- Input sampling latency guaranteed by the wrapper plus core.
