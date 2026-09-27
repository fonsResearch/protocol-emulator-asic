#!/usr/bin/env bash
# Mutation campaign. Usage (repo root, tools/env.sh sourced):
#   formal/mutation/run_mutants.sh [timeout-s=120] [jobs=8] [nprog=40] [targets="rtl spec"]
# Resumable: mutants with an existing result.txt are skipped. Run it as a foreground or
# ordinary background job (not nohup/detached) so it can be stopped.
# Then: python3 formal/mutation/kill_matrix.py  -> log/kill_matrix.csv, log/kill_matrix.md
set -u
TMO=${1:-120}; JOBS=${2:-8}; NPROG=${3:-40}; TARGETS=${4:-"rtl spec"}
export BUILD_DIR=${BUILD_DIR:-$TMPDIR/_build_pemu}
dune build --root . --build-dir "$BUILD_DIR" formal/bin/mutants.exe formal/bin/replay_cex.exe 2>&1 | grep -v xcrun_db
M=$BUILD_DIR/default/formal/bin/mutants.exe
mkdir -p ${MUT_DIR:-formal/work/mut}
for t in $TARGETS; do $M list $t > ${MUT_DIR:-formal/work/mut}/sites_$t.csv; done
for t in $TARGETS; do cut -d, -f1 ${MUT_DIR:-formal/work/mut}/sites_$t.csv | sed "s/^/$t /"; done \
  | xargs -P $JOBS -n 2 sh -c 'formal/mutation/one_mutant.sh "$0" "$1" '"$TMO $NPROG"
