# protocol-emulator-asic

A firmware-programmable protocol emulator with an on-chip assumption monitor, for the Jane Street
protocol emulator ASIC competition, on Tiny Tapeout IHP SG13CMOS5L (6x4 tiles, 30 MHz). RTL in
Hardcaml (OCaml), emitted as Verilog for the Tiny Tapeout flow.

Two lanes run protocol firmware; a monitor checks each lane's pins against a package contract and
reports a guarantee violation as *fail* (the chip's fault) or an assumption violation as *blame*
(the attached device's fault). Shipped packages: UART TX/RX, SPI controller/target (mode 0), I2C
controller Fm/Sm, I2C target Sm, USB-LS TX.

Status (2026-11-11): tape-out candidate on branch `v2-inc5-usb`, signed off by CI (slow-corner
setup slack +5.83 ns, 48.6 % utilisation, DRC/LVS/antenna clean). Not tested on silicon.

| topic | document |
|---|---|
| **verification write-up (start here)** | `doc/verification.md` |
| architecture overview | `doc/architecture_v2.md` |
| concept (assume-guarantee) | `doc/concept/assume_guarantee.md` |
| lane ISA, host interface, monitor | `doc/isa/isa_v1.md`, `doc/interface_v1.md`, `doc/contracts/monitor_isa_v1.md` |
| contract language, protocol packages | `doc/contracts/language_v1.md`, `doc/protocols/` |
| assembler and contract compiler | `doc/toolchain.md` |
| host package (RP2350, MicroPython) | `doc/host.md` |
| proofs and verification results | `log/proofs_v2.md`, `log/protocols_v2.md`, `log/witness_v2.md`, `log/campaign_v2.md`, `log/demo_v2.md` |
| physical design and sign-off | `log/ci_results_v2.md`, `log/increments_v2.md` |
| held-out protocol (1-Wire, after freeze) | `log/flexibility_v2.md`, `doc/protocols/onewire_v1.md` |
| one-command reproduction | `tools/reproduce.sh <tier>`, tiers quick, sim, proofs, r1, witness, all |
| change log of frozen documents | `doc/CHANGES.md` |

## Licence

MIT; see LICENSE. Files imported from the Tiny Tapeout template keep their original Apache-2.0 notices.
