#!/usr/bin/env bash
# Formal oracles of one v2 mutant (plan step 9). Usage (repo root, tools/env.sh sourced):
#   formal/mutation/v2/one_formal.sh <unit> <index|id> <timeout-s per harness>
# Writes $MUT_V2/formal/<unit>_<index>/result.txt, one line per harness:
#   <oracle> <markdown row of formal/prove_one.sh>
# Binaries: the snapshot in $MUT_V2/fbin (formal/mutation/v2/snapshot.sh), not _build.
# Scratch (Verilog, AIGER) lives under $SCRATCH (outside the repo); only the result, ABC logs,
# counterexamples and replays are copied to $MUT_V2/formal/<unit>_<index>/. A re-run writes
# result.<n>.txt next to an existing result (FORCE=1); nothing in the repo is deleted.
# Unit "c:<pkg>" runs the contract-mutant harnesses (cemit) of package <pkg>.
set -u
[ -f "${MUT_V2:-formal/work/mut_v2}/STOP" ] && exit 0
u=$1; i=$2; TMO=$3
export MUT_V2=${MUT_V2:-formal/work/mut_v2}
export BUILD_DIR=$(cat $MUT_V2/fbin_current)
export BMC_F=${BMC_F:-20}
M=$BUILD_DIR/default/formal/bin/mutants_v2.exe
D=$MUT_V2/formal/${u/:/_}_$i
[ -f $D/result.txt ] && [ -z "${FORCE:-}" ] && exit 0
X=${SCRATCH:?set SCRATCH to a directory outside the repo}/${u/:/_}_$i.$$
mkdir -p $D $X/v $X/aig
case $u in c:*) emit="cemit ${u#c:}" ;; *) emit="emit $u" ;; esac
{
  $M $emit $i $X/v | while read o e n; do
    case $o in INVALID) echo "INVALID $e $n"; continue ;; esac
    echo "$o $(ENGINE=$e formal/prove_one.sh $n $X/v $X/aig $TMO '?')"
  done
} > $X/result.txt 2>&1
for f in $X/aig/*.abc.log $X/aig/*.bmc.log $X/aig/*.cex $X/aig/*.replay.txt; do [ -f "$f" ] && cp "$f" $D/; done
out=$D/result.txt; [ -f $out ] && { k=1; while [ -f $D/result.$k.txt ]; do k=$((k + 1)); done; out=$D/result.$k.txt; }
cp $X/result.txt $out
rm -rf $X
