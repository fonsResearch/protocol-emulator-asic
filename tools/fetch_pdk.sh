#!/usr/bin/env bash
# Fetch the SG13CMOS5L PDK subset used for local mapping and netlist equivalence into
# .toolchain/pdk (gitignored). The revision must match IHP_PDK_REV in
# TinyTapeout/tt-gds-action@ihp-cmos5l install_sg13cmos5l.sh; re-check it before relying on results.
# Usage: tools/fetch_pdk.sh [workdir]   (workdir holds the sparse clone; default /tmp/ihp-pdk-sparse)
set -euo pipefail
REV=2bbec755dc67ca3db0261c3d6163e15735d66710
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="${1:-/tmp/ihp-pdk-sparse}"
rm -rf "$W"; mkdir -p "$W"; cd "$W"
git init -q; git remote add o https://github.com/IHP-GmbH/IHP-Open-PDK.git
git config core.sparseCheckout true
cat > .git/info/sparse-checkout <<SP
/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/
/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/verilog/
/ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram
/ihp-sg13cmos5l/libs.tech/librelane/
/ihp-sg13g2/libs.ref/sg13g2_sram/
SP
git fetch -q --depth 1 --filter=blob:none o "$REV"; git checkout -q FETCH_HEAD
D="$ROOT/.toolchain/pdk/ihp-sg13cmos5l"; rm -rf "$ROOT/.toolchain/pdk"; mkdir -p "$D/libs.ref/sg13cmos5l_io" "$D/libs.tech/librelane"
cp -RL ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell "$D/libs.ref/"
cp -RL ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/verilog "$D/libs.ref/sg13cmos5l_io/"
for f in ihp-sg13cmos5l/libs.tech/librelane/*; do [ -e "$f" ] && cp -RL "$f" "$D/libs.tech/librelane/"; done
for sub in lef lib gds verilog doc; do
  mkdir -p "$D/libs.ref/sg13cmos5l_sram/$sub"
  find -L ihp-sg13g2/libs.ref/sg13g2_sram/$sub -maxdepth 1 \( -name 'RM_IHPSG13_1P_64x16_c2*' -o -name 'RM_IHPSG13_1P_core*' \) -exec cp -L {} "$D/libs.ref/sg13cmos5l_sram/$sub/" \;
done
echo "IHP-Open-PDK $REV (subset)" > "$D/SOURCES"
echo "PDK subset installed in $D"
