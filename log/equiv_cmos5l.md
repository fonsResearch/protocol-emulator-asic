# E4/E5: RTL == SG13CMOS5L netlists from TT CI (2026-10-17)

Script: `flow/equiv/run_equiv_cmos5l.sh <ci-artifacts>` (Yosys 0.69 + ABC dprove, local).
Inputs: CI run 39022291276, commit d7eb344 (main, flop-memory core). The RTL side reads `GDS_logs/src` (byte-identical to the repo at d7eb344).

| check | netlist side | result | AIG | time |
|---|---|---|---|---|
| E4 | LibreLane post-synthesis netlist (`06-yosys-synthesis/*.nl.v`) | **PASS** | 19 in / 1 out, 2240 latches, 12302 AND | 2 s |
| E5 | final netlist after placement, CTS, resizer (1,866 buffers incl. 1,202 hold), routing (`tt_submission/*.v`) | **PASS** | same | 2 s |
| N1 (must fail) | E5 netlist with `uo_out[0]` inverted at its flop | FAIL as required, frame 0 | | 0 s |
| N2 (must fail) | E5 netlist with the `uio_in[5]` input buffer replaced by an inverter | FAIL as required, frame 8 (load a word, run it) | | 0 s |

**Claim (fact, under the stated assumptions).** For every input sequence on clk/rst_n/ena/ui_in/uio_in, the RTL wrapper+core and each netlist produce identical
uo_out/uio_out/uio_oe in every cycle, starting from the all-zero state of every flop on both sides.

**Assumptions and limits.**
- Cell semantics come from Yosys `read_liberty` on the typ liberty (`function` and `ff` groups). This is a different description from the PDK
  Verilog UDP models that the GL cocotb replay uses. The two checks share no cell model; both pass.
- The initial state is all zeros on both sides, including the 1,024 instruction-memory flops and the SRAM-model output register. The
  same zero-init assumption as A1 applies: real flops power up arbitrary. E4/E5 relate RTL and netlist; they do not cover power-up behaviour.
- Async reset (the wrapper's 2 synchroniser flops) is modelled with `async2sync` on both sides. No metastability is modelled.
- Timing is not part of the claim; it is covered by STA in CI (log/ci_results.md).
- The netlist side is live in the miter: about 1,120 latches per side, and mutations made only in the netlist flip the verdict.
- 11 Yosys "undriven" notes are the miter's free primary inputs (ui_in[7:6], uio_in[7:0], rst_n), treated as `$anyseq`; no other undriven nets.

Consequence: chained with A1 (spec == RTL on all pins, zero-init) this gives spec == SG13CMOS5L final netlist on all pins, under the
union of both sets of assumptions.

## Macro variant: core-macro @ 0f4d84e (CI run 3, 2026-10-17)

`VARIANT=macro flow/equiv/run_equiv_cmos5l.sh <ci-artifacts>/core-macro`. RTL side: wrapper + `pemu_core_macro.v` as hardened. Both sides
instantiate the unmodified IHP functional model of RM_IHPSG13_1P_64x16_c2 (`rtl/macros`, `-DFUNCTIONAL`), so the check covers all
standard-cell logic around the SRAM. E1 (log/proofs.md) relates that model to pemu_core's behavioural memory.

| check | netlist side | result | AIG | time |
|---|---|---|---|---|
| E4m | LibreLane post-synthesis netlist | **PASS** | 19 in / 1 out, 2240 latches, 14259 AND | 2 s |
| E5m | final netlist (placed, CTS, resizer, routed) | **PASS** | same | 2 s |
| N1m (must fail) | final netlist, `uo_out[0]` inverted | FAIL as required, frame 0 | | 0 s |
| N2m (must fail) | final netlist, `uio_in[5]` buffer replaced by an inverter | FAIL as required, frame 8 | | 0 s |

Regression on the flop variant with the same script revision: E4/E5 PASS, N1/N2 FAIL (unchanged).
Same assumptions as above (zero initial state, including the SRAM-model array and output register; async2sync; liberty cell semantics).
Chain for the macro variant: spec ==(A1, zero-init) pemu_core ==(E1) pemu_core_macro + IHP model ==(E5m) final netlist + IHP model.
The last link treats the SRAM as its IHP functional model; the SRAM's silicon behaviour is outside every claim here.
