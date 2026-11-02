#!/usr/bin/env bash
# E4/E5 for v2 builds (pemu_core_v1m + two RM_IHPSG13_1P_256x16_c2_bm_bist): RTL (tt_um wrapper +
# core, as hardened, from GDS_logs/src) == SG13CMOS5L netlists of the Tiny Tapeout CI run.
#   E4  LibreLane post-synthesis netlist (runs/wokwi/06-yosys-synthesis/<top>.nl.v)
#   E5  final netlist (tt_submission/<top>.v)
# SRAM cut (flow/equiv/macro_cut.py): both macros are removed on both sides. Their data outputs come
# from one SHARED free input per macro, and all their other pins (A_CLK excepted) are compared with
# the chip outputs. Claim: from the all-zero power-up state of every flop on both sides, for every
# input sequence on clk/rst_n/ena/ui_in/uio_in AND every SRAM output sequence, uo_out/uio_out/uio_oe
# and the 2 x 89 macro input bits agree in every cycle. This covers the real macros, which are
# identical on both sides and see identical inputs. Cell semantics: read_liberty functional models of
# the typ liberty (independent of the PDK Verilog models of the gate-level replay). Engine: ABC dprove.
# Negative controls (must FAIL): N1 uo_out[0] inverted, N2 uio_in[5] input buffer inverted (as the
# v0.1 script), N3 SRAM-0 address MSB inverted at the macro (visible only through the macro-pin compare).
# The v0.1 script with the full SRAM models (VARIANT=v1m) timed out at 3,000 s on E4 (20,320 latches).
# usage: flow/equiv/run_equiv_v1m.sh <ci-artifacts-dir> [timeout_s]   (run from the repo root)
set -u
CI=${1:?ci artifacts dir}; TMO=${2:-1800}
TOP=tt_um_dean_protocol_emulator
W=${WORK:-flow/equiv/work_v1m}; mkdir -p "$W"
LIB=.toolchain/pdk/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib
[ -f "$LIB" ] || { echo "missing $LIB (run tools/fetch_pdk.sh)"; exit 2; }
GD=$(ls -d "$CI"/GDS_logs* | head -1); TS=$(ls -d "$CI"/tt_submission* | head -1)
SRC="$GD/src"
N_SYN="$GD/runs/wokwi/06-yosys-synthesis/$TOP.nl.v"
N_FIN="$TS/tt_submission/$TOP.v"
echo "variant=v1m-cut commit=$(grep -o '"commit": *"[0-9a-f]*' "$TS/tt_submission/commit_id.json" | grep -o '[0-9a-f]*$' | cut -c1-7)"

python3 flow/equiv/macro_cut.py rtl "$SRC/pemu_core_v1m.v" "$SRC/$TOP.v" "$W/rtl_core.v" "$W/rtl_wrap.v" >/dev/null || exit 2
yosys -q -p "read_liberty -ignore_miss_func $LIB; write_verilog -noattr $W/cells.v" || exit 2
cat > "$W/miter.v" <<EOF
module eq_top (input clk, input rst_n, input ena, input [7:0] ui_in, input [7:0] uio_in,
               input [15:0] md0, input [15:0] md1, output bad);
  wire [7:0] ao, aio, aoe, bo, bio, boe;
  wire [88:0] ap0, ap1, bp0, bp1;
  $TOP   a (.clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui_in), .uio_in(uio_in), .uo_out(ao), .uio_out(aio), .uio_oe(aoe),
            .mdout_l0(md0), .mdout_l1(md1), .mpin_l0(ap0), .mpin_l1(ap1));
  ${TOP}_b b (.clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui_in), .uio_in(uio_in), .uo_out(bo), .uio_out(bio), .uio_oe(boe),
            .mdout_l0(md0), .mdout_l1(md1), .mpin_l0(bp0), .mpin_l1(bp1));
  assign bad = (ao != bo) | (aio != bio) | (aoe != boe) | (ap0 != bp0) | (ap1 != bp1);
endmodule
EOF

prove() {  # <name> <cut netlist>
  local n=$1 nl=$2
  sed -E "s/^module $TOP([ (])/module ${TOP}_b\\1/" "$nl" > "$W/$n.nl.v"
  grep -q -E "^module ${TOP}_b[ (]" "$W/$n.nl.v" || { echo "$n: rename failed"; return; }
  yosys -q -l "$W/$n.yosys.log" -p "read_verilog $W/cells.v; read_verilog $W/rtl_wrap.v $W/rtl_core.v;
    read_verilog $W/$n.nl.v; read_verilog $W/miter.v; hierarchy -check -top eq_top; proc -norom; flatten;
    memory -nomap -nordff; memory_map; setundef -zero -init; async2sync;
    opt -keepdc -fast; techmap; opt -keepdc -fast; dffunmap; aigmap; setundef -zero;
    tee -o $W/$n.stat stat; write_aiger -zinit -miter -map $W/$n.map $W/$n.aig" >/dev/null 2>&1 \
    || { echo "$n: yosys ERROR (see $W/$n.yosys.log)"; return; }
  local undr=$(grep -i "undriven\|no driver" "$W/$n.yosys.log" | grep -v -E "eq_top\.\\\\(ui_in|uio_in|rst_n|ena|clk|md0|md1)|Treating a total of" | wc -l | tr -d ' ')
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

python3 flow/equiv/macro_cut.py gate "$N_SYN" "$W/syn_cut.v" >/dev/null || exit 2
python3 flow/equiv/macro_cut.py gate "$N_FIN" "$W/fin_cut.v" >/dev/null || exit 2
prove e4_synth "$W/syn_cut.v"
prove e5_final "$W/fin_cut.v"
# N1: invert uo_out[0] at its driving flop in the final netlist
perl -pe 's/\.Q\(uo_out\[0\]\)/.Q(neg_q0)/' "$W/fin_cut.v" | perl -0pe 's/(\n endmodule|\nendmodule)/\n assign uo_out[0] = ~neg_q0;\n wire neg_q0;$1/' > "$W/neg1_src.v"
grep -q "assign uo_out\[0\] = ~neg_q0" "$W/neg1_src.v" || echo "N1 edit did not apply"
prove n1_final_out_inverted "$W/neg1_src.v"
# N2: replace the uio_in[5] input buffer by an inverter in the final netlist
perl -0pe 's/sg13cmos5l_buf_1 (\S+) \(\.A\(uio_in\[5\]\),\s*\n\s*\.X\(/sg13cmos5l_inv_1 $1 (.A(uio_in[5]),\n    .Y(/' "$W/fin_cut.v" > "$W/neg2_src.v"
grep -q "sg13cmos5l_inv_1 [^ ]* (.A(uio_in\[5\])" "$W/neg2_src.v" || echo "N2 edit did not apply"
prove n2_final_uio5_inverted "$W/neg2_src.v"
# N3: invert the SRAM-0 address MSB at the macro pin in the final netlist
python3 flow/equiv/macro_cut.py gate "$N_FIN" "$W/neg3_src.v" --flip-addr0 >/dev/null || echo "N3 edit did not apply"
prove n3_final_sram0_addr_inverted "$W/neg3_src.v"
