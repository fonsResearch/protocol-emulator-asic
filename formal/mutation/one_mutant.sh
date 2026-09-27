#!/usr/bin/env bash
# Run all four oracles on one mutant. Usage: one_mutant.sh <rtl|spec> <index> <timeout-s> <nprog>
# Writes formal/work/mut/<target>_<index>/result.txt:
#   SIM <KILLED ...|SURVIVED ...>
#   <oracle> <markdown row from prove_one.sh>
set -u
# stop switch: if <MUT_DIR>/STOP exists, do nothing (lets a running campaign drain)
[ -f "${MUT_DIR:-formal/work/mut}/STOP" ] && exit 0
t=$1; i=$2; TMO=$3; NPROG=$4
B=${BUILD_DIR:-$TMPDIR/_build_pemu}; export BUILD_DIR=$B
D=${MUT_DIR:-formal/work/mut}/${t}_$i; mkdir -p $D/v
M=$B/default/formal/bin/mutants.exe
# resumable: a finished mutant (result.txt written atomically at the end) is skipped
[ -f $D/result.txt ] && exit 0
{
  echo "SIM $(formal/tlimit.sh $TMO $M sim $t $i $NPROG 2>&1 | tail -1)"
  $M emit $t $i $D/v | while read o n; do
    echo "$o $(formal/prove_one.sh $n $D/v $D/aig $TMO '?')"
  done
} > $D/result.tmp 2>&1
mv $D/result.tmp $D/result.txt
