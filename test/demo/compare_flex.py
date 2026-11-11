#!/usr/bin/env python3
"""Compare held-out package runs (test_flex.py) between two result directories, e.g. RTL and gate
level: every recorded field must be identical, including every DQ edge (board cycle).

usage: compare_flex.py <dir A> <dir B>
"""
import json
import sys
from pathlib import Path


def main():
    a, b = Path(sys.argv[1]), Path(sys.argv[2])
    names = sorted({p.name for p in a.glob("flex_*.json")} | {p.name for p in b.glob("flex_*.json")})
    bad = 0
    for n in names:
        pa, pb = a / n, b / n
        if not (pa.exists() and pb.exists()):
            print(f"{n:28s} MISSING in {'A' if not pa.exists() else 'B'}")
            bad += 1
            continue
        da, db = json.loads(pa.read_text()), json.loads(pb.read_text())
        diff = sorted(k for k in set(da) | set(db) if da.get(k) != db.get(k))
        edges = len(da.get("edges", []))
        print(f"{n:28s} {'identical' if not diff else 'DIFFER: ' + ', '.join(diff)} ({edges} DQ edges)")
        bad += bool(diff)
    print(f"{len(names)} scenarios, {bad} differ")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
