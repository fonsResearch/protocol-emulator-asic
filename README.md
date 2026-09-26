# protocol-emulator-asic

A firmware-programmable protocol emulator ASIC for the Jane Street protocol emulator ASIC competition, targeting Tiny Tapeout on IHP SG13CMOS5L (6x4 tiles).

The RTL is written in Hardcaml (OCaml) and emitted as Verilog for the Tiny Tapeout flow.

The project is verification-led. Its goal is an end-to-end result: shipped protocol programs, running on the taped-out netlist, are proven to produce pin traces that satisfy protocol monitors. That proof is cross-checked by spec-free timed self-consistency (QED) and by mutation analysis.

Status: repository initialized. No functional logic yet.

## Licence

MIT; see LICENSE. Files imported from the Tiny Tapeout template keep their original Apache-2.0 notices.
