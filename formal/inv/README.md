# formal/inv: invariant mining for A2 harnesses (experimental)

Status and measurements: log/inv_mining_i2c.md. The flow did not produce an unbounded I2C
proof; on 2026-10-19 it was stopped by user decision and is kept for later use.

Pipeline (one harness):

```
source tools/env.sh; export TMPDIR=/tmp BUILD_DIR=<build dir>
$BUILD_DIR/default/formal/bin/emit_formal.exe <vdir>
ENGINE=bmc BMC_F=1 formal/prove_one.sh <h> <vdir> <wdir> 60 '?'      # writes <wdir>/<h>.aig/.map
$BUILD_DIR/default/formal/bin/inv_traces.exe <h> traces.bin 64 60000 <seed>   # INV_VERBOSE=1: first blames
python formal/inv/aig.py <wdir>/<h>.aig <wdir>/<h>.map <simdir>      # builds <simdir>/aigsim
<simdir>/aigsim traces.bin states.bin 23                              # exit 1 on any bad mismatch
```

Then, in Python (`sys.path` = formal/inv): `houdini.load_states`, `houdini.mine`,
`houdini.base_filter`, `houdini.houdini(..., prop=True | "assume" | False)`,
`strengthen.write_strengthened` and `strengthen.check_extension`. The strengthened model is
an ordinary AIGER file for ABC, rIC3 and Certifaiger.

Trust: only `strengthen.check_extension` (structural: same inputs, latches, next-state
functions and original gates; original bad is a disjunct of the new bad) and the model checker
that proves the strengthened model. The traces, simulator, templates and Houdini only propose
lemmas.
