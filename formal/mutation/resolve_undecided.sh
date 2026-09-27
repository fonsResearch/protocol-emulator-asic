#!/usr/bin/env bash
# Re-run the A1 oracle with a longer limit on mutants that no oracle killed and A1 left
# undecided. usage: resolve_undecided.sh <timeout-s> <jobs>   (MUT_DIR = campaign dir)
# Writes <MUT_DIR>/<t>_<i>/a1_long.txt (resumable).
set -u
TMO=${1:-900}; JOBS=${2:-6}; export MUT_DIR=${MUT_DIR:-formal/work/mut}; export BUILD_DIR=${BUILD_DIR:-$TMPDIR/_build_pemu}
python3 - > $MUT_DIR/undecided.txt <<'PY'
import csv
for x in csv.DictReader(open('log/kill_matrix.csv')):
    if x['A1'] == 'U' and 'K' not in (x['SIM'], x['A2'], x['B1']):
        print(x['target'], x['index'])
PY
cat $MUT_DIR/undecided.txt | xargs -P $JOBS -n 2 sh -c '
  d=$MUT_DIR/$0_$1; [ -f $d/a1_long.txt ] && exit 0
  formal/prove_one.sh m_$0_$1__a1_miter $d/v $d/aig_long '"$TMO"' "?" > $d/a1_long.tmp 2>/dev/null; mv $d/a1_long.tmp $d/a1_long.txt'
