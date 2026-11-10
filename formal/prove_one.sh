#!/usr/bin/env bash
# Prove one harness. Usage: formal/prove_one.sh <harness> <verilog-dir> <work-dir> <timeout-s> <PASS|FAIL|?>
# Prints one markdown row: | harness | expected | engine | result | depth | stats | wall s | replay |
# Requires tools/env.sh sourced and BUILD_DIR (default $TMPDIR/_build_pemu) containing built exes.
set -u
# stop switch for mutation campaigns (see formal/mutation/one_mutant.sh)
if [ -n "${MUT_DIR:-}" ] && [ -f "$MUT_DIR/STOP" ]; then echo "| $1 | $5 | - | STOPPED | | | | |"; exit 0; fi
h=$1; V=$2; A=$3; TMO=$4; expected=$5
B=${BUILD_DIR:-$TMPDIR/_build_pemu}
mkdir -p $A
# proc -norom: case statements stay mux trees. Otherwise proc_rom infers ROM memories from
# Hardcaml's combinational case blocks, and memory_dff can then fold the (kept) SRAM output
# register into the ROM read port, leaving the read wire undriven (seen on mutant rtl_122).
# Hardcaml emits no real memories here (all storage is registers), so no memory passes.
# Initial state = reset state: every FF gets init 0 immediately after proc, BEFORE any opt
# pass (otherwise opt_dff may exploit the undefined init, e.g. replace a synchroniser flop
# whose D is constant by that constant). SRAM output registers (rtl_imem_dout*) are then
# stripped of init and stay free, as are registers named free_* (harness-declared free
# initial state, e.g. a1_miter_anyinit). Selection is structural (the flip-flops driving any wire
# of that name, then every wire on their Q ports), because Yosys may carry the init attribute
# on a differently named alias of the net (seen on the IHP model's dr_r). They are marked keep: otherwise Yosys may
# delete a never-enabled free register (seen on mutant rtl_6, whose SRAM is never enabled),
# which silently turns its free power-up value into a constant. All opt passes use -keepdc so free init values are not
# exploited either. The final 'setundef -zero' only touches x constants introduced by Yosys
# (the Hardcaml Verilog contains no x literals; checked by grep below).
if grep -q -E "'b?x|[0-9]'hx" $V/$h.v; then echo "| $h | $expected | - | X-LITERAL | | | | |"; exit 0; fi
yosys -q -l $A/$h.yosys.log -p "
  read_verilog $V/$h.v; hierarchy -check -top $h; proc -norom;
  setundef -zero -init;
  select -set ff w:rtl_imem_dout* w:free_* %ci1:+[Q]; select -set qw @ff %co1:+[Q];
  setattr -unset init @qw; setattr -set keep 1 @ff;
  flatten; opt -keepdc -fast;
  techmap; opt -keepdc -fast; dffunmap; aigmap; setundef -zero;
  write_aiger -zinit -miter -map $A/$h.map $A/$h.aig" >/dev/null 2>&1 || { echo "| $h | $expected | yosys | ERROR | | | | |"; exit 0; }
# Undriven-bit guard: the AIGER backend may report top-level input-port bits as "undriven"
# (harmless: each is still exactly one AIGER input); any other undriven bit is an error.
if ! bad_undriven=$(python3 formal/undriven_guard.py $h $A/$h.yosys.log $V/$h.v); then
  echo "| $h | $expected | - | UNDRIVEN ($bad_undriven) | | | | |"; exit 0; fi
# Free-init check: every SRAM output register (16 bits each) must appear as 16 free
# initial-value inputs in the AIGER map; otherwise the model is not the intended one.
# SRAM register names must be unique (no backend-added _<n> suffix): replay maps init values by name.
if grep -q -E "reg \[15:0\] rtl_imem_dout(_[a-z]+)?_[0-9]+;" $V/$h.v; then echo "| $h | $expected | - | DUPLICATE-SRAM-NAME | | | | |"; exit 0; fi
n_dout=$(grep -c -E "reg \[15:0\] rtl_imem_dout(_[a-z]+)?;" $V/$h.v)
n_free=$(awk '$1=="init" && $4 ~ /^rtl_imem_dout/ {print $2}' $A/$h.map | sort -u | wc -l | tr -d ' ')
if [ "$n_free" != "$((16 * n_dout))" ]; then echo "| $h | $expected | - | INIT-CHECK FAIL ($n_free free, expected $((16 * n_dout))) | | | | |"; exit 0; fi
stats=$(yosys-abc -c "read_aiger $A/$h.aig; print_stats" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -o -E "i/o = *[0-9]+/ *[0-9]+ *lat = *[0-9]+ *and = *[0-9]+" | tr -s ' ')
# Engine: ABC dprove for every harness (user decision 2026-09-27). dprove = BMC, then
# sequential reductions (retiming, rewriting, latch correspondence, fraiging), K-step
# induction, interpolation, BDD reachability, PDR. Measured before the switch: 2-10x faster
# than pdr on most harnesses; pdr cannot prove a1_miter (UNDECIDED at 1200 s).
# BMC (bmc3) is used below only to produce a shortest counterexample for cyclesim replay
# (to depth+1 by default; REPLAY_F overrides the depth, since a dprove frame number can come
# from a retimed network and undercount the original depth: v2 campaign, NO-BMC-CEX cases).
t0=$(date +%s)
# ENGINE (default dprove, the project default): ind = ABC k-induction (ind -F ${IND_K:-12}),
# for harnesses whose property carries explicit strengthening invariants; it proves or is
# undecided, never reports a counterexample itself. bmc = bmc3 to ${BMC_F:-60} frames
# (refutation only). The engine is printed in the results row.
engine="${ENGINE:-dprove}"
case "$engine" in
  ind) out=$(formal/tlimit.sh $TMO yosys-abc -c "read_aiger $A/$h.aig; ind -F ${IND_K:-12}" 2>&1) ;;
  bmc) out=$(formal/tlimit.sh $TMO yosys-abc -c "read_aiger $A/$h.aig; bmc3 -F ${BMC_F:-60}" 2>&1) ;;
  *)
# -T bounds only dprove's final PDR stage; the whole call is bounded by formal/tlimit.sh.
out=$(formal/tlimit.sh $TMO yosys-abc -c "read_aiger $A/$h.aig; dprove -v -T $TMO" 2>&1) ;;
esac
# Latch-free models (e.g. a miter that Hardcaml constant-folded) go to CEC, which prints
# UNSATISFIABLE (proved) or SATISFIABLE (counterexample).
if echo "$out" | grep -q -E "Networks are equivalent|^UNSATISFIABLE"; then res=PASS
elif echo "$out" | grep -q -i -E "not equivalent|asserted in frame|failed in frame|^SATISFIABLE"; then res=FAIL
else res=UNDECIDED; fi
t1=$(date +%s)
[ "$res" = UNDECIDED ] && [ $((t1 - t0)) -ge $TMO ] && res=TIMEOUT
depth=$(echo "$out" | grep -o -E "asserted in frame [0-9]+" | grep -o -E "[0-9]+$" | head -1)
echo "$out" > $A/$h.abc.log
# Replay: on any FAIL, obtain a shortest counterexample with bmc3 (PDR/dprove traces need not
# be first failures) and require bad to rise first at exactly its last frame in cyclesim.
replay=""
if [ "$res" = FAIL ]; then
  if echo "$stats" | grep -q -E "^i/o = 0/ ?1 lat = 0 "; then
    # no latches and no inputs (Hardcaml constant-folded the miter): the only trace is one
    # frame with no inputs
    printf "\n\n# DONE\n" > $A/$h.cex; bdepth=0
  else
    bout=$(formal/tlimit.sh ${REPLAY_BMC_T:-$TMO} yosys-abc -c "read_aiger $A/$h.aig; bmc3 -F ${REPLAY_F:-$(( ${depth:-300} + 1 ))} -T ${REPLAY_BMC_T:-$TMO}; write_cex -a $A/$h.cex" 2>&1)
    echo "$bout" > $A/$h.bmc.log
    bdepth=$(echo "$bout" | grep -o -E "asserted in frame [0-9]+" | grep -o -E "[0-9]+$" | head -1)
    [ -n "$bdepth" ] && depth=$bdepth
  fi
  if [ -z "${bdepth:-}" ] && [ "$engine" = dprove ]; then
    # Fallback (v2 campaign): bmc3 cannot reach the failing depth within the limit, which happens
    # when dprove's sequential reductions find the failure much faster than plain BMC. Take
    # dprove's own counterexample (mapped back to this AIG by ABC) and replay it; it need not be a
    # shortest trace, so a kill only requires bad to rise somewhere in the trace in cyclesim.
    formal/tlimit.sh $TMO yosys-abc -c "read_aiger $A/$h.aig; dprove -T $TMO; write_cex -a $A/$h.dcex" > $A/$h.dcex.log 2>&1
    if [ -s $A/$h.dcex ]; then
      formal/tlimit.sh $TMO "$B/default/formal/bin/replay_cex.exe" $h $A/$h.dcex $A/$h.map > $A/$h.replay.txt 2>&1
      if grep -q -E "REPLAY (OK|MISMATCH): bad first rises at frame" $A/$h.replay.txt; then
        replay="replay ok (dprove cex, bad at frame $(grep -o -E 'rises at frame [0-9]+' $A/$h.replay.txt | grep -o -E '[0-9]+$'))"
      else replay="NO-BMC-CEX, dprove cex does not replay"; fi
    else replay="NO-BMC-CEX"; fi
  elif [ -z "${bdepth:-}" ]; then replay="NO-BMC-CEX"
  elif formal/tlimit.sh $TMO "$B/default/formal/bin/replay_cex.exe" $h $A/$h.cex $A/$h.map > $A/$h.replay.txt 2>&1
  then replay="replay ok"; else replay="REPLAY MISMATCH"; fi
fi
echo "| $h | $expected | $engine | $res | ${depth:-} | $stats | $((t1 - t0)) | $replay |"
