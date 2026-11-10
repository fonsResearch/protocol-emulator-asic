#!/usr/bin/env python3
"""Aggregate the v2 campaign (plan step 9) into log/kill_matrix_v2.csv,
log/kill_matrix_v2_contracts.csv and log/kill_matrix_v2.md.

Cell codes (as v1, log/kill_matrix.md):
  K  killed (formal: FAIL and the counterexample replays in cyclesim; simulation: a difference)
  S  survived (formal dprove: proved; R1b: no counterexample within BMC_F frames; sim: none)
  U  undecided (engine gave up or hit the wall-clock limit)
  E  error (tool error, or a counterexample that does not replay)
  -  oracle not applicable to this unit
Graph mutants with A1 = S are proven pin-equivalent to the unmutated partner and are excluded
from kill-rate denominators (lane_rtl, lane_spec). mon_lane has no unbounded kill oracle; its
survivors are triaged by an equivalence check against the shipped lane (column EQ, see eq_cell),
and equivalent ones are excluded the same way.
Oracle families: spec-based (SIM, A1, R1b, C3: compare with Lane_model / Lane_circuit /
Mon_spec / Psim) and spec-free (A2: package contracts; SR: libsigrokdecode on the pins and the
intended traffic). Contract mutants: A2U (U proof, shipped firmware), A2N (firmware-mutant
negatives must still FAIL), SV (Psim directed scenarios vs the shipped contract's firings)."""
import collections
import csv
import math
import os
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[3]
MUT = root / os.environ.get("MUT_V2", "formal/work/mut_v2")
LOG = root / "log"
UNITS = ["lane_rtl", "lane_spec", "mon_lane"]
ORACLES = ["SIM", "A1", "A2", "R1b", "C3", "SR"]
APPLIES = {"lane_rtl": {"SIM", "A1", "C3", "SR"}, "lane_spec": {"SIM", "A1", "A2"},
           "mon_lane": {"SIM", "R1b", "C3", "SR"}}
FAMILY = {"SIM": "spec-based", "A1": "spec-based", "R1b": "spec-based", "C3": "spec-based",
          "A2": "spec-free", "SR": "spec-free"}


def wilson(k, n):
    if n == 0:
        return "-"
    z = 1.96
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return f"{100 * (c - h):.0f}-{100 * (c + h):.0f} %"


def latest(d):
    fs = sorted(d.glob("result*.txt"), key=lambda f: int(re.findall(r"\d+", f.name)[0]) if re.findall(r"\d+", f.name) else 0)
    return fs[-1] if fs else None


def formal_cell(row):
    p = [x.strip() for x in row.split("|")]
    if len(p) < 9:
        return "E"
    res, replay = p[4], p[8]
    if res == "FAIL":
        return "K" if replay.startswith("replay ok") else "E"
    if res == "PASS":
        return "S"
    if res in ("UNDECIDED", "TIMEOUT"):
        return "U"
    return "E"


def combine(cells, bounded=False):
    """oracle verdict over its harnesses: any K -> K; all S -> S; any E -> E; else U.
    bounded (R1b, BMC): UNDECIDED without a counterexample counts as S (survived the bound)."""
    if not cells:
        return "missing"
    if "K" in cells:
        return "K"
    if bounded:
        cells = ["S" if c == "U" else c for c in cells]
    if all(c == "S" for c in cells):
        return "S"
    if "E" in cells:
        return "E"
    return "U"


def eq_row(f):
    if not f.exists():
        return None
    p = [x.strip() for x in f.read_text().split("|")]
    return p[4] if len(p) > 4 else "E"


def eq_cell(i):
    """survivor triage of a monitor-lane mutant (formal/src/mut_v2_harness.ml eq_mon):
    EQ     sequentially equivalent to the shipped lane (all outputs, every input, any tables)
    EQ-rom differs only in act/pc6/pc7/pcs, which feed only the loadable fetcher (not in the
           shipped ROM-mode build): equivalent for the shipped chip
    NE     firing outputs differ even under the tick-spacing assumption (steps >= 6 apart)
    -      not triaged (killed by an oracle)"""
    d = MUT / "eq"
    full = eq_row(d / f"mon_lane_{i}.txt")
    if full is None:
        return "-"
    if full == "PASS":
        return "EQ"
    groups = {g: eq_row(d / f"mon_lane_{i}_{g}.txt") for g in ("fire", "overrun", "busy", "pcs")}
    if groups["fire"] == "PASS" and groups["overrun"] == "PASS" and groups["busy"] == "PASS":
        return "EQ-rom"
    t6 = eq_row(d / f"mon_lane_{i}_t6_fire.txt")
    if t6 == "PASS":
        return "EQ-t6"
    return "NE" if t6 == "FAIL" else "U"


def sim_cell(u, i):
    f = MUT / "sim" / f"{u}_{i}.txt"
    if not f.exists():
        return "missing"
    t = f.read_text()
    return "K" if t.startswith("KILLED") else "S" if t.startswith("SURVIVED") else "E"


def last_line_cell(f, key):
    if not f.exists():
        return "missing"
    lines = [l for l in f.read_text().splitlines() if l.startswith(key + " ")]
    if not lines:
        return "E"
    v = lines[-1].split()[1]
    return {"KILLED": "K", "SURVIVED": "S", "INVALID": "INVALID"}.get(v, "E")


sites = {u: {int(l.split(",")[0]): l.strip().split(",", 2)[1:] for l in open(MUT / f"sites_{u}.csv")} for u in UNITS}

# ---- full population, SIM ----
pop = []
for u in UNITS:
    for i, (op, desc) in sites[u].items():
        pop.append({"unit": u, "index": i, "op": op, "desc": desc, "SIM": sim_cell(u, i)})

# ---- sample, full matrix ----
rows = []
for line in open(MUT / "sample_graph.txt"):
    u, i = line.split()
    i = int(i)
    op, desc = sites[u][i]
    r = {"unit": u, "index": i, "op": op, "desc": desc, "SIM": sim_cell(u, i)}
    d = MUT / "formal" / f"{u}_{i}"
    f = latest(d) if d.exists() else None
    per = collections.defaultdict(list)
    if f:
        for l in f.read_text().splitlines():
            k, _, rest = l.partition(" ")
            if k in ("A1", "A2", "R1b"):
                per[k].append(formal_cell(rest))
    for o in ("A1", "A2", "R1b"):
        r[o] = combine(per[o], bounded=(o == "R1b")) if o in APPLIES[u] else "-"
    r["EQ"] = eq_cell(i) if u == "mon_lane" else "-"
    cd = MUT / "chip" / f"{u}_{i}"
    r["C3"] = last_line_cell(cd / "chip.txt", "C3") if "C3" in APPLIES[u] else "-"
    r["SR"] = last_line_cell(cd / "sr.txt", "SR") if "SR" in APPLIES[u] else "-"
    rows.append(r)

with open(LOG / "kill_matrix_v2.csv", "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=["unit", "index", "op", "desc"] + ORACLES + ["EQ"])
    w.writeheader()
    w.writerows(rows)

# ---- contracts ----
crows = []
cs = {}
for p in ["uart_tx", "uart_rx", "spi_ctl", "spi_tgt", "usb"]:
    f = MUT / f"csites_{p}.csv"
    if f.exists():
        for l in f.read_text().split():
            i, op, wname, stmt, valid = l.split(",")
            cs[(p, int(i))] = (op, wname, stmt, valid)
DIRECTION = {"win_lo_down": "weaken", "win_hi_up": "weaken", "drop_check": "weaken", "hold_down": "weaken (shorter hold)",
             "win_lo_up": "strengthen", "win_hi_down": "strengthen", "hold_up": "strengthen (longer hold)",
             "negate": "garble", "role_swap": "role", "code_bump": "code only"}
if (MUT / "sample_contract.txt").exists():
    for line in open(MUT / "sample_contract.txt"):
        u, i = line.split()
        p, i = u[2:], int(i)
        op, wname, stmt, _ = cs[(p, i)]
        r = {"pkg": p, "index": i, "op": op, "direction": DIRECTION[op], "watcher": wname, "stmt": stmt}
        d = MUT / "formal" / f"c_{p}_{i}"
        f = latest(d) if d.exists() else None
        u_cells, n_cells = [], []
        if f:
            for l in f.read_text().splitlines():
                k, _, rest = l.partition(" ")
                if k == "A2U":
                    u_cells.append(formal_cell(rest))
                elif k == "A2N":
                    c = formal_cell(rest)
                    # a negative must FAIL; it PASSing means the weakened contract misses the bug
                    n_cells.append({"K": "S", "S": "K"}.get(c, c))
        r["A2U"] = combine(u_cells)
        r["A2N"] = combine(n_cells) if n_cells else "missing"
        # A2N: K if any negative now passes (any 'K' after the flip), S if all still fail
        if n_cells:
            r["A2N"] = "K" if "K" in n_cells else ("S" if all(c == "S" for c in n_cells) else ("E" if "E" in n_cells else "U"))
        r["SV"] = last_line_cell(MUT / "sv" / f"{p}_{i}.txt", "SV")
        crows.append(r)
    with open(LOG / "kill_matrix_v2_contracts.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["pkg", "index", "op", "direction", "watcher", "stmt", "A2U", "A2N", "SV"])
        w.writeheader()
        w.writerows(crows)

# ---- report ----
out = []
P = out.append
P("# Mutation kill matrix, v2 (plan step 9)\n")
P(f"Source: {MUT.relative_to(root)}. Generated by formal/mutation/v2/kill_matrix_v2.py.\n")
P(__doc__.split("\n\n", 1)[1])
P("\n## 1. Full population, oracle SIM\n")
P("| unit | mutants | K | S | E/U | missing | kill rate |")
P("|---|---|---|---|---|---|---|")
for u in UNITS:
    c = collections.Counter(r["SIM"] for r in pop if r["unit"] == u)
    n = sum(c.values())
    done = c["K"] + c["S"]
    P(f"| {u} | {n} | {c['K']} | {c['S']} | {c['E'] + c['U']} | {c['missing']} | {c['K']}/{done} ({100 * c['K'] / max(done, 1):.1f} %) |")
P("\nPer operator (SIM K / mutants):\n")
ops = sorted({r["op"] for r in pop})
P("| op | " + " | ".join(UNITS) + " |")
P("|---|" + "---|" * len(UNITS))
for op in ops:
    cells = []
    for u in UNITS:
        g = [r for r in pop if r["unit"] == u and r["op"] == op]
        cells.append(f"{sum(r['SIM'] == 'K' for r in g)}/{len(g)}" if g else "-")
    P(f"| {op} | " + " | ".join(cells) + " |")

P("\n## 2. Sample (120 per unit, stratified by operator), all applicable oracles\n")
for u in UNITS:
    g = [r for r in rows if r["unit"] == u]
    eq = [r for r in g if r["A1"] == "S" or r["EQ"] in ("EQ", "EQ-rom", "EQ-t6")]
    live = [r for r in g if r not in eq]
    P(f"\n### {u}\n")
    if u == "mon_lane":
        tri = collections.Counter(r["EQ"] for r in g)
        P(f"mutants {len(g)}; survivors of all oracles triaged by the equivalence check: "
          f"EQ {tri['EQ']}, EQ-rom {tri['EQ-rom']}, EQ-t6 {tri['EQ-t6']}, NE {tri['NE']}, U {tri['U']}; "
          f"equivalent (excluded) {len(eq)}; denominator {len(live)}\n")
    else:
        P(f"mutants {len(g)}; proven pin-equivalent (A1 = S) {len(eq)}; denominator {len(live)}\n")
    P("| oracle | family | K | S | U | E | missing | kill rate (of denominator) | 95 % CI |")
    P("|---|---|---|---|---|---|---|---|---|")
    for o in ORACLES:
        if o not in APPLIES[u]:
            continue
        c = collections.Counter(r[o] for r in live)
        P(f"| {o} | {FAMILY[o]} | {c['K']} | {c['S']} | {c['U']} | {c['E']} | {c['missing']} | {c['K']}/{len(live)} | {wilson(c['K'], len(live))} |")
    combos = collections.Counter("+".join(o for o in ORACLES if r[o] == "K") or "none" for r in live)
    P("\nKill sets (denominator mutants):\n")
    P("| kill set | mutants |")
    P("|---|---|")
    for k, v in combos.most_common():
        P(f"| {k} | {v} |")
    P("\nUnique kills (killed by exactly one oracle):\n")
    P("| oracle | unique kills |")
    P("|---|---|")
    for o in ORACLES:
        if o in APPLIES[u]:
            P(f"| {o} | {sum(1 for r in live if [x for x in ORACLES if r[x] == 'K'] == [o])} |")
    free = sum(1 for r in live if any(r[o] == "K" for o in ORACLES if FAMILY[o] == "spec-free"))
    only_based = sum(1 for r in live if any(r[o] == "K" for o in ORACLES if FAMILY[o] == "spec-based")
                     and not any(r[o] == "K" for o in ORACLES if FAMILY[o] == "spec-free"))
    P(f"\nkilled by a spec-free oracle: {free}/{len(live)}; killed only by spec-based oracles: {only_based}/{len(live)}")
    surv = [r for r in live if not any(r[o] == "K" for o in ORACLES)]
    P(f"\nSurvivors (no oracle kills, not proven equivalent): {len(surv)}\n")
    if surv:
        P("| index | op | desc | " + " | ".join(o for o in ORACLES if o in APPLIES[u]) + " | EQ |")
        P("|---|---|---|" + "---|" * (len(APPLIES[u]) + 1))
        for r in surv:
            P(f"| {r['index']} | {r['op']} | {r['desc']} | " + " | ".join(r[o] for o in ORACLES if o in APPLIES[u]) + f" | {r['EQ']} |")
    samp = collections.Counter(r["SIM"] for r in g)
    popc = collections.Counter(r["SIM"] for r in pop if r["unit"] == u)
    P(f"\nSample check: SIM kill rate in the sample {samp['K']}/{len(g)} vs population {popc['K']}/{popc['K'] + popc['S']}.")

if crows:
    P("\n## 3. Contract mutants (20 valid per package, stratified by operator)\n")
    invalid = collections.Counter(v[0] for v in cs.values() if v[3] == "invalid")
    P(f"Sites: {len(cs)}; rejected by Lang.validate / Compile / slot limit (not sampled): {sum(invalid.values())} "
      f"({', '.join(f'{k} {v}' for k, v in invalid.most_common())}).\n")
    P("| package | oracle | K | S | U | E | missing |")
    P("|---|---|---|---|---|---|---|")
    for p in ["uart_tx", "uart_rx", "spi_ctl", "spi_tgt", "usb"]:
        for o in ["A2U", "A2N", "SV"]:
            c = collections.Counter(r[o] for r in crows if r["pkg"] == p)
            P(f"| {p} | {o} | {c['K']} | {c['S']} | {c['U']} | {c['E']} | {c['missing']} |")
    combos = collections.Counter("+".join(o for o in ["A2U", "A2N", "SV"] if r[o] == "K") or "none" for r in crows)
    P("\nKill sets:\n")
    P("| kill set | mutants |")
    P("|---|---|")
    for k, v in combos.most_common():
        P(f"| {k} | {v} |")
    P("\nBy direction (operator class, nominal):\n")
    P("| direction | mutants | killed by any oracle | survived all |")
    P("|---|---|---|---|")
    for dname in sorted({r["direction"] for r in crows}):
        g = [r for r in crows if r["direction"] == dname]
        k = sum(1 for r in g if any(r[o] == "K" for o in ["A2U", "A2N", "SV"]))
        P(f"| {dname} | {len(g)} | {k} | {len(g) - k} |")
    tol = [r for r in crows if not any(r[o] == "K" for o in ["A2U", "A2N", "SV"])]
    P(f"\nContract-error tolerance: contract mutants no oracle catches: {len(tol)}/{len(crows)}\n")
    if tol:
        P("| package | index | op | direction | watcher | stmt | A2U | A2N | SV |")
        P("|---|---|---|---|---|---|---|---|---|")
        for r in tol:
            P(f"| {r['pkg']} | {r['index']} | {r['op']} | {r['direction']} | {r['watcher']} | {r['stmt']} | {r['A2U']} | {r['A2N']} | {r['SV']} |")

(LOG / "kill_matrix_v2.md").write_text("\n".join(out) + "\n")
print(f"wrote log/kill_matrix_v2.md ({len(rows)} sample rows, {len(pop)} population, {len(crows)} contract rows)")
