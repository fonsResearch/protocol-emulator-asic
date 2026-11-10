"""Kill-set figure (UpSet style) for the v2 campaign (plan step 9).
usage: python3 plot_kill_sets_v2.py <kill_matrix_v2.csv> <kill_matrix_v2_contracts.csv> <out.png>
Panels: one per graph unit (sampled mutants not proven equivalent: A1 = S for the lane units,
the equivalence triage for the monitor lane) and one for the contract
mutants. Bars: mutants grouped by the exact set of oracles that kill them (grey = none);
dot matrix below: which oracles form each set. Dot colour = oracle family."""
import collections
import csv
import sys

import matplotlib.pyplot as plt

src, csrc, out = sys.argv[1:4]
rows = list(csv.DictReader(open(src)))
crows = list(csv.DictReader(open(csrc)))
SPEC_BASED, SPEC_FREE, CONTRACT, NONE = "#3b6ea8", "#c7782a", "#5a8f5a", "#b0b0b0"
PANELS = [
    ("lane_rtl", "Lane RTL", ["SIM", "A1", "C3", "SR"]),
    ("lane_spec", "Lane spec circuit", ["SIM", "A1", "A2"]),
    ("mon_lane", "Monitor lane", ["SIM", "R1b", "C3", "SR"]),
    ("contracts", "Contracts (5 packages)", ["A2U", "A2N", "SV"]),
]
COLOUR = {"SIM": SPEC_BASED, "A1": SPEC_BASED, "R1b": SPEC_BASED, "C3": SPEC_BASED, "A2": SPEC_FREE,
          "SR": SPEC_FREE, "A2U": CONTRACT, "A2N": CONTRACT, "SV": CONTRACT}

fig, axes = plt.subplots(2, 4, figsize=(7.2, 3.4),
                         gridspec_kw={"height_ratios": [2.2, 1.1], "hspace": 0.06, "wspace": 0.35})
for col, (unit, title, oracles) in enumerate(PANELS):
    if unit == "contracts":
        live = crows
    else:
        live = [r for r in rows if r["unit"] == unit and r.get("A1") != "S" and r.get("EQ") not in ("EQ", "EQ-rom", "EQ-t6")]
    combos = collections.Counter(tuple(o for o in oracles if r[o] == "K") for r in live)
    order = sorted(combos.items(), key=lambda kv: (len(kv[0]) == 0, -kv[1]))
    ax, mx = axes[0, col], axes[1, col]
    xs = range(len(order))
    ax.bar(xs, [v for _, v in order], color=[NONE if not k else "#4d4d4d" for k, _ in order], width=0.7)
    for x, (_, v) in zip(xs, order):
        ax.text(x, v, str(v), ha="center", va="bottom", fontsize=6)
    ax.set_title(f"{title}\n(n = {len(live)})", fontsize=7, loc="left")
    ax.set_xticks([])
    ax.spines[["top", "right"]].set_visible(False)
    ax.margins(y=0.15)
    if col == 0:
        ax.set_ylabel("mutants")
    for y, o in enumerate(oracles):
        for x, (k, _) in zip(xs, order):
            on = o in k
            mx.plot(x, y, "o", ms=3.5, color=COLOUR[o] if on else "#e4e4e4", zorder=3)
        sel = [x for x, (k, _) in zip(xs, order) if o in k]
    for x, (k, _) in zip(xs, order):
        ys = [oracles.index(o) for o in k]
        if len(ys) > 1:
            mx.plot([x, x], [min(ys), max(ys)], color="#4d4d4d", lw=0.8, zorder=2)
    mx.set_yticks(range(len(oracles)))
    mx.set_yticklabels(oracles, fontsize=6)
    mx.set_ylim(-0.6, len(oracles) - 0.4)
    mx.set_xlim(ax.get_xlim())
    mx.set_xticks([])
    mx.invert_yaxis()
    for s in mx.spines.values():
        s.set_visible(False)
    mx.tick_params(length=0)
handles = [plt.Line2D([], [], marker="o", ls="", color=c, ms=4, label=l) for c, l in
           [(SPEC_BASED, "spec-based oracle"), (SPEC_FREE, "spec-free oracle"), (CONTRACT, "contract oracle")]]
handles.append(plt.Rectangle((0, 0), 1, 1, color=NONE, label="killed by no oracle"))
fig.legend(handles=handles, loc="lower center", ncol=4, frameon=False, fontsize=6, bbox_to_anchor=(0.5, -0.02))
fig.savefig(out, dpi=300, bbox_inches="tight")
print("wrote", out)
