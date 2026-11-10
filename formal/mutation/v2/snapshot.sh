#!/usr/bin/env bash
# Snapshot the campaign's formal binaries into $MUT_V2/fbin (layout of a dune build dir, so
# formal/prove_one.sh finds replay_cex.exe via BUILD_DIR). Run after `dune build` and before a
# formal campaign; later builds do not affect a running campaign.
# Each snapshot is a new directory $MUT_V2/fbin_<epoch>; $MUT_V2/fbin_current names the one in
# use. Nothing is overwritten or deleted.
set -eu
export MUT_V2=${MUT_V2:-formal/work/mut_v2}
S=$MUT_V2/fbin_$(date +%s)
mkdir -p $S/default/formal/bin
for e in mutants_v2 replay_cex; do cp _build/default/formal/bin/$e.exe $S/default/formal/bin/; done
echo $S > $MUT_V2/fbin_current
shasum -a 256 $S/default/formal/bin/*.exe
