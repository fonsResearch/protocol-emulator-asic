#!/usr/bin/env bash
# v2 campaign, oracle SIM on every graph mutant (plan step 9). Usage (repo root):
#   formal/mutation/v2/run_sim.sh [jobs=9] [timeout-s=300] [units="lane_spec lane_rtl mon_lane"]
# Resumable: a mutant with a result file is skipped. Results: $MUT_V2/sim/<unit>_<index>.txt
# (one line: KILLED ... | SURVIVED ... | ERROR ... | TIMEOUT). Stop switch: touch $MUT_V2/STOP.
# Run as an ordinary (foreground or tool-background) job, never nohup.
set -u
JOBS=${1:-9}; TMO=${2:-300}; UNITS=${3:-"lane_spec lane_rtl mon_lane"}
export MUT_V2=${MUT_V2:-formal/work/mut_v2}
B=_build/default/formal/bin/mutants_v2.exe
[ -x $B ] || { echo "build $B first (dune build ./formal/bin/mutants_v2.exe)"; exit 1; }
# snapshot: later dune builds must not replace the binary under a running campaign
mkdir -p $MUT_V2/sim $MUT_V2/bin
[ -x $MUT_V2/bin/mutants_v2.exe ] || cp $B $MUT_V2/bin/mutants_v2.exe
M=$MUT_V2/bin/mutants_v2.exe
for u in $UNITS; do $M list $u > $MUT_V2/sites_$u.csv; done
one() {
  u=$1; i=$2; f=$MUT_V2/sim/${u}_$i.txt
  [ -f $MUT_V2/STOP ] && return 0
  [ -f $f ] && return 0
  r=$(perl formal/glimit.pl $TMO $M sim $u $i 2>&1 | tail -1)
  case "$r" in KILLED*|SURVIVED*|ERROR*) ;; *) r="TIMEOUT limit=$TMO $r" ;; esac
  echo "$r" > $f.tmp && mv $f.tmp $f
}
export -f one; export M TMO
for u in $UNITS; do cut -d, -f1 $MUT_V2/sites_$u.csv | sed "s/^/$u /"; done \
  | xargs -P $JOBS -n 2 bash -c 'one "$0" "$1"'
for u in $UNITS; do
  n=$(wc -l < $MUT_V2/sites_$u.csv | tr -d ' ')
  c() { cat $MUT_V2/sim/${u}_*.txt 2>/dev/null | grep -c "^$1"; }
  echo "$u: sites $n done $(ls $MUT_V2/sim | grep -c "^${u}_") killed $(c KILLED) survived $(c SURVIVED) error $(c ERROR) timeout $(c TIMEOUT)"
done
