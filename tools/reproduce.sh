#!/usr/bin/env bash
# One-command reproduction of the v2 results (plan step 10). Tiers, cheapest first:
#   tools/reproduce.sh quick     build, all expect tests (dune @runtest), toolchain CLIs, host assets
#                                up to date, MicroPython check (if `micropython` is on PATH)   ~5 min
#                                and the freeze check (re-emitted core == src/pemu_core_v1m.v)
#   tools/reproduce.sh sim       quick + virtual demo board (17 scenarios, one simulator run; per-
#                                scenario waveforms: test/demo/run_demo.sh), host package (11
#                                scenarios) and held-out 1-Wire (3, log/flexibility_v2.md
#                                ) on the RTL; with GL_NETLIST and PDK_ROOT set, also on the gate-
#                                level netlist (sha256 = sign-off netlist), and RTL = GL compared                  ~5 min (+10 GL)
#   tools/reproduce.sh proofs    shipped-configuration proofs: pipelined R1 (k-induction) and package
#                                A2 (U, N1 and negative controls) for UART TX/RX, SPI ctl/tgt, USB
#                                (21 harnesses; A2_FILTER=<regex> for a subset)                ~1.5-2.5 h
#   tools/reproduce.sh r1        only the pipelined R1 proofs and their negative controls     ~1 min
#   tools/reproduce.sh witness   check-witness obligation (103 covers, directed witnesses, oracle W) ~1.5 h
#   tools/reproduce.sh all       everything above
# Each tier prints PASS/FAIL lines and ends with a summary; exit status 0 iff every step passed.
# Long campaigns (log/campaign_v2.md, several hours) are not included; their commands are in that
# log, section 7. Run from anywhere; needs the opam switch and tools in tools/env.sh.
set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
export HOME=${HOME:-/tmp}
# shellcheck disable=SC1091
source tools/env.sh > /dev/null 2>&1
tier=${1:-quick}
fails=0
step() { # name, command...
  local name=$1; shift
  local log=/tmp/reproduce_${name}.log
  local t0=$SECONDS
  if "$@" > "$log" 2>&1; then
    printf "PASS  %-28s %5ds\n" "$name" $((SECONDS - t0))
  else
    printf "FAIL  %-28s %5ds  (log %s)\n" "$name" $((SECONDS - t0)) "$log"
    fails=$((fails + 1))
  fi
}

# The frozen design: the core emitted from the current sources (inc5 recipe, log/increments_v2.md
# section 5) must be byte-identical to the committed src/pemu_core_v1m.v, and a gate-level netlist
# given in GL_NETLIST must be the sign-off netlist of CI run 42426292730.
SIGNOFF_NL_SHA=b450fe7c24d63d1107968b43c271f7826458913ce80c18aab3c588620c75abb0
freeze_verilog() {
  dune build ./rtl_v1/bin/emit_lane_rtl.exe || return 1
  local d; d=$(mktemp -d /tmp/pemu_freeze.XXXXXX)
  PEMU_LIB=v2inc5 PEMU_LOADABLE=rom PEMU_SLOTS=5 PEMU_VPIPE=1 PEMU_PWIN=1 PEMU_LPIPE=1 \
    ./_build/default/rtl_v1/bin/emit_lane_rtl.exe top_macro_mon_sweep > "$d/raw.v" || return 1
  python3 tools/fix_combdly.py "$d/raw.v" "$d/fixed.v" || return 1
  cmp "$d/fixed.v" src/pemu_core_v1m.v && echo "re-emitted core identical to src/pemu_core_v1m.v"
}
gl_netlist_sha() {
  local h; h=$(shasum -a 256 "$GL_NETLIST" | cut -d' ' -f1)
  echo "$h"; [ "$h" = "$SIGNOFF_NL_SHA" ]
}
quick() {
  step build dune build
  step runtest dune build @runtest
  step cc_list ./_build/default/toolchain/bin/pemu_cc.exe list
  step cc_retune ./_build/default/toolchain/bin/pemu_cc.exe retune 0 uart_tx:d=6,pin=0
  step asm_examples sh -c 'for f in toolchain/examples/*.s; do ./_build/default/toolchain/bin/pemu_asm.exe asm "$f" --werror > /dev/null || exit 1; done'
  step host_assets python3 host/tools/build_assets.py --check
  step freeze_verilog freeze_verilog
  if command -v micropython > /dev/null; then
    step micropython micropython host/tools/upy_check.py
  else
    printf "SKIP  %-28s (micropython not on PATH)\n" micropython
  fi
}

# formal/work/results.md rows: | harness | expected | engine | result | ...; every row must match
check_results() { # file, minimum row count
  python3 - "$1" "$2" <<'EOF2'
import sys
rows = [l.split("|") for l in open(sys.argv[1]) if l.startswith("| ") and not l.startswith("| harness")]
bad = [r[1].strip() for r in rows if r[2].strip() != r[4].strip()]
print(len(rows), "harnesses; expected != result:", bad)
sys.exit(1 if bad or len(rows) < int(sys.argv[2]) else 0)
EOF2
}
prove() { # name, minimum rows, run_proofs args...
  local name=$1 n=$2; shift 2
  formal/run_proofs.sh "$@" > /dev/null 2>&1
  cp formal/work/results.md "/tmp/reproduce_$name.md"
  check_results "/tmp/reproduce_$name.md" "$n"
}
sim_make() { # out dir, module, extra make args...
  local out=$1 mod=$2; shift 2
  ( cd test/demo && mkdir -p "results/$out" \
    && DEMO_OUT=$PWD/results/$out make COCOTB_TEST_MODULES=$mod FST= "$@" > "results/$out/run.log" 2>&1; \
    grep -E "TESTS=" "results/$out/run.log"; grep -q "FAIL=0" "results/$out/run.log" )
}

sim() {
  export PATH=${PYTHON_BIN:-$HOME/.claude-science/conda/envs/python/bin}:$PATH  # cocotb
  # fresh results go to results/repro_*; the committed records (results/{rtl,gl}{,_host}) are the
  # reference: every verdict must be identical
  step demo_rtl sim_make repro_rtl test_demo
  step host_pkg_rtl sim_make repro_rtl_host test_host_pkg
  step demo_rtl_verdicts python3 test/demo/compare_verdicts.py test/demo/results/repro_rtl test/demo/results/rtl
  step host_rtl_verdicts python3 test/demo/compare_verdicts.py test/demo/results/repro_rtl_host test/demo/results/rtl_host
  step flex_rtl sim_make repro_rtl_flex test_flex
  step flex_rtl_records python3 test/demo/compare_flex.py test/demo/results/repro_rtl_flex test/demo/results/rtl_flex
  if [ -n "${GL_NETLIST:-}" ] && [ -n "${PDK_ROOT:-}" ]; then
    step gl_netlist_sha gl_netlist_sha
    step demo_gl sim_make repro_gl test_demo GATES=yes GL_NETLIST="$GL_NETLIST"
    step flex_gl sim_make repro_gl_flex test_flex GATES=yes GL_NETLIST="$GL_NETLIST"
    step flex_rtl_eq_gl python3 test/demo/compare_flex.py test/demo/results/repro_rtl_flex test/demo/results/repro_gl_flex
    step host_pkg_gl sim_make repro_gl_host test_host_pkg GATES=yes GL_NETLIST="$GL_NETLIST"
    step demo_rtl_eq_gl sh -c 'cd test/demo && python3 compare_runs.py results/repro_rtl results/repro_gl | grep -q "^0 differing"'
    step host_rtl_eq_gl sh -c 'cd test/demo && python3 compare_runs.py results/repro_rtl_host results/repro_gl_host | grep -q "^0 differing"'
    step demo_gl_verdicts python3 test/demo/compare_verdicts.py test/demo/results/repro_gl test/demo/results/gl
  else
    printf "SKIP  %-28s (set GL_NETLIST and PDK_ROOT)\n" gate_level
  fi
}

proofs() {
  export TMPDIR=${TMPDIR:-/tmp} BUILD_DIR=/tmp/_build_pemu_repro
  # engine conventions: log/proofs_v2.md (R1 by k-induction, negatives by BMC 30 frames)
  step r1_pipelined env ENGINE=ind bash -c "$(declare -f check_results prove); prove r1 6 '^r1v2p_s5_u[0-4](_t5)?$' 300"
  step r1_pipelined_neg env ENGINE=bmc BMC_F=30 bash -c "$(declare -f check_results prove); prove r1neg 2 '^r1v2p_s5_.*_neg$' 300"
  [ "${R1_ONLY:-0}" = 1 ] && return
  # A2_FILTER (regex) re-runs a subset; the default is every unbounded package harness (21).
  # a2_usb_g7 is excluded: USB packet contents (G7) are bounded, not proved (dprove times out;
  # log/protocols_v1.md), so it cannot be expected to PASS here. Its negatives stay in.
  local f=${A2_FILTER:-'^a2_(uart_tx_d4|uart_rx_d8|spi_ctl_m0|spi_tgt_m0|usb_u|usb_n1|usb_g7_)'}
  local n=21; [ -n "${A2_FILTER:-}" ] && n=1
  step a2_packages bash -c "$(declare -f check_results prove); prove a2 $n '$f' 1800"
}

# the checks the formal covers leave open (timeouts at 1,800 s; log/witness_v2.md section 2.2)
WSEARCH="i2c_ctl_fm B77 i2c_ctl_sm B77 i2c_tgt B58 i2c_tgt B81 i2c_tgt F54 i2c_tgt F55 i2c_tgt F56 i2c_tgt F57 usb FA4"
witness() {
  export TMPDIR=${TMPDIR:-/tmp}
  step witness_build dune build ./formal/bin/mutants_v2.exe ./formal/bin/replay_cex.exe
  step witness_snapshot formal/mutation/v2/snapshot.sh
  # resumable: checks with a result in formal/work/mut_v2/witness3 are skipped; move that
  # directory aside to rerun from scratch
  step witness_formal env SCRATCH=/tmp/wit_repro WOUT=formal/work/mut_v2/witness3 formal/mutation/v2/run_witness.sh 9 1800
  step witness_directed bash -c 'mkdir -p formal/work/mut_v2/wsearch; echo '"$WSEARCH"' | xargs -n 2 | while read p c; do ./_build/default/formal/bin/mutants_v2.exe wsearch $p $c > formal/work/mut_v2/wsearch/${p}_$c.txt 2>&1; tail -1 formal/work/mut_v2/wsearch/${p}_$c.txt | grep -q "chip CONFIRMED" || exit 1; done'
  step witness_report sh -c 'python3 formal/mutation/v2/witness_report.py | grep -q "open 0, error 0"'
  step witness_clean sh -c 'python3 formal/mutation/v2/clean_witness.py | grep -q "same-frame blame: 0"'
  step oracle_w sh formal/mutation/v2/run_wsv.sh
}

case $tier in
  quick) quick ;;
  sim) quick; sim ;;
  proofs) quick; proofs ;;
  r1) R1_ONLY=1 proofs ;;
  witness) quick; witness ;;
  all) quick; sim; proofs; witness ;;
  *) echo "usage: tools/reproduce.sh quick|sim|proofs|r1|witness|all"; exit 3 ;;
esac
echo "reproduce $tier: $fails failed step(s)"
exit $((fails > 0))
