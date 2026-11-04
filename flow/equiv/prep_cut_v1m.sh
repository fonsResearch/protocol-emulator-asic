#!/usr/bin/env bash
# Prepare the SRAM-cut sources for E4/E5 (same transform as run_equiv_v1m.sh, without the ABC run):
#   rtl_core.v rtl_wrap.v  RTL as hardened (GDS_logs/src), both SRAM macros removed, DOUT as inputs
#   syn_cut.v              post-synthesis netlist (E4), same cut
#   fin_cut.v              final netlist (E5), same cut
#   cells.v                functional models from the typ liberty (read_liberty)
# Then: flow/equiv/run_e5_induct.sh <work> flow/equiv/maps/<map>.json <tag> fin_cut.v|syn_cut.v
# usage: flow/equiv/prep_cut_v1m.sh <ci-artifacts-dir> <work dir>   (run from the repo root)
set -eu
CI=${1:?ci artifacts dir}; W=${2:?work dir}; mkdir -p "$W"
TOP=tt_um_dean_protocol_emulator
LIB=.toolchain/pdk/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib
GD=$(ls -d "$CI"/GDS_logs* | head -1); TS=$(ls -d "$CI"/tt_submission* | head -1)
python3 flow/equiv/macro_cut.py rtl "$GD/src/pemu_core_v1m.v" "$GD/src/$TOP.v" "$W/rtl_core.v" "$W/rtl_wrap.v" > /dev/null
python3 flow/equiv/macro_cut.py gate "$GD/runs/wokwi/06-yosys-synthesis/$TOP.nl.v" "$W/syn_cut.v" > /dev/null
python3 flow/equiv/macro_cut.py gate "$TS/tt_submission/$TOP.v" "$W/fin_cut.v" > /dev/null
yosys -q -p "read_liberty -ignore_miss_func $LIB; write_verilog -noattr $W/cells.v"
echo "prepared $W (commit $(grep -o '"commit": *"[0-9a-f]*' "$TS/tt_submission/commit_id.json" | grep -o '[0-9a-f]*$' | cut -c1-7))"
