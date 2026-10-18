#!/usr/bin/env bash
# Spec-free cross-check: decode exported pad traces with libsigrokdecode and compare with
# the bytes the lane moved. Usage: tools/sigrok/xcheck.sh <srd-dir (build.sh OUT)> <trace dir> <proto>
set -euo pipefail
SRD=$1; D=$2; P=$3
export SIGROKDECODE_DIR=$SRD/inst/share/libsigrokdecode/decoders
fail=0
for f in $D/${P}_*.rle; do
  n=$(basename $f .rle)
  case $P in
    uart_rx|uart_tx) $SRD/srd_run 60000000 $f -d uart -o baudrate=115200 -c rx=0 > $D/$n.ann ;;
  esac
  # uart annotation class 0 = RX data (hex text)
  awk '$1=="uart" && $4==0 {print toupper($5)}' $D/$n.ann > $D/$n.decoded
  if cmp -s $D/$n.decoded $D/$n.bytes; then echo "$n: sigrok $(wc -l < $D/$n.decoded | tr -d ' ') bytes = lane"
  else echo "$n: MISMATCH"; diff $D/$n.decoded $D/$n.bytes | head -5; fail=1; fi
done
exit $fail
