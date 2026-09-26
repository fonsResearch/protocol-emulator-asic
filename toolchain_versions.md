# Toolchain versions (verified 2026-09-27)

Host: macOS 27.0, Apple Silicon. Compiler: Apple clang 21.0.0 (clang-2100.3.34.2), from the Command Line Tools selected with `xcode-select`.

To set up a shell: `source tools/env.sh`. To re-verify everything: `flow/smoke/run_smoke.sh`; its last run is in `smoke_test.log`.

## OCaml / Hardcaml (opam switch `hardcaml`, installed by the user from the official install script)

| Package | Version |
|---|---|
| ocaml (ocaml-base-compiler) | 5.3.0 |
| dune | 3.24.2 |
| hardcaml | v0.17.1 |
| ppx_hardcaml | v0.17.1 |
| hardcaml_waveterm | v0.17.0 |
| hardcaml_verify | v0.17.0 |
| ppx_expect | v0.17.3 |
| ppx_jane | v0.17.0 |
| core | v0.17.2 |
| zarith | 1.14 |

hardcaml v0.17.1 requires OCaml >= 5.3.0 (from its opam metadata).

Note: the installed hardcaml_verify is v0.17.0. The earlier API reading in the project notes came from the GitHub master branch (commit 53dc7d8, 2026-05-15). Check v0.17.0's `nusmv.mli` before relying on that API.

## Formal and simulation tools (built from source into `.toolchain/eda`, gitignored)

| Tool | Version / revision | Notes |
|---|---|---|
| Yosys (+ yosys-abc, yosys-smtbmc, yosys-witness) | v0.69, git 9f75ca1f9834a39a863915b5dae0c7b1e33533bc | Source tarball from codeload.github.com plus submodule tarballs (abc a51bf4a7bb38ce06ea3a544b1463b40832213917, others at their v0.69 pins). `abc/.gitcommit` written by hand, which the build needs when building outside git. CMake flags: `-DYOSYS_WITHOUT_TCL=ON -DYOSYS_WITHOUT_READLINE=ON -DYOSYS_WITHOUT_EDITLINE=ON -DYOSYS_WITHOUT_LIBFFI=ON -DYOSYS_USE_BUNDLED_LIBS=ON -DYOSYS_ENABLE_HOMEBREW=OFF`, bison 3.8.2 / GNU m4 1.4.21 / flex 2.6.4 from conda. The binary links only system libraries. |
| SymbiYosys (sby) | v0.69, git b1a1e98cba941ec8433f8dc27f416cd7bb7f14be | `make install PREFIX=.toolchain/eda`; requires Python `click` |
| Icarus Verilog | v13_0, git dfeee909ed9f20b4870dd93423156c0170c0e1ff | Configured with conda bison/flex/gperf. The system bison 2.3 fails on `parse.y`. |

## From conda environment `hwverif` (conda-forge)

| Tool | Version |
|---|---|
| z3 | 5.1.0 |
| verilator | 5.052 |
| cocotb | 2.0.1 (pinned to match `test/requirements.txt`) |
| pytest | 8.4.2 |
| Python | 3.12 |

## Findings from setup that matter later

1. **cocotb version and the TT CI check.** cocotb 2.1.0 writes `failures="0"` into `results.xml`, and the TT workflow check `! grep failure results.xml` then fails on a passing run. The template pins cocotb 2.0.1, which does not write that attribute. Keep the pin.
2. **Uninitialised registers in formal.** Hardcaml registers without reset or clear are emitted as `reg` with no initialiser. `write_aiger -zinit` turns them into free initial state, so a correct design is "refuted" at frame 0. The smoke test uses `setundef -zero -init` to match cyclesim's zero initial state. The real design must instead prove from reset: registers take reset values and the formal harness asserts reset in the first cycle. Silicon has no zero initial state.
3. **Expect tests need reading, not just promoting.** The first smoke expect test printed a reversed trace, because Core's `List.init` evaluates a side-effecting `f` from the last index. Fixed with an explicit loop. Promoted expect output is only an oracle once a human has read it.
4. **Sandbox limits on this host** (these affect agent sessions, not your own terminal):
   - GitHub release assets and raw.githubusercontent.com return proxy 502.
   - Files named `.gitmodules` cannot be created.
   - opam 2.5.0 from conda-forge aborts (SIGABRT) during large tree copies.
   - Hence opam and the switch were installed by the user outside the sandbox, and the EDA tools were built from source tarballs.
5. **No BTOR2 engine installed yet.** Yosys writes BTOR2 (`write_btor` works), but no BTOR2 model checker (btormc, Pono, rIC3, AVR) is installed. The formal flow currently uses AIGER + ABC `pdr`/`bmc3` and SMT via `yosys-smtbmc` + z3 (k-induction).
6. **sby + abc pdr on a failing property.** It reports FAIL correctly, but the task ends in ERROR (rc=16) because trace conversion fails. Direct `yosys-abc` gives the failing frame, and the smtbmc engine produces VCD and Yosys witness traces. Worth investigating before relying on sby-pdr counterexamples.

## Stale directories to remove (gitignored)

`.toolchain/opam`, `.toolchain/opam-*.log`, `.toolchain/exttest`, `.toolchain/cptest` are left over from the failed conda-opam attempt. They will be moved to Trash with your approval.
