#!/usr/bin/env bash
# v2 campaign, full oracle matrix on the stratified samples (plan step 9). Usage (repo root,
# tools/env.sh sourced, formal/mutation/v2/snapshot.sh run, SCRATCH set outside the repo):
#   formal/mutation/v2/run_matrix.sh [jobs=8] [formal timeout-s=900] [sample files]
# Per graph mutant: formal oracles (one_formal.sh: A1, A2, R1b) and, for lane_rtl / mon_lane,
# the chip oracles: C3 (chip vs Psim) and SR (sigrok + intended traffic) ->
# $MUT_V2/chip/<unit>_<index>/{chip.txt,sr.txt}. Per contract mutant (c:<pkg>): A2U / A2N
# (one_formal.sh) and SV -> $MUT_V2/sv/<pkg>_<index>.txt. Resumable; stop switch $MUT_V2/STOP.
set -u
JOBS=${1:-8}; TMO=${2:-900}; SAMPLES=${3:-"formal/work/mut_v2/sample_graph.txt formal/work/mut_v2/sample_contract.txt"}
export MUT_V2=${MUT_V2:-formal/work/mut_v2} TMO
: ${SCRATCH:?set SCRATCH to a directory outside the repo}
export SCRATCH
export M=$(cat $MUT_V2/fbin_current)/default/formal/bin/mutants_v2.exe
mkdir -p $MUT_V2/chip $MUT_V2/sv $SCRATCH
one() {
  u=$1; i=$2
  [ -f $MUT_V2/STOP ] && return 0
  case $u in
    c:*)
      p=${u#c:}
      formal/mutation/v2/one_formal.sh $u $i ${CTMO:-1800}
      f=$MUT_V2/sv/${p}_$i.txt
      [ -f $f ] || { perl formal/glimit.pl 900 $M csv $p $i > $f.tmp 2>&1; mv $f.tmp $f; } ;;
    *)
      formal/mutation/v2/one_formal.sh $u $i $TMO
      if [ $u != lane_spec ]; then
        d=$MUT_V2/chip/${u}_$i
        if [ ! -f $d/sr.txt ]; then
          x=$SCRATCH/chip_${u}_$i.$$; mkdir -p $x $d
          perl formal/glimit.pl 1200 $M chip $u $i $x > $x/chip.txt 2>&1
          formal/mutation/v2/sigrok_check.sh $x > $x/sr.txt 2>&1
          cp $x/chip.txt $d/chip.txt; cp $x/sr.txt $d/sr.txt; rm -rf $x
        fi
      fi ;;
  esac
}
export -f one
cat $SAMPLES | xargs -P $JOBS -n 2 bash -c 'one "$0" "$1"'
echo "matrix done: $(ls $MUT_V2/formal | wc -l | tr -d ' ') formal dirs, $(ls $MUT_V2/chip | wc -l | tr -d ' ') chip, $(ls $MUT_V2/sv | wc -l | tr -d ' ') sv"
