#!/usr/bin/env bash
# Regenerate test/vectors/*.vec (wrapper-level replay vectors) from the spec interpreter.
# Run from anywhere after `source tools/env.sh`. Commit the result: TT CI does not build OCaml.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="${BUILD_DIR:-/tmp/_build_pemu}"
cd "$ROOT"
dune build --root . --build-dir "$B" rtl/bin/dump_tt_vectors.exe 2>&1 | grep -v xcrun_db || true
rm -f test/vectors/*.vec
"$B/default/rtl/bin/dump_tt_vectors.exe" test/vectors
