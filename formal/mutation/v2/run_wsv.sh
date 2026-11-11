#!/bin/sh
# Witness oracle W on the sampled contract mutants (log/witness_v2.md section 5).
# usage: formal/mutation/v2/run_wsv.sh   (after dune build ./formal/bin/mutants_v2.exe)
M=./_build/default/formal/bin/mutants_v2.exe
mkdir -p formal/work/mut_v2/wsv
while read u i; do
  p=${u#c:}
  $M wsv "$p" "$i" > "formal/work/mut_v2/wsv/${p}_$i.txt" 2>&1
done < formal/work/mut_v2/sample_contract.txt
python3 formal/mutation/v2/check_wsv.py
