"""Stratified random samples for the v2 campaign's full oracle matrix (plan step 9).

Graph mutants: N per unit (default 120) from $MUT_V2/sites_<unit>.csv, stratified by operator
(proportional allocation, largest remainder, at least 1 per operator present).
Contract mutants: M per package (default 20) from the valid sites of `mutants_v2.exe clist`,
stratified the same way. Seed fixed (20261108), so the sample is reproducible.
Writes $MUT_V2/sample_graph.txt ("<unit> <index>") and $MUT_V2/sample_contract.txt
("c:<pkg> <index>")."""
import os
import random
import subprocess
import sys
from collections import defaultdict

MUT = os.environ.get("MUT_V2", "formal/work/mut_v2")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 120
MC = int(sys.argv[2]) if len(sys.argv) > 2 else 20
SEED = 20261108


def stratified(rows, n, rng):
    """rows: list of (index, op). Returns sorted indices."""
    by = defaultdict(list)
    for i, op in rows:
        by[op].append(i)
    total = len(rows)
    if n >= total:
        return sorted(i for i, _ in rows)
    quota = {op: n * len(v) / total for op, v in by.items()}
    alloc = {op: max(1, int(q)) for op, q in quota.items()}
    while sum(alloc.values()) > n:  # too many minimum allocations: trim the largest strata
        op = max(alloc, key=lambda o: alloc[o])
        alloc[op] -= 1
    rest = sorted(by, key=lambda o: -(quota[o] - int(quota[o])))
    k = 0
    while sum(alloc.values()) < n:
        op = rest[k % len(rest)]
        if alloc[op] < len(by[op]):
            alloc[op] += 1
        k += 1
    out = []
    for op in sorted(by):
        out += rng.sample(sorted(by[op]), alloc[op])
    return sorted(out)


rng = random.Random(SEED)
with open(f"{MUT}/sample_graph.txt", "w") as f:
    for u in ("lane_rtl", "lane_spec", "mon_lane"):
        rows = [(int(l.split(",")[0]), l.split(",")[1]) for l in open(f"{MUT}/sites_{u}.csv")]
        s = stratified(rows, N, rng)
        f.writelines(f"{u} {i}\n" for i in s)
        print(u, len(rows), "->", len(s))

M = os.environ.get("MUTANTS_V2", "_build/default/formal/bin/mutants_v2.exe")
with open(f"{MUT}/sample_contract.txt", "w") as f:
    for p in ("uart_tx", "uart_rx", "spi_ctl", "spi_tgt", "usb"):
        lines = subprocess.run([M, "clist", p], capture_output=True, text=True, check=True).stdout.split()
        open(f"{MUT}/csites_{p}.csv", "w").write("\n".join(lines) + "\n")
        rows = [(int(l.split(",")[0]), l.split(",")[1]) for l in lines if l.endswith(",valid")]
        s = stratified(rows, MC, rng)
        f.writelines(f"c:{p} {i}\n" for i in s)
        print(p, len(lines), "sites,", len(rows), "valid ->", len(s))
