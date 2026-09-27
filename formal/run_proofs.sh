#!/usr/bin/env bash
# Build formal harnesses (Hardcaml -> Verilog), convert with Yosys to AIGER miters, run ABC,
# replay counterexamples in cyclesim. Usage (repo root, after `source tools/env.sh`):
#   formal/run_proofs.sh [harness-name-regex] [timeout-seconds]
# Results table: formal/work/results.md. Per-harness logic: formal/prove_one.sh.
set -u
FILTER=${1:-.}
TMO=${2:-900}
export BUILD_DIR=${BUILD_DIR:-$TMPDIR/_build_pemu}
W=formal/work; mkdir -p $W/v $W/aig
dune build --root . --build-dir "$BUILD_DIR" formal/bin/emit_formal.exe formal/bin/replay_cex.exe formal/bin/mutants.exe 2>&1 | grep -v xcrun_db
"$BUILD_DIR/default/formal/bin/emit_formal.exe" $W/v > $W/harnesses.txt || exit 1
echo "| harness | expected | engine | result | depth/frames | inputs/latches/ands | wall s | cex replay |" > $W/results.md
echo "|---|---|---|---|---|---|---|---|" >> $W/results.md
for h in $(grep -E "$FILTER" $W/harnesses.txt); do
  if [[ $h == *neg* ]]; then expected=FAIL; else expected=PASS; fi
  formal/prove_one.sh $h $W/v $W/aig $TMO $expected | tee -a $W/results.md
done
