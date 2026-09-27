#!/usr/bin/env bash
# Replay spec-derived vectors through the emitted Verilog with Icarus:
#   1. pemu_core (behavioural SRAM model in Hardcaml)
#   2. pemu_core_macro + the unmodified IHP RM_IHPSG13_1P_64x16_c2 model (-DFUNCTIONAL)
# Run from the repo root after `source tools/env.sh` and generating src/*.v.
set -eu
B=${BUILD_DIR:-$TMPDIR/_build_pemu}
W=${WORK:-$TMPDIR/pemu_macro_sim}; mkdir -p "$W"
M=rtl/macros/RM_IHPSG13_1P_64x16_c2
dune build --root . --build-dir "$B" rtl/bin/dump_vectors.exe 2>&1 | grep -v xcrun_db || true
"$B/default/rtl/bin/dump_vectors.exe" "$W"
iverilog -g2012 -o "$W/behav.vvp" -DTOP=pemu_core rtl/macro_sim/tb_vectors.v src/pemu_core.v
iverilog -g2012 -o "$W/macro.vvp" -DTOP=pemu_core_macro -DFUNCTIONAL rtl/macro_sim/tb_vectors.v \
  src/pemu_core_macro.v "$M/RM_IHPSG13_1P_64x16_c2.v" "$M/RM_IHPSG13_1P_core_behavioral.v"
( cd "$W" && vvp -n behav.vvp | grep -E "RESULT|MISMATCH" )
( cd "$W" && vvp -n macro.vvp | grep -E "RESULT|MISMATCH|ERROR" )
