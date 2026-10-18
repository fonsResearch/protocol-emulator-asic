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
    spi_ctl|spi_tgt)
      m=${n##*_m}; cpol=$((m / 2)); cpha=$((m % 2))
      $SRD/srd_run 60000000 $f -d spi -o cpol=$cpol -o cpha=$cpha -o bitorder=msb-first -o wordsize=8 \
        -c clk=0 -c mosi=1 -c miso=2 -c cs=3 > $D/$n.ann
      for dirn in mosi:1 miso:0; do
        s=${dirn%%:*}; cls=${dirn##*:}
        awk -v c=$cls '$1=="spi" && $4==c {print toupper($5)}' $D/$n.ann > $D/$n.$s.decoded
        if cmp -s $D/$n.$s.decoded $D/$n.$s.bytes; then echo "$n $s: sigrok $(wc -l < $D/$n.$s.decoded | tr -d ' ') bytes = lane-side bytes"
        else echo "$n $s: MISMATCH"; diff $D/$n.$s.decoded $D/$n.$s.bytes | head -5; fail=1; fi
      done
      continue ;;
    i2c_ctl)
      $SRD/srd_run 60000000 $f -d i2c -c scl=0 -c sda=1 > $D/$n.ann
      python3 "$(dirname "$0")/i2c_tokens.py" $D/$n.ann $D/$n.tokens $D/$n.decoded_pushes
      if cmp -s $D/$n.tokens $D/$n.bus; then echo "$n bus: sigrok $(wc -l < $D/$n.tokens | tr -d ' ') tokens = peer transcript"
      else echo "$n bus: MISMATCH"; diff $D/$n.tokens $D/$n.bus | head -5; fail=1; fi
      if cmp -s $D/$n.decoded_pushes $D/$n.bytes; then echo "$n pushes: bus-derived $(wc -l < $D/$n.bytes | tr -d ' ') = lane pushes"
      else echo "$n pushes: MISMATCH"; diff $D/$n.decoded_pushes $D/$n.bytes | head -5; fail=1; fi
      continue ;;
    uart_rx|uart_tx) $SRD/srd_run 60000000 $f -d uart -o baudrate=115200 -c rx=0 > $D/$n.ann ;;
  esac
  # uart annotation class 0 = RX data (hex text)
  awk '$1=="uart" && $4==0 {print toupper($5)}' $D/$n.ann > $D/$n.decoded
  if cmp -s $D/$n.decoded $D/$n.bytes; then echo "$n: sigrok $(wc -l < $D/$n.decoded | tr -d ' ') bytes = lane"
  else echo "$n: MISMATCH"; diff $D/$n.decoded $D/$n.bytes | head -5; fail=1; fi
done
exit $fail
