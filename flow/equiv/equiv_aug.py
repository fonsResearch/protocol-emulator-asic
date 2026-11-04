#!/usr/bin/env python3
"""Correspondence augmentation for name-based Yosys equivalence (equiv_make / equiv_induct).

Synthesis keeps RTL wire names as hints on netlist nets, but a hint can be wrong for the
pairing: fsm_recode re-encodes state registers one-hot while some one-hot bits keep the name
of a binary state bit (core._955[1] etc.), and some nets carry the name of a different RTL
wire than the value they hold (core._13013 holds s2_ui[0]). equiv_make pairs by name, so these
become false pairs that no inductive proof can close, and they poison every dependent pair.

This tool, driven by a JSON map, renames each such gate net to a fresh name (so the false pair
disappears) and pairs it with an explicit gold helper expression under a common new name:
  {"rename": {"<gate net>": "<gold Verilog expression over pemu_core_v1m signals>", ...}}
Example: {"rename": {"_955[1]": "(_955 == 2'b10)", "_13013": "s2_ui[0]"}}
Helpers are (* keep *) so opt_clean cannot drop them. The helper pairs are proof OBLIGATIONS,
not assumptions: equiv_induct proves them together with every other pair, and a wrong entry
shows up as an unproven fixh_* pair. Entries must be mutually consistent (a contradictory set
makes the induction hypothesis unsatisfiable and nothing is proven).

usage: equiv_aug.py <map.json> <rtl_core.v> <fin_cut.v> <out_rtl_core.v> <out_fin_cut.v>
"""
import json, re, sys

mp, rtl_in, gate_in, rtl_out, gate_out = sys.argv[1:6]
ren = json.load(open(mp)).get("rename", {})
gate = open(gate_in).read()
rtl = open(rtl_in).read()
gold_add, gate_add = [], []
for gname, gexpr in ren.items():
    old = f"\\core.{gname} "
    tag = re.sub(r"\W", "_", gname).strip("_")
    new = f"\\core.fixg_{tag} "
    n = gate.count(old)
    if n < 2:
        sys.exit(f"gate net {old.strip()} occurs {n} times (expected a declared, used net)")
    gate = gate.replace(old, new)
    gate_add.append(f"  (* keep *) wire \\core.fixh_{tag} ;\n  assign \\core.fixh_{tag}  = {new};\n")
    gold_add.append(f"  (* keep *) wire fixh_{tag};\n  assign fixh_{tag} = {gexpr};\n")
    print(f"{old.strip():24s} ({n:2d} refs) -> fixh_{tag} == gold {gexpr}")
# Invariants: gold-only predicates that must hold in every reachable state (e.g. a 3-state FSM
# held in 2 bits never reaches the unused code). Each becomes a pair gold <expr> == gate 1'b1:
# assumed for the induction window and proven at the next step like every other pair, so it is
# an obligation (an inductive invariant of the gold design), not an unchecked assumption.
for name, gexpr in json.load(open(mp)).get("invariant", {}).items():
    gate_add.append(f"  (* keep *) wire \\core.fixh_{name} ;\n  assign \\core.fixh_{name}  = 1'b1;\n")
    gold_add.append(f"  (* keep *) wire fixh_{name};\n  assign fixh_{name} = {gexpr};\n")
    print(f"invariant fixh_{name}: gold {gexpr} == 1")
# Drops: gate COMBINATIONAL nets whose name hint is not the gold wire of that name. Renaming
# them removes the pair (one assumption and one obligation). Removing pairs can only make the
# induction harder, never unsound; outputs and macro pins stay compared. Never drop a flop.
for gname in json.load(open(mp)).get("drop", []):
    old = f"\\core.{gname} "
    tag = re.sub(r"\W", "_", gname).strip("_")
    new = f"\\core.dropg_{tag} "
    if re.search(r"\.Q\(" + re.escape(old) + r"\)", gate):
        sys.exit(f"refusing to drop {old.strip()}: it is a flop output")
    n = gate.count(old)
    gate = gate.replace(old, new)
    print(f"drop {old.strip()} ({n} refs)")
i = gate.index("endmodule")          # top module is the first (and only) module of the cut netlist
gate = gate[:i] + "".join(gate_add) + gate[i:]
m = re.search(r"module pemu_core_v1m\b", rtl)
j = rtl.index("endmodule", m.end())
rtl = rtl[:j] + "".join(gold_add) + rtl[j:]
open(gate_out, "w").write(gate)
open(rtl_out, "w").write(rtl)
