#!/usr/bin/env bash
# Local SG13CMOS5L mapping estimate (approximates LibreLane's Yosys synthesis; NOT the TT flow).
# usage: flow/map/map_cmos5l.sh <flop|macro|top> [abc_delay_ps]   (top = wrapper + flop core, for local GL replay)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
V="$1"; DPS="${2:-20000}"
PDK="$ROOT/.toolchain/pdk/ihp-sg13cmos5l"
LIB="$PDK/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib"
SLIB="$PDK/libs.ref/sg13cmos5l_sram/lib/RM_IHPSG13_1P_64x16_c2_typ_1p20V_25C.lib"
LT="$PDK/libs.tech/librelane/sg13cmos5l_stdcell"
DU=""; for c in $(cat "$LT/synth_exclude.cells"); do DU="$DU -dont_use $c"; done
OUT="$ROOT/flow/map/out/$V"; mkdir -p "$OUT"
case "$V" in
  flop)  SRC="read_verilog $ROOT/src/pemu_core.v"; TOP=pemu_core ;;
  macro) SRC="read_liberty -lib $SLIB; read_verilog $ROOT/src/pemu_core_macro.v"; TOP=pemu_core_macro ;;
  top)   SRC="read_verilog $ROOT/src/tt_um_dean_protocol_emulator.v $ROOT/src/pemu_core.v"; TOP=tt_um_dean_protocol_emulator ;;
esac
cat > "$OUT/map.ys" <<YS
read_liberty -lib $LIB
$SRC
hierarchy -check -top $TOP
synth -top $TOP -flatten
techmap -map $LT/mux4_map.v
techmap -map $LT/mux2_map.v
techmap -map $LT/latch_map.v
simplemap
dfflibmap -liberty $LIB $DU
abc -liberty $LIB -D $DPS $DU
hilomap -singleton -hicell sg13cmos5l_tiehi L_HI -locell sg13cmos5l_tielo L_LO
setundef -zero
splitnets
opt_clean -purge
insbuf -buf sg13cmos5l_buf_1 A X
check
tee -o $OUT/stat.txt stat -liberty $LIB $( [ "$V" = macro ] && echo "-liberty $SLIB" )
stat -json -liberty $LIB $( [ "$V" = macro ] && echo "-liberty $SLIB" )
write_verilog -noattr $OUT/netlist.v
YS
yosys -q -l "$OUT/yosys.log" -s "$OUT/map.ys" > "$OUT/stat.json.raw"
echo "done $V"
