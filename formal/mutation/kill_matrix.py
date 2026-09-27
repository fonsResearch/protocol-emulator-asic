#!/usr/bin/env python3
"""Aggregate formal/work/mut/*/result.txt into log/kill_matrix.csv and log/kill_matrix.md.

Cell codes per oracle:
  K  killed (formal: FAIL and the counterexample replays in cyclesim; SIM: miter bad observed)
  S  survived (formal: property proved for the mutant; SIM: no difference in the run)
  U  undecided (engine gave up, or the wall-clock limit was hit)
  E  error (yosys error, init-check failure, or a counterexample that does NOT replay)
A1 = S means the mutant is proven pin-equivalent to the unmutated partner model from reset
(an equivalent mutant with respect to the pins); it is excluded from the kill-rate denominators.
"""
import csv, collections, pathlib, re, sys

root = pathlib.Path(__file__).resolve().parents[2]
import os
mut = root / os.environ.get("MUT_DIR", "formal/work/mut")
ORACLES = ["SIM", "A1", "A2", "B1"]


def cell_formal(row):
    parts = [p.strip() for p in row.split("|")]
    # ['', name, expected, engine, result, depth, stats, wall, replay, '']
    if len(parts) < 9:
        return "E", "", ""
    res, depth, wall, replay = parts[4], parts[5], parts[7], parts[8]
    if res == "FAIL":
        return ("K" if replay == "replay ok" else "E"), depth, wall
    if res == "PASS":
        return "S", "", wall
    if res in ("UNDECIDED", "TIMEOUT"):
        return "U", "", wall
    return "E", "", wall


rows = []
for target in ["rtl", "spec"]:
    sites_f = mut / f"sites_{target}.csv"
    if not sites_f.exists():
        continue
    for line in sites_f.read_text().splitlines():
        idx, op, desc = line.split(",", 2)
        r = {"target": target, "index": int(idx), "op": op, "desc": desc}
        res_f = mut / f"{target}_{idx}" / "result.txt"
        if not res_f.exists():
            r.update({o: "missing" for o in ORACLES})
            rows.append(r)
            continue
        for l in res_f.read_text().splitlines():
            key, _, rest = l.partition(" ")
            if key == "SIM":
                m = re.search(r"cycle=(\d+)", rest)
                r["SIM"] = "K" if rest.startswith("KILLED") else ("S" if rest.startswith("SURVIVED") else "E")
                r["SIM_cycle"] = m.group(1) if m else ""
            elif key in ORACLES:
                c, depth, wall = cell_formal(rest)
                r[key], r[key + "_depth"], r[key + "_wall_s"] = c, depth, wall
        rows.append(r)

missing = sum(1 for r in rows if r.get("SIM") == "missing")
cols = ["target", "index", "op", "desc"] + sum(
    [[o, o + ("_cycle" if o == "SIM" else "_depth")] + ([] if o == "SIM" else [o + "_wall_s"]) for o in ORACLES], [])
out_csv = root / "log/kill_matrix.csv"
with out_csv.open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
    w.writeheader()
    for r in rows:
        w.writerow(r)

md = ["# Mutation kill matrix", "",
      f"Source: formal/work/mut (campaign), {len(rows)} mutants, {missing} missing results.",
      "Codes: K killed (formal cex replayed in cyclesim), S survived (formal: proved), U undecided (timeout), E error.",
      "A1 = S: mutant proven pin-equivalent to the partner model from reset; excluded from kill-rate denominators.", ""]
for target in ["rtl", "spec"]:
    tr = [r for r in rows if r["target"] == target and r.get("SIM") != "missing"]
    if not tr:
        continue
    equiv = [r for r in tr if r.get("A1") == "S"]
    live = [r for r in tr if r.get("A1") != "S"]
    md += [f"## target = {target}", "",
           f"mutants {len(tr)}; proven pin-equivalent (A1 = S) {len(equiv)}; non-equivalent or unresolved {len(live)}", ""]
    md += ["| oracle | K | S | U | E | kill rate on non-equivalent |", "|---|---|---|---|---|---|"]
    for o in ORACLES:
        c = collections.Counter(r.get(o, "E") for r in tr)
        kl = sum(1 for r in live if r.get(o) == "K")
        md.append(f"| {o} | {c['K']} | {c['S']} | {c['U']} | {c['E']} | {kl}/{len(live)} |")
    # kill-set combinations over non-equivalent mutants
    combo = collections.Counter("+".join(o for o in ORACLES if r.get(o) == "K") or "none" for r in live)
    md += ["", "Kill sets (non-equivalent mutants): oracles that kill each mutant", "",
           "| kill set | mutants |", "|---|---|"]
    for k, n in combo.most_common():
        md.append(f"| {k} | {n} |")
    spec_free = sum(1 for r in live if r.get("A2") == "K" or r.get("B1") == "K")
    spec_based_only = sum(1 for r in live if (r.get("A1") == "K" or r.get("SIM") == "K")
                          and not (r.get("A2") == "K" or r.get("B1") == "K"))
    md += ["", f"killed by a spec-free oracle (A2 or B1): {spec_free}/{len(live)}; "
               f"killed only by spec-based oracles (SIM or A1): {spec_based_only}/{len(live)}", ""]
    surv = [r for r in live if not any(r.get(o) == "K" for o in ORACLES)]
    md += [f"Survivors (no oracle kills, not proven equivalent): {len(surv)}", ""]
    if surv:
        md += ["| index | op | desc | SIM | A1 | A2 | B1 |", "|---|---|---|---|---|---|---|"]
        for r in surv:
            md.append(f"| {r['index']} | {r['op']} | {r['desc']} | {r.get('SIM')} | {r.get('A1')} | {r.get('A2')} | {r.get('B1')} |")
    md.append("")
    # per operator
    md += ["Per operator (non-equivalent / proven-equivalent):", "", "| op | non-equiv | equiv |", "|---|---|---|"]
    ops = sorted(set(r["op"] for r in tr))
    for op in ops:
        md.append(f"| {op} | {sum(1 for r in live if r['op'] == op)} | {sum(1 for r in equiv if r['op'] == op)} |")
    md.append("")
(root / "log/kill_matrix.md").write_text("\n".join(md) + "\n")
print(f"rows={len(rows)} missing={missing}")
