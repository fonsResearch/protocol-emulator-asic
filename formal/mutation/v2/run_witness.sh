#!/usr/bin/env bash
# Check-witness obligation (log/witness_v2.md): one formal cover per distinct check of every
# shipped ROM package (Pemu_formal.Witness_v2). Usage (repo root, tools/env.sh sourced,
# formal/mutation/v2/snapshot.sh run):
#   SCRATCH=/tmp/w formal/mutation/v2/run_witness.sh [jobs=9] [timeout-s=1800] [name regex=.]
# Result per check: $WOUT/<name>.txt (WOUT default $MUT_V2/witness2) (prove_one row) plus its counterexample and replay.
# FAIL + replay = witnessed; PASS = dead check; UNDECIDED / TIMEOUT = open. Resumable.
set -u
JOBS=${1:-9}; TMO=${2:-1800}; RE=${3:-.}
export MUT_V2=${MUT_V2:-formal/work/mut_v2} TMO
: ${SCRATCH:?set SCRATCH to a directory outside the repo}
export WOUT=${WOUT:-$MUT_V2/witness2}
export SCRATCH REPLAY_BMC_T=${REPLAY_BMC_T:-120}
export BUILD_DIR=$(cat $MUT_V2/fbin_current)
export M=$BUILD_DIR/default/formal/bin/mutants_v2.exe
mkdir -p $WOUT $SCRATCH
$M wlist > $WOUT/list.txt || exit 1
wone() {
  n=$1; f=$WOUT/$n.txt
  [ -f $MUT_V2/STOP ] && return 0
  [ -f $f ] && return 0
  X=$SCRATCH/$n.$$; mkdir -p $X/v $X/aig
  $M wemit $n $X/v > /dev/null 2> $X/emit.err || { echo "| $n | ? | - | EMIT-ERROR | | | | |" > $f; rm -rf $X; return 0; }
  ENGINE=dprove formal/prove_one.sh $n $X/v $X/aig $TMO '?' > $X/row.txt 2>&1
  for g in $X/aig/$n.cex $X/aig/$n.dcex $X/aig/$n.replay.txt $X/aig/$n.abc.log; do [ -f $g ] && cp $g $WOUT/; done
  cp $X/row.txt $f; rm -rf $X
}
export -f wone
awk '{print $1}' $WOUT/list.txt | grep -E "$RE" | xargs -P $JOBS -n 1 bash -c 'wone "$0"'
ls $WOUT/w2_*.txt | grep -v "\.replay\.txt$" | xargs cat | awk -F'|' '{gsub(/ /,"",$5); print $5}' | sort | uniq -c
