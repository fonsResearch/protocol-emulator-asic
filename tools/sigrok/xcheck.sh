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
    i2c_tgt)
      $SRD/srd_run 60000000 $f -d i2c -c scl=0 -c sda=1 > $D/$n.ann
      python3 "$(dirname "$0")/i2c_tokens.py" $D/$n.ann $D/$n.tokens /dev/null 50 $D/$n.dec_w $D/$n.dec_r
      for pair in tokens:bus dec_w:wbytes dec_r:rbytes; do
        a=${pair%%:*}; b=${pair##*:}
        if cmp -s $D/$n.$a $D/$n.$b; then echo "$n $a: sigrok $(wc -l < $D/$n.$a | tr -d ' ') = $b"
        else echo "$n $a: MISMATCH vs $b"; diff $D/$n.$a $D/$n.$b | head -5; fail=1; fi
      done
      continue ;;
    usb_tx)
      # low-speed USB: usb_signalling (dp = ch0, dm = ch1) stacked with usb_packet. A packet counts
      # as received only if no "CRC16 ERROR" annotation lies inside it; PIDs map DATA0 -> C3,
      # DATA1 -> 4B. The aborted packet must be rejected (CRC error or absent).
      $SRD/srd_run 60000000 $f -d usb_signalling -o signalling=low-speed -c dp=0 -c dm=1 \
        -s -d usb_packet -o signalling=low-speed > $D/$n.ann
      awk '$1=="usb_packet" && $4==10 {err[NR]=$2} $1=="usb_packet" && ($4==15 || $4==16) {
             bad=0; for (k in err) if (err[k] >= $2 && err[k] <= $3) bad=1;
             pid=($5=="DATA0") ? "C3" : ($5=="DATA1") ? "4B" : $5; line=pid;
             for (i=7; i<=NF && $i!="]"; i++) line=line " " $i;
             if (!bad) print line; else rej++ }
           END { print rej+0 > "/dev/stderr" }' $D/$n.ann > $D/$n.decoded 2> $D/$n.rejected
      if cmp -s $D/$n.decoded $D/$n.packets; then
        echo "$n: sigrok $(wc -l < $D/$n.decoded | tr -d ' ') CRC-valid packets = expected; rejected $(cat $D/$n.rejected)"
      else echo "$n: MISMATCH"; diff $D/$n.decoded $D/$n.packets | head -5; fail=1; fi
      continue ;;
    uart_rx|uart_tx) $SRD/srd_run 60000000 $f -d uart -o baudrate=115200 -c rx=0 > $D/$n.ann ;;
  esac
  # uart annotation class 0 = RX data (hex text)
  awk '$1=="uart" && $4==0 {print toupper($5)}' $D/$n.ann > $D/$n.decoded
  if cmp -s $D/$n.decoded $D/$n.bytes; then echo "$n: sigrok $(wc -l < $D/$n.decoded | tr -d ' ') bytes = lane"
  else echo "$n: MISMATCH"; diff $D/$n.decoded $D/$n.bytes | head -5; fail=1; fi
done
exit $fail
