#!/usr/bin/env bash
# Std-cell area and logic depth of a core-v1 + monitor-engine build (pemu_core_v1m), SG13CMOS5L.
# This is the flow of the step-6/7 area studies (log/monitor_engine.md section 5,
# log/protocols_v1.md "ROM library area"), committed so that the numbers are reproducible.
# Local estimate only: NOT the TT/LibreLane flow, no wire load, SRAM macros are black boxes
# and not counted.
# usage: flow/map/map_v1m.sh <verilog> <out dir> <typ|slow>
#   typ : abc area mapping at typ 1.20 V 25 C
#   slow: delay-targeted mapping at slow 1.08 V 125 C for 60 MHz (16.67 ns), stime -p gives
#         the logic depth (register to register and IO, no wires)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRCV="$1"; OUT="$2"; CORNER="$3"
LIBD="$ROOT/.toolchain/pdk/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib"
BB="$ROOT/rtl/macros/RM_IHPSG13_1P_256x16_c2_bm_bist/RM_IHPSG13_1P_256x16_c2_bm_bist_bb.v"
mkdir -p "$OUT"
case "$CORNER" in
  typ)  LIB="$LIBD/sg13cmos5l_stdcell_typ_1p20V_25C.lib"; ABC="abc -liberty $LIB" ;;
  slow) LIB="$LIBD/sg13cmos5l_stdcell_slow_1p08V_125C.lib"
        ABC="abc -D 16670 -liberty $LIB -script +strash;dch;map,-D,16670;buffer;upsize,-D,16670;dnsize,-D,16670;stime,-p" ;;
esac
cat > "$OUT/map.ys" <<YS
read_verilog -lib $BB
read_verilog $SRCV
synth -top pemu_core_v1m -flatten
dfflibmap -liberty $LIB
$ABC
opt_clean
tee -o $OUT/stat.txt stat -liberty $LIB
YS
yosys -q -l "$OUT/yosys.log" -s "$OUT/map.ys" > /dev/null
echo "area $(grep -E 'Chip area' "$OUT/stat.txt" | tail -1 | awk '{print $NF}')"
if [ "$CORNER" = slow ]; then grep -E "Delay =" "$OUT/yosys.log" | tail -1 | sed -E 's/.*Delay = *([0-9.]+) ps.*/depth \1 ps/'; fi
