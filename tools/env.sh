# Put the project toolchain on PATH. Usage: source tools/env.sh
#
# - OCaml / Hardcaml: opam switch "hardcaml" (OCaml 5.3.0) in ~/.opam
# - Yosys, yosys-abc, yosys-smtbmc, sby, iverilog: built from source into .toolchain/eda
#   (toolchain_versions.md lists exact revisions and build flags)
# - z3, verilator, cocotb: conda environment "hwverif", or any install already on PATH
#
# .toolchain/ is gitignored. toolchain_versions.md explains how to rebuild it.

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

if command -v opam >/dev/null 2>&1; then
  eval "$(opam env --switch=hardcaml --set-switch)"
elif [ -d "$HOME/.opam/hardcaml/bin" ]; then
  export OPAM_SWITCH_PREFIX="$HOME/.opam/hardcaml"
  export PATH="$OPAM_SWITCH_PREFIX/bin:$PATH"
  export CAML_LD_LIBRARY_PATH="$OPAM_SWITCH_PREFIX/lib/stublibs:$OPAM_SWITCH_PREFIX/lib/ocaml/stublibs"
fi

export PATH="$_repo_root/.toolchain/eda/bin:$PATH"
unset _repo_root
