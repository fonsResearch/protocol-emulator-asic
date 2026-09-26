# Repository structure

| Path | Contents | Owner context (see isolation_rules.md) |
|---|---|---|
| `doc/isa/` | ISA document, the single source for spec and RTL | Doc (human-approved) |
| `doc/protocols/` | Protocol convention documents (UART, SPI, I2C) used by monitors | Doc |
| `doc/interface.md` | Pin interface and program-load port contract | Doc |
| `spec/` | S1 reference semantics: OCaml interpreter plus Hardcaml spec-as-circuit | Spec |
| `rtl/` | Hardcaml core RTL and the Verilog generator executable | RTL |
| `monitors/` | S3 protocol monitors as Hardcaml circuits (bad output, bounded liveness) | Monitor |
| `trace/` | S2 timed pin-trace format: reader/writer, cyclesim replay | Trace |
| `formal/` | Observer circuits, miters, Yosys scripts, proof logs | Integrator |
| `mutation/` | Mutation operators on the Hardcaml circuit graph, kill matrix | Integrator |
| `flow/` | Equivalence checks (IR, Verilog, netlist), gate-level replay | Integrator |
| `log/` | Disagreement log and proof/runtime records | Integrator |
| `src/` | Tiny Tapeout Verilog: hand-written `tt_um_dean_protocol_emulator.v` wrapper plus the generated core | RTL (generated), wrapper (Doc) |
| `test/` | Tiny Tapeout cocotb tests (RTL and gate-level) | Integrator |
| `docs/` | Tiny Tapeout datasheet (`info.md`) | Doc |
| `.github/workflows/` | Tiny Tapeout CMOS5L gds/test/docs workflows from the template | — |

## Template provenance

The following files come from TinyTapeout/ttihp-verilog-template, branch `cmos5l`, commit b86a2a781484bcab7ba522dc5de540086695a430:
- `src/config.json`
- `.github/workflows/*`
- `test/Makefile`, `test/tb.v`, `test/test.py`, `test/requirements.txt`, `test/README.md`, `test/tb.gtkw`
- `docs/info.md`
- `info.yaml`

Those files are Apache-2.0; see `LICENSE-TinyTapeout`. Changes from the template:
- `info.yaml`: title, author, tiles 6x4, top module, source list.
- `test/Makefile`: source list.
- `test/tb.v`: module name.
- `test/test.py`: replaced by a wrapper idle test.

## Notes

- The workflows reference `TinyTapeout/tt-gds-action@ihp-cmos5l`, a moving branch labelled experimental upstream. Whether to pin it to a commit (for example 3412659, 2026-09-14) is still open.
- `tt_um_dean_protocol_emulator` has not been checked for uniqueness on the shuttle.
- Generated Verilog in `src/` is committed because the GDS action builds from `src/` directly.
