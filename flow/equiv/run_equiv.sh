#!/usr/bin/env bash
# Flow equivalence checks (repo root, tools/env.sh sourced, src/*.v generated):
#  E1  pemu_core (behavioural SRAM) == pemu_core_macro + unmodified IHP functional model
#  E2  pemu_core == its Yosys generic `synth` netlist
#  E3  gate-level replay: the E2 netlist on the spec-derived vectors (Icarus + Yosys simcells)
# Initial state as in formal/prove_one.sh: every FF init 0 before any opt, both memories 0,
# SRAM output registers (rtl_imem_dout, IHP dr_r) free and independent.
set -u
TMO=${1:-600}
W=${WORK:-flow/equiv/work}; mkdir -p $W
M=rtl/macros/RM_IHPSG13_1P_64x16_c2
prove() {  # <name> <expected free init bits> <read commands>
  local n=$1; local want=$2; shift 2
  yosys -q -l $W/$n.yosys.log -p "$*; hierarchy -check -top eq_miter; proc -norom; flatten;
    memory -nomap -nordff; memory_map;
    setundef -zero -init;
    select -set ff w:*rtl_imem_dout* w:*dr_r* %ci1:+[Q]; select -set qw @ff %co1:+[Q];
    setattr -unset init @qw; setattr -set keep 1 @ff;
    opt -keepdc -fast; techmap; opt -keepdc -fast; dffunmap; aigmap; setundef -zero;
    write_aiger -zinit -miter -map $W/$n.map $W/$n.aig" >/dev/null 2>&1 || { echo "$n: yosys ERROR"; return; }
  local free=$(awk '$1=="init"{print $2}' $W/$n.map | sort -u | wc -l | tr -d ' ')
  [ "$free" = "$want" ] || { echo "$n: INIT-CHECK FAIL ($free free init bits, expected $want)"; return; }
  local st=$(yosys-abc -c "read_aiger $W/$n.aig; print_stats" 2>&1 | grep -o -E "i/o = *[0-9]+/ *[0-9]+ *lat = *[0-9]+ *and = *[0-9]+" | tr -s ' ')
  local t0=$(date +%s)
  local out=$(formal/tlimit.sh $TMO yosys-abc -c "read_aiger $W/$n.aig; dprove -v -T $TMO" 2>&1)
  echo "$out" > $W/$n.abc.log
  local res=UNDECIDED
  echo "$out" | grep -q -E "Networks are equivalent|^UNSATISFIABLE" && res=PASS
  echo "$out" | grep -q -i -E "not equivalent|asserted in frame|^SATISFIABLE" && res=FAIL
  echo "$n: $res ($st, free init bits $free, $(( $(date +%s)-t0 )) s)"
}
# E1
prove e1_macro 32 "read_verilog -DCORE_B=pemu_core_macro flow/equiv/miter.v; read_verilog src/pemu_core.v src/pemu_core_macro.v; read_verilog -DFUNCTIONAL $M/RM_IHPSG13_1P_64x16_c2.v $M/RM_IHPSG13_1P_core_behavioral.v"
# E2: generic synthesis of pemu_core, module renamed to pemu_core_b
yosys -q -l $W/synth.log -p "read_verilog src/pemu_core.v; synth -top pemu_core -flatten; rename pemu_core pemu_core_b; stat; write_verilog -noattr $W/pemu_core_synth.v" >/dev/null 2>&1 || echo "synth ERROR"
grep -A3 "Number of cells" $W/synth.log | head -4 | tr -s ' '
prove e2_synth 32 "read_verilog flow/equiv/miter.v; read_verilog src/pemu_core.v; read_verilog $W/pemu_core_synth.v; read_verilog -lib $(yosys-config --datdir)/simcells.v"
# Negative controls (must FAIL): E1 with write-through removed from a copy of the IHP model;
# E2 with uo_out[0] inverted in the netlist (observable by construction; an earlier choice,
# the first AND gate turned into OR, was UNDECIDED at 600 s: masked or deep, so unusable).
sed 's/dr_r<= DIN_MUX;/dr_r<= dr_r;/' $M/RM_IHPSG13_1P_core_behavioral.v > $W/neg_core_behavioral.v
grep -q "dr_r<= dr_r;" $W/neg_core_behavioral.v || echo "neg E1 edit did not apply"
prove e1_macro_neg 32 "read_verilog -DCORE_B=pemu_core_macro flow/equiv/miter.v; read_verilog src/pemu_core.v src/pemu_core_macro.v; read_verilog -DFUNCTIONAL $M/RM_IHPSG13_1P_64x16_c2.v $W/neg_core_behavioral.v"
sed "s/assign uo_out = out;/assign uo_out = out ^ 8'h01;/" $W/pemu_core_synth.v > $W/neg_synth.v
diff -q $W/pemu_core_synth.v $W/neg_synth.v >/dev/null && echo "neg E2 edit did not apply"
prove e2_synth_neg 32 "read_verilog flow/equiv/miter.v; read_verilog src/pemu_core.v; read_verilog $W/neg_synth.v; read_verilog -lib $(yosys-config --datdir)/simcells.v"
# E3: gate-level replay of the synthesised netlist (module renamed back for the testbench)
sed 's/^module pemu_core_b/module pemu_core/' $W/pemu_core_synth.v > $W/pemu_core_gl.v
B=${BUILD_DIR:-$TMPDIR/_build_pemu}
"$B/default/rtl/bin/dump_vectors.exe" $W >/dev/null
iverilog -g2012 -o $W/gl.vvp -DTOP=pemu_core rtl/macro_sim/tb_vectors.v $W/pemu_core_gl.v $(yosys-config --datdir)/simcells.v 2>&1 | head -5
( cd $W && vvp -n gl.vvp | grep -E "RESULT|MISMATCH" | head -3 )
