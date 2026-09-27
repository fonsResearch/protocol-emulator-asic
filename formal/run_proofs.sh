#!/usr/bin/env bash
# Build formal harnesses (Hardcaml -> Verilog), convert with Yosys to AIGER miters, and run
# ABC. Usage (repo root, after `source tools/env.sh`):
#   formal/run_proofs.sh [harness-name-regex] [pdr-timeout-seconds]
# Results table: formal/work/results.md (per run) - copy into log/ when recording.
set -u
FILTER=${1:-.}
TMO=${2:-900}
B=${BUILD_DIR:-$TMPDIR/_build_pemu}
W=formal/work; mkdir -p $W/v $W/aig
dune build --root . --build-dir "$B" formal/bin/emit_formal.exe formal/bin/replay_cex.exe 2>&1 | grep -v xcrun_db
"$B/default/formal/bin/emit_formal.exe" $W/v > $W/harnesses.txt || exit 1

echo "| harness | expected | engine | result | depth/frames | inputs/latches/ands | wall s | cex replay |" > $W/results.md
echo "|---|---|---|---|---|---|---|---|" >> $W/results.md
for h in $(grep -E "$FILTER" $W/harnesses.txt); do
  if [[ $h == *neg* ]]; then expected=FAIL; else expected=PASS; fi
  # Initial state = reset state: every FF gets init 0 immediately after proc, BEFORE any opt
  # pass (otherwise opt_dff may exploit the undefined init, e.g. replace a synchroniser flop
  # whose D is constant by that constant). SRAM output registers (rtl_imem_dout*) are then
  # stripped of init and stay free. All opt passes use -keepdc so free init values are not
  # exploited either. The final 'setundef -zero' only touches x constants introduced by Yosys
  # (the Hardcaml Verilog contains no x literals; checked by grep below).
  if grep -q -E "'b?x|[0-9]'hx" $W/v/$h.v; then echo "| $h | $expected | - | X-LITERAL | | | |" >> $W/results.md; continue; fi
  yosys -q -l $W/aig/$h.yosys.log -p "
    read_verilog $W/v/$h.v; hierarchy -check -top $h; proc;
    setundef -zero -init;
    setattr -unset init w:rtl_imem_dout*;
    flatten; opt -keepdc -fast; memory -nomap; memory_map; opt -keepdc -fast;
    techmap; opt -keepdc -fast; dffunmap; aigmap; setundef -zero;
    write_aiger -zinit -miter -map $W/aig/$h.map $W/aig/$h.aig" >/dev/null 2>&1 || { echo "| $h | $expected | yosys | ERROR | | | |" >> $W/results.md; continue; }
  stats=$(yosys-abc -c "read_aiger $W/aig/$h.aig; print_stats" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -o -E "i/o = *[0-9]+/ *[0-9]+ *lat = *[0-9]+ *and = *[0-9]+" | tr -s ' ')
  # Engines: a1_miter* (full-program refinement, 2x1024 memory bits) -> dprove (signal
  # correspondence + k-induction; PDR alone timed out at 1200 s in frame 18). Other positive
  # claims -> pdr. Other negative controls -> bmc3.
  t0=$(date +%s)
  if [[ $h == a1_miter* ]]; then
    engine="dprove"
    out=$(yosys-abc -c "read_aiger $W/aig/$h.aig; dprove -v -T $TMO; write_cex -a $W/aig/$h.cex" 2>&1)
    if echo "$out" | grep -q "Networks are equivalent"; then res=PASS
    elif echo "$out" | grep -q -i -E "NOT EQUIVALENT|asserted in frame|failed in frame"; then res=FAIL
    else res=UNDECIDED; fi
    depth=$(echo "$out" | grep -o -E "(asserted|failed) in frame [0-9]+" | grep -o -E "[0-9]+$" | head -1)
  elif [ $expected = FAIL ]; then
    engine="bmc3"
    out=$(yosys-abc -c "read_aiger $W/aig/$h.aig; bmc3 -F 400 -T $TMO; write_cex -a $W/aig/$h.cex" 2>&1)
    res=$(echo "$out" | grep -q "asserted in frame" && echo FAIL || echo "no-cex")
    depth=$(echo "$out" | grep -o -E "asserted in frame [0-9]+" | grep -o -E "[0-9]+$")
  else
    engine="pdr"
    out=$(yosys-abc -c "read_aiger $W/aig/$h.aig; pdr -T $TMO; write_cex -a $W/aig/$h.cex" 2>&1)
    if echo "$out" | grep -q "Property proved"; then res=PASS
    elif echo "$out" | grep -q "asserted in frame"; then res=FAIL
    else res=UNDECIDED; fi
    depth=$(echo "$out" | grep -o -E "asserted in frame [0-9]+" | grep -o -E "[0-9]+$" | head -1)
  fi
  t1=$(date +%s)
  echo "$out" > $W/aig/$h.abc.log
  replay=""
  if [ "$res" = FAIL ]; then
    if "$B/default/formal/bin/replay_cex.exe" $h $W/aig/$h.cex $W/aig/$h.map > $W/aig/$h.replay.txt 2>&1
    then replay="replay ok"; else replay="REPLAY MISMATCH"; fi
  fi
  echo "| $h | $expected | $engine | $res | ${depth:-} | $stats | $((t1 - t0)) | $replay |" | tee -a $W/results.md
done
