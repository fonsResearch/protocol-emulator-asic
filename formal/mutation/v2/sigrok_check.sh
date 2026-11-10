#!/usr/bin/env bash
# Oracle SR (spec-free) of the v2 campaign: decode the chip's pad traces with libsigrokdecode and
# compare with the intended traffic, and compare the bytes the lane pushed with the bytes the
# peer sent. Inputs: <dir>/<scenario>.{rle,exp_*,got_pushes} from `mutants_v2.exe chip`.
# Usage: formal/mutation/v2/sigrok_check.sh <dir>   (SRD defaults to .toolchain/srd)
# Prints one line per check and a final "SR KILLED <first mismatch>" or "SR SURVIVED".
set -u
D=$1; SRD=${SRD:-.toolchain/srd}
export SIGROKDECODE_DIR=$SRD/inst/share/libsigrokdecode/decoders
first=""
check() { # name a b
  if cmp -s "$2" "$3"; then echo "$1 ok"; else echo "$1 MISMATCH"; [ -z "$first" ] && first=$1; fi
}
for f in $D/*.got_pushes; do
  n=$(basename $f .got_pushes)
  [ -f $D/$n.exp_pushes ] && check "$n:pushes" $D/$n.exp_pushes $f
done
if [ -f $D/uart_tx_ok.rle ]; then
  # d = 4 steps per bit at P = 7 (8 cycles per step): 32 samples per bit, scaled to 115200 baud
  $SRD/srd_run 3686400 $D/uart_tx_ok.rle -d uart -o baudrate=115200 -c rx=0 > $D/uart_tx_ok.ann 2>/dev/null
  awk '$1=="uart" && $4==0 {print toupper($5)}' $D/uart_tx_ok.ann > $D/uart_tx_ok.dec_bytes
  check uart_tx_ok:sigrok $D/uart_tx_ok.exp_bytes $D/uart_tx_ok.dec_bytes
fi
for n in spi_ctl_ok spi_tgt_ok; do
  [ -f $D/$n.rle ] || continue
  $SRD/srd_run 30000000 $D/$n.rle -d spi -o cpol=0 -o cpha=0 -o bitorder=msb-first -o wordsize=8 \
    -c clk=0 -c mosi=1 -c miso=2 -c cs=3 > $D/$n.ann 2>/dev/null
  awk '$1=="spi" && $4==1 {print toupper($5)}' $D/$n.ann > $D/$n.dec_mosi
  awk '$1=="spi" && $4==0 {print toupper($5)}' $D/$n.ann > $D/$n.dec_miso
  check $n:sigrok_mosi $D/$n.exp_mosi $D/$n.dec_mosi
  check $n:sigrok_miso $D/$n.exp_miso $D/$n.dec_miso
done
if [ -f $D/usb_two.rle ]; then
  # 20 cycles per bit = 1.5 Mbit/s at a 30 MHz sample rate; a packet counts only without a CRC error
  $SRD/srd_run 30000000 $D/usb_two.rle -d usb_signalling -o signalling=low-speed -c dp=0 -c dm=1 \
    -s -d usb_packet -o signalling=low-speed > $D/usb_two.ann 2>/dev/null
  awk '$1=="usb_packet" && $4==10 {err[NR]=$2} $1=="usb_packet" && ($4==15 || $4==16) {
         bad=0; for (k in err) if (err[k] >= $2 && err[k] <= $3) bad=1;
         pid=($5=="DATA0") ? "C3" : ($5=="DATA1") ? "4B" : $5; line=pid;
         for (i=7; i<=NF && $i!="]"; i++) line=line " " $i;
         if (!bad) print line }' $D/usb_two.ann > $D/usb_two.dec_packets
  check usb_two:sigrok $D/usb_two.exp_packets $D/usb_two.dec_packets
fi
if [ -f $D/i2c_ctl_ok.rle ]; then
  $SRD/srd_run 30000000 $D/i2c_ctl_ok.rle -d i2c -c scl=0 -c sda=1 > $D/i2c_ctl_ok.ann 2>/dev/null
  python3 tools/sigrok/i2c_tokens.py $D/i2c_ctl_ok.ann $D/i2c_ctl_ok.dec_bus $D/i2c_ctl_ok.dec_buspushes
  check i2c_ctl_ok:sigrok_bus $D/i2c_ctl_ok.exp_bus $D/i2c_ctl_ok.dec_bus
fi
if [ -n "$first" ]; then echo "SR KILLED $first"; else echo "SR SURVIVED"; fi
