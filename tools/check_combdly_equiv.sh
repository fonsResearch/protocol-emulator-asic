#!/usr/bin/env bash
# Equivalence of Hardcaml Verilog before and after tools/fix_combdly.py (Yosys equiv_*).
# Usage: tools/check_combdly_equiv.sh <orig.v> <fixed.v> <top> [blackbox-stub.v ...]
set -euo pipefail
O=$1; F=$2; TOP=$3; shift 3
BB=""; for b in "$@"; do BB="$BB read_verilog -lib $b;"; done
yosys -q -p "
  $BB read_verilog $O; hierarchy -top $TOP; proc; flatten; opt_clean; rename $TOP gold; design -stash gold;
  $BB read_verilog $F; hierarchy -top $TOP; proc; flatten; opt_clean; rename $TOP gate; design -stash gate;
  design -copy-from gold -as gold gold; design -copy-from gate -as gate gate;
  equiv_make gold gate equiv; hierarchy -top equiv; equiv_simple -seq 2; equiv_induct; equiv_status -assert" \
  && echo "EQUIVALENT: $O == $F" || { echo "NOT PROVEN EQUIVALENT"; exit 1; }
