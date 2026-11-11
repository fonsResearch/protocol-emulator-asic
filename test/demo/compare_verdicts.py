"""Regression check: the verdict fields (every key containing "verdict") of a fresh result set
equal those of the committed records. Peer-side absolute cycle fields are not compared: in a
single simulator run (tools/reproduce.sh) they are one cycle earlier than in the per-scenario runs
of run_demo.sh, while every chip verdict and stamp is identical.
usage: python3 compare_verdicts.py NEW_DIR REF_DIR"""
import json
import sys
from pathlib import Path

new, ref = Path(sys.argv[1]), Path(sys.argv[2])
bad, n = [], 0
for f in sorted(ref.glob("*.json")):
    g = new / f.name
    if not g.exists():
        bad.append(f.name + " missing")
        continue
    a, b = json.loads(f.read_text()), json.loads(g.read_text())
    n += 1
    for k in a:
        if "verdict" in k and a[k] != b.get(k):
            bad.append(f"{f.name}:{k}")
print(f"{n} records, verdict differences: {bad if bad else 0}")
sys.exit(1 if bad or n == 0 else 0)
