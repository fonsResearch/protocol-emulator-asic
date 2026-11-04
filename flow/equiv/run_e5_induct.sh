#!/usr/bin/env bash
# E4/E5 by register correspondence + induction (Yosys equiv_make / equiv_induct) on the SRAM-cut
# pair produced by run_equiv_v1m.sh (rtl_core.v, rtl_wrap.v, cells.v, fin_cut.v | syn_cut.v).
#
# Method notes (each found by a reduced experiment, see log/ci_results_v2.md section 5):
#  - equiv_induct runs WITHOUT a preceding equiv_simple. With equiv_simple first, the reset
#    synchroniser pairs are marked proven and equiv_induct no longer constrains them; on the
#    34-flop mon_now sub-circuit that turns 66/66 proven into 0/64.
#  - gold is bit-blasted (simplemap) and opt_merge'd, so duplicate bit-level flops (e.g. the
#    s2_ui / _2099 ui_in synchronisers) merge as they did in synthesis; otherwise the dropped
#    duplicate has no gate partner and is free in the induction.
#  - false name pairs (one-hot recoded FSM bits, misnamed nets) and reachable-state invariants are
#    handled by equiv_aug.py with a per-build map (flow/equiv/maps/).
# Claim, ONLY when equiv_status reports every pair proven (equiv_induct is a single pass: each
# "proven" pair relies on all other pairs, so partial counts are conditional, not partial proofs):
# from any pair of states in which all pairs and invariants agree, the two designs agree on every
# pair, including uo_out, uio_out, uio_oe and both 89-bit macro input buses, for all inputs and
# all SRAM outputs. That reset brings both designs into such a state is argued, not mechanised
# (log/ci_results_v2.md section 5.2).
# usage: [SEQ=2] flow/equiv/run_e5_induct.sh <work dir> <map.json> <tag> [fin_cut.v|syn_cut.v]
set -u
W=${1:?work}; MAP=${2:?map}; TAG=${3:?tag}; GATE=${4:-fin_cut.v}
python3 "$(dirname "$0")/equiv_aug.py" "$MAP" "$W/rtl_core.v" "$W/$GATE" "$W/rtl_core_$TAG.v" "$W/gate_$TAG.v" > "$W/aug_$TAG.txt" || exit 2
cat > "$W/$TAG.ys" <<EOF
read_verilog $W/rtl_wrap.v $W/rtl_core_$TAG.v
hierarchy -top tt_um_dean_protocol_emulator
proc -norom; flatten; async2sync; simplemap; opt_merge; opt_clean; splitnets
rename tt_um_dean_protocol_emulator gold
design -stash gold
read_verilog $W/cells.v
read_verilog $W/gate_$TAG.v
hierarchy -top tt_um_dean_protocol_emulator
proc; flatten; async2sync; opt_clean
rename tt_um_dean_protocol_emulator gate
design -stash gate
design -copy-from gold -as gold gold
design -copy-from gate -as gate gate
equiv_make gold gate equiv
hierarchy -top equiv
async2sync
equiv_induct -seq ${SEQ:-2}
tee -o $W/st_$TAG.txt equiv_status
EOF
s=$(date +%s)
yosys -q -l "$W/$TAG.log" "$W/$TAG.ys" > /dev/null 2>&1
echo "$TAG rc=$? secs=$(( $(date +%s) - s )) $(grep 'Of those cells' "$W/st_$TAG.txt")"
grep -o 'Unproven .*core\.fixh_[^ ]*_gold' "$W/st_$TAG.txt" | sed 's/.*core\./  unproven /'
