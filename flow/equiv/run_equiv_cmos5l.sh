#!/usr/bin/env bash
# E4/E5: RTL (tt_um wrapper + core) == SG13CMOS5L netlists from the Tiny Tapeout CI run.
#   E4  LibreLane post-synthesis netlist (runs/wokwi/06-yosys-synthesis/<top>.nl.v)
#   E5  final netlist after place, CTS, resizer and route (tt_submission/<top>.v; fill/decap/tap
#       cells have no ports and drop out on flatten)
# Cell semantics: Yosys `read_liberty` functional models of the typ liberty (function / ff groups),
# NOT the PDK Verilog UDP models used by the gate-level cocotb replay; the two checks therefore use
# independent cell descriptions.
# Claim: from the all-zero power-up state of every flop on both sides, for every input sequence on
# clk/rst_n/ena/ui_in/uio_in, uo_out/uio_out/uio_oe agree in every cycle. The wrapper's async-reset
# synchroniser flops are converted with async2sync on both sides alike. Engine: ABC dprove.
# Negative controls (must FAIL): N1 uo_out[0] inverted (observable at once), N2 uio_in[5] input
# buffer replaced by an inverter (needs a loaded program to become visible).
#
# usage: flow/equiv/run_equiv_cmos5l.sh <ci-artifacts-dir> [timeout_s]   (repo root, tools/env.sh)
set -u
CI=${1:?ci artifacts dir}; TMO=${2:-900}
TOP=tt_um_dean_protocol_emulator
W=${WORK:-flow/equiv/work_cmos5l}; mkdir -p "$W"
LIB=.toolchain/pdk/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib
[ -f "$LIB" ] || { echo "missing $LIB (run tools/fetch_pdk.sh)"; exit 2; }
SRC="$CI/GDS_logs/src"   # the RTL exactly as hardened
N_SYN="$CI/GDS_logs/runs/wokwi/06-yosys-synthesis/$TOP.nl.v"
N_FIN="$CI/tt_submission/tt_submission/$TOP.v"

yosys -q -p "read_liberty -ignore_miss_func $LIB; write_verilog -noattr $W/cells.v" || exit 2
cat > "$W/miter.v" <<EOF
module eq_top (input clk, input rst_n, input ena, input [7:0] ui_in, input [7:0] uio_in, output bad);
  wire [7:0] ao, aio, aoe, bo, bio, boe;
  $TOP   a (.clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui_in), .uio_in(uio_in), .uo_out(ao), .uio_out(aio), .uio_oe(aoe));
  ${TOP}_b b (.clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui_in), .uio_in(uio_in), .uo_out(bo), .uio_out(bio), .uio_oe(boe));
  assign bad = (ao != bo) | (aio != bio) | (aoe != boe);
endmodule
EOF

prove() {  # <name> <netlist>
  local n=$1 nl=$2
  sed -E "s/^module $TOP([ (])/module ${TOP}_b\\1/" "$nl" > "$W/$n.nl.v"
  grep -q -E "^module ${TOP}_b[ (]" "$W/$n.nl.v" || { echo "$n: rename failed"; return; }
  yosys -q -l "$W/$n.yosys.log" -p "read_verilog $W/cells.v; read_verilog $SRC/$TOP.v $SRC/pemu_core.v;
    read_verilog $W/$n.nl.v; read_verilog $W/miter.v; hierarchy -check -top eq_top; proc -norom; flatten;
    memory -nomap -nordff; memory_map; setundef -zero -init; async2sync;
    opt -keepdc -fast; techmap; opt -keepdc -fast; dffunmap; aigmap; setundef -zero;
    tee -o $W/$n.stat stat; write_aiger -zinit -miter -map $W/$n.map $W/$n.aig" >/dev/null 2>&1 \
    || { echo "$n: yosys ERROR (see $W/$n.yosys.log)"; return; }
  # "undriven" lines for the miter's primary inputs are expected (free inputs, $anyseq); anything else is reported
  local undr=$(grep -i "undriven\|no driver" "$W/$n.yosys.log" | grep -v -E "eq_top\.\\\\(ui_in|uio_in|rst_n|ena|clk)|Treating a total of" | wc -l | tr -d ' ')
  local st=$(yosys-abc -c "read_aiger $W/$n.aig; print_stats" 2>&1 | grep -o -E "i/o = *[0-9]+/ *[0-9]+ *lat = *[0-9]+ *and = *[0-9]+" | tr -s ' ')
  local t0=$(date +%s)
  local out=$(formal/tlimit.sh "$TMO" yosys-abc -c "read_aiger $W/$n.aig; dprove -v -T $TMO" 2>&1)
  echo "$out" > "$W/$n.abc.log"
  local res=UNDECIDED
  echo "$out" | grep -q -E "Networks are equivalent|^UNSATISFIABLE" && res=PASS
  echo "$out" | grep -q -i -E "not equivalent|asserted in frame|^SATISFIABLE" && res=FAIL
  local fr=$(echo "$out" | grep -o -i -E "asserted in frame [0-9]+|frame [0-9]+" | tail -1)
  echo "$n: $res ($st, other-undriven $undr, $(( $(date +%s)-t0 )) s${fr:+, $fr})"
}

prove e4_synth "$N_SYN"
prove e5_final "$N_FIN"
# N1: invert uo_out[0] at its driving flop in the final netlist
perl -pe 's/\.Q\(uo_out\[0\]\)/.Q(neg_q0)/' "$N_FIN" | perl -0pe 's/(\n endmodule|\nendmodule)/\n assign uo_out[0] = ~neg_q0;\n wire neg_q0;$1/' > "$W/neg1_src.v"
grep -q "assign uo_out\[0\] = ~neg_q0" "$W/neg1_src.v" || echo "N1 edit did not apply"
prove n1_final_out_inverted "$W/neg1_src.v"
# N2: replace the uio_in[5] input buffer by an inverter in the final netlist
perl -0pe 's/sg13cmos5l_buf_1 (\S+) \(\.A\(uio_in\[5\]\),\s*\n\s*\.X\(/sg13cmos5l_inv_1 $1 (.A(uio_in[5]),\n    .Y(/' "$N_FIN" > "$W/neg2_src.v"
grep -q "sg13cmos5l_inv_1 [^ ]* (.A(uio_in\[5\])" "$W/neg2_src.v" || echo "N2 edit did not apply"
prove n2_final_uio5_inverted "$W/neg2_src.v"
