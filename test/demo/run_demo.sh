#!/usr/bin/env bash
# One simulator run per scenario so each gets its own waveform:
#   test/demo/run_demo.sh rtl|gl [scenario ...]
# writes results/<mode>/<scenario>.{json,log} and the top-level pin waveform <scenario>.vcd.gz
# (WAVE=fst: Icarus FST instead, not decoded or checked locally). gl needs GL_NETLIST (final/nl,
# unpowered netlist) and PDK_ROOT.
set -u
cd "$(dirname "$0")"
mode=${1:-rtl}; shift || true
all="calibrate uart_tx_clean uart_tx_bad_start uart_rx_clean uart_rx_fast_peer spi_ctl_clean spi_ctl_slow_target
     spi_tgt_clean spi_tgt_early_cs i2c_ctl_clean i2c_ctl_slow_target i2c_ctl_late_ack i2c_tgt_clean i2c_tgt_short_start_hold
     usb_ls_tx windows_uart_d6 two_lanes"
list=${*:-$all}
out=results/$mode; mkdir -p "$out"
gates=no; [ "$mode" = gl ] && gates=yes
for s in $list; do
  rm -f tb.fst
  if [ "${WAVE:-vcd}" = fst ]; then
    DEMO_OUT=$PWD/$out COCOTB_TEST_FILTER="test_demo.$s" make GATES=$gates > "$out/$s.log" 2>&1
    [ -f tb.fst ] && mv tb.fst "$out/$s.fst"
  else
    # FST= makes Icarus write VCD (tb.v names the file tb.fst in both formats)
    DEMO_OUT=$PWD/$out COCOTB_TEST_FILTER="test_demo.$s" make GATES=$gates FST= > "$out/$s.log" 2>&1
    [ -f tb.fst ] && gzip -c tb.fst > "$out/$s.vcd.gz" && rm -f tb.fst
  fi
  r=$(grep -Eo "$s +(PASS|FAIL)" "$out/$s.log" | tail -1)
  echo "${r:-$s NO RESULT}"
done
