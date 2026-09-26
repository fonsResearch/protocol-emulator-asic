#!/usr/bin/env bash
# Toolchain smoke test: Hardcaml -> cyclesim expect tests -> Verilog -> Yosys ->
# AIGER miter -> ABC PDR/BMC, SymbiYosys (smtbmc k-induction + abc pdr), and the
# TT cocotb wrapper test on Icarus. Run from the repo root after `source tools/env.sh`.
set -u
cd "$(dirname "$0")/../.."
S=flow/smoke; W=$S/work; mkdir -p $W $S/out
status=0
step() { echo; echo "### $*"; }
check() { if [ "$1" = "$2" ]; then echo "RESULT: $3 as expected"; else echo "RESULT: UNEXPECTED ($3: got '$1', expected '$2')"; status=1; fi; }

step "versions"
ocamlfind ocamlopt -version | sed 's/^/ocaml /'; dune --version | sed 's/^/dune /'
yosys -V; iverilog -V 2>&1 | head -1; z3 --version
python3 -c "import cocotb; print('cocotb', cocotb.__version__)"

step "Hardcaml expect tests (cyclesim + waveterm)"
dune build --root . @flow/smoke/runtest 2>&1 | grep -v xcrun_db; rc=${PIPESTATUS[0]}
check "$rc" 0 "expect tests"

step "Emit Verilog"
dune build --root . flow/smoke/bin/emit.exe 2>&1 | grep -v xcrun_db
./_build/default/flow/smoke/bin/emit.exe $S/out && ls $S/out

for d in ctr_ok ctr_bug; do
  expect=$([ $d = ctr_ok ] && echo proved || echo "asserted in frame 10")
  step "$d: Yosys -> AIGER miter -> ABC pdr / bmc3"
  yosys -q -p "read_verilog $S/out/$d.v; prep -top ctr; setundef -zero -init; flatten; techmap; opt -fast; dffunmap; aigmap; write_aiger -zinit -miter $W/$d.aig"
  pdr=$(yosys-abc -c "read_aiger $W/$d.aig; pdr" 2>&1 | grep -E "Property proved|asserted in frame" | head -1)
  echo "pdr: $pdr"
  case "$pdr" in *"$expect"*) check ok ok "pdr $d";; *) check "$pdr" "$expect" "pdr $d";; esac
  yosys-abc -c "read_aiger $W/$d.aig; bmc3 -F 20" 2>&1 | grep -E "asserted|No output" | head -1 | sed 's/^/bmc3: /'

  step "$d: SymbiYosys (smtbmc z3 k-induction, abc pdr)"
  # [files] paths in the .sby are relative to the directory sby is started from
  ( cd $S && sby -f --prefix work/sby_$d $d.sby > work/sby_$d.log 2>&1 )
  grep -h -E "summary: engine_0 \(" $W/sby_$d.log | sed 's/^SBY *[0-9:]* *//'
  kind=$(grep -h "sby_${d}_kind\] DONE" $W/sby_$d.log | grep -o -E "PASS|FAIL")
  check "$kind" "$([ $d = ctr_ok ] && echo PASS || echo FAIL)" "sby k-induction $d"
done

step "TT cocotb wrapper test (Icarus)"
make -C test clean >/dev/null 2>&1; make -C test > $W/cocotb.log 2>&1
grep -E "TESTS=" $W/cocotb.log
if grep -q failure test/results.xml; then check fail pass "TT CI grep check"; else check pass pass "TT CI grep check"; fi

echo; [ $status = 0 ] && echo "SMOKE TEST: ALL AS EXPECTED" || echo "SMOKE TEST: UNEXPECTED RESULTS"
exit $status
