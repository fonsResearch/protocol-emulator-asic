#!/usr/bin/env bash
# Build libsigrokdecode 0.5.3 (static) and the srd_run front end into $OUT (default /tmp/srd).
# Needs a conda env with: python=3.11 glib pkg-config autoconf automake libtool make clang.
# Usage: tools/sigrok/build.sh <conda-env-prefix> [OUT]
# Notes (macOS arm64, 2026-10-18): libsigrokdecode is not on conda-forge for osx-arm64; the
# 0.5.3 configure knows Python only up to 3.8 (patched to python-3.11-embed); the bundled
# libtool misreads recent macOS versions unless MACOSX_DEPLOYMENT_TARGET is set; only a static
# library is built. The git snapshot endpoint refuses automated clients; use the release.
set -euo pipefail
E=$1; OUT=${2:-/tmp/srd}; HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p $OUT && cd $OUT
[ -f lsrd-0.5.3.tgz ] || curl -sSL -o lsrd-0.5.3.tgz https://sigrok.org/download/source/libsigrokdecode/libsigrokdecode-0.5.3.tar.gz
rm -rf libsigrokdecode-0.5.3 && tar xzf lsrd-0.5.3.tgz && cd libsigrokdecode-0.5.3
sed -i.bak 's/python-3\.8-embed/python-3.11-embed/g' configure
export PKG_CONFIG_PATH=$E/lib/pkgconfig CC=$E/bin/clang PATH=$E/bin:$PATH MACOSX_DEPLOYMENT_TARGET=11.0
./configure --prefix=$OUT/inst --disable-dependency-tracking --disable-shared --enable-static >/dev/null
make -j6 >/dev/null && make install >/dev/null
export PKG_CONFIG_PATH=$OUT/inst/lib/pkgconfig:$E/lib/pkgconfig
$E/bin/clang -O2 -o $OUT/srd_run $HERE/srd_run.c $(pkg-config --cflags --libs --static libsigrokdecode)
echo "built $OUT/srd_run; run with SIGROKDECODE_DIR=$OUT/inst/share/libsigrokdecode/decoders"
