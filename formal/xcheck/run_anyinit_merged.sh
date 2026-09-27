#!/usr/bin/env bash
# A1 with arbitrary-but-equal initial instruction memory, via input merging:
# Yosys -> ASCII AIGER (same init rules as prove_one.sh) -> merge_init.py (spec/RTL word k bit b
# share one free init input) -> binary AIGER -> dprove under a wall-clock limit.
# usage: formal/xcheck/run_anyinit_merged.sh <seconds>   (after formal/run_proofs.sh emitted Verilog)
set -u
TMO=${1:-1200}; h=a1_miter_anyinit; V=formal/work/v; W=formal/work/xcheck; mkdir -p $W
yosys -q -l $W/$h.yosys.log -p "read_verilog $V/$h.v; hierarchy -check -top $h; proc -norom; setundef -zero -init; setattr -unset init w:rtl_imem_dout* w:free_*; setattr -set keep 1 w:rtl_imem_dout* %ci1:+[Q] w:free_* %ci1:+[Q]; flatten; opt -keepdc -fast; techmap; opt -keepdc -fast; dffunmap; aigmap; setundef -zero; write_aiger -ascii -zinit -miter -map $W/$h.map $W/$h.aag" || exit 1
python3 formal/xcheck/merge_init.py $W/$h.aag $W/$h.map $W/$h.merged.aig || exit 1
yosys-abc -c "read_aiger $W/$h.merged.aig; print_stats" 2>&1 | grep -o "i/o.*"
t0=$(date +%s)
formal/tlimit.sh $TMO yosys-abc -c "read_aiger $W/$h.merged.aig; dprove -v -T $TMO" > $W/$h.merged.dprove.log 2>&1
echo "rc=$? wall=$(( $(date +%s)-t0 ))s"
grep -E "K-step|Latch-corr|equivalent|UNDECIDED|asserted" $W/$h.merged.dprove.log | tail -6
