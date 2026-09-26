# spec (S1 reference semantics)

This is the executable specification of ISA v0.1 and interface v0.1 (`doc/isa/isa_v0.md`, `doc/interface.md`). It covers the whole observable machine at the core boundary: input synchronisers, the running/halt rule, all opcodes including the reserved NOPs, WAIT, and the byte-wise program-load protocol.

Independence note: the spec was written in the same context as the RTL and the documents. See the status at the top of `isolation_rules.md`.

| File | Contents |
|---|---|
| `src/isa.ml` | Encoding and decoding (`decode` ignores must-be-zero bits), assembler |
| `src/programs.ml` | Reference UART TX program (ISA section 6), known-bad variant, timed-QED transform (section 7) |
| `src/interp.ml` | Pure-OCaml cycle-level interpreter. `outputs st` gives the pins during the current cycle; `step st inputs` applies the edge that ends it |
| `src/spec_circuit.ml` | The same semantics as a Hardcaml circuit (`pemu_spec`). Instruction memory is 64 x 16 registers named `spec_imem_<i>`, read combinationally and written only by the load protocol |
| `test/` | Expect tests: encode/decode, per-instruction timing, UART timeline, QED equivalence of P and T(P), load over pins, and co-simulation of interpreter vs circuit |

Interpretation choices, all taken from the documents literally:
- `rst_sync_n` is a synchronous clear of every register except `imem`, including the synchronisers (interface section 3).
- A write event needs a rising edge of the *synchronised* WSTB (`s2` = 1 while its previous value was 0). Load data is the synchronised `uio_in` in the same cycle.
- WAIT k is modelled with a hidden `(waiting, wait_cnt)` pair. Only its observable effect, k+1 cycles, is specified.

Run the tests (from the repo root, after `source tools/env.sh`, with `/usr/bin` ahead of the conda env on PATH):

    dune build --root . --build-dir $TMPDIR/_build_pemu @spec/runtest

Results at commit time:
- decode/encode is consistent for all 65,536 words.
- Timing traces were checked by hand against ISA sections 4-6.
- P and T(P) give identical traces for 1,024 runs (D in {3,4,5,7} x 256 bytes).
- Co-simulation: 200 random programs, more than 200k cycles, 0 mismatches.
