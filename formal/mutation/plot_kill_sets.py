"""Kill-set figure (UpSet style) from log/kill_matrix.csv.
usage: python plot_kill_sets.py <kill_matrix.csv> <out.png>
Bars: mutants not proven equivalent (A1 != S) grouped by the exact set of oracles that kill them.
Dot matrix: which oracles form each set. Colour = oracle family (spec-based / spec-free)."""
import sys
import collections
import csv
import matplotlib
import matplotlib.pyplot as plt

src, out = sys.argv[1], sys.argv[2]
rows = list(csv.DictReader(open(src)))
ORACLES = ["SIM", "A1", "A2", "B1"]
LABEL = {"SIM": "SIM  random co-sim vs partner model",
         "A1": "A1  formal refinement miter",
         "A2": "A2  formal UART monitor",
         "B1": "B1  formal timed QED"}
FAMILY = {"SIM": "spec-based", "A1": "spec-based", "A2": "spec-free", "B1": "spec-free"}
COL = {"spec-based": "#3b6ea8", "spec-free": "#c7782a"}
GREY = "#d0d0d0"

fig, axes = plt.subplots(2, 2, figsize=(7.2, 4.2), sharex="col",
                         gridspec_kw={"height_ratios": [2.2, 1.3], "hspace": 0.05, "wspace": 0.12})
for col, (target, title) in enumerate([("rtl", "RTL mutants"), ("spec", "Spec mutants")]):
    live = [r for r in rows if r["target"] == target and r["A1"] != "S"]
    n_all = sum(1 for r in rows if r["target"] == target)
    combos = collections.Counter(
        tuple(o for o in ORACLES if r[o] == "K") for r in live)
    order = sorted(combos.items(), key=lambda kv: (-kv[1], len(kv[0])))
    ax, mx = axes[0, col], axes[1, col]
    xs = range(len(order))
    for x, (k, n) in zip(xs, order):
        fam = {FAMILY[o] for o in k}
        c = GREY if not k else (COL[fam.pop()] if len(fam) == 1 else "#6b6b6b")
        ax.bar(x, n, color=c, width=0.7)
        ax.text(x, n + 1, str(n), ha="center", va="bottom", fontsize=6)
    ax.set_title(f"{title}\n{len(live)} of {n_all} not proven equivalent", loc="left", fontsize=8)
    ax.spines[["top", "right"]].set_visible(False)
    ax.set_ylim(0, max(n for _, n in order) * 1.18)
    if col == 0:
        ax.set_ylabel("mutants", fontsize=8)
    ax.tick_params(labelsize=6)
    for y, o in enumerate(ORACLES):
        for x, (k, _) in zip(xs, order):
            on = o in k
            mx.plot(x, y, "o", ms=4.5, color=COL[FAMILY[o]] if on else GREY, zorder=3)
        ks = [x for x, (k, _) in zip(xs, order) if o in k]
    for x, (k, _) in zip(xs, order):
        ys = [ORACLES.index(o) for o in k]
        if len(ys) > 1:
            mx.plot([x, x], [min(ys), max(ys)], color="#555555", lw=1, zorder=2)
    mx.set_yticks(range(len(ORACLES)))
    mx.set_yticklabels([LABEL[o] if col == 0 else "" for o in ORACLES], fontsize=6)
    for t, o in zip(mx.get_yticklabels(), ORACLES):
        t.set_color(COL[FAMILY[o]])
    mx.set_ylim(len(ORACLES) - 0.5, -0.5)
    mx.set_xticks([])
    mx.set_xlim(-0.6, len(order) - 0.4)
    for s in mx.spines.values():
        s.set_visible(False)
    mx.tick_params(left=False)
    nk = [x for x, (k, _) in zip(xs, order) if not k]
    if nk:
        mx.text(nk[0], len(ORACLES) - 0.55, "no kill", ha="center", va="top", fontsize=6, color="#555555")
fig.text(0.01, 0.99, "Spec-based and spec-free oracles kill different mutants", fontsize=8,
         ha="left", va="top", weight="bold")
h = [matplotlib.patches.Patch(color=COL["spec-based"], label="killed only by spec-based oracles"),
     matplotlib.patches.Patch(color=COL["spec-free"], label="killed only by spec-free oracles"),
     matplotlib.patches.Patch(color="#6b6b6b", label="killed by both families"),
     matplotlib.patches.Patch(color=GREY, label="no oracle kills (unresolved)")]
fig.legend(handles=h, loc="upper right", bbox_to_anchor=(0.995, 0.995), ncol=2, fontsize=6, frameon=False)
fig.subplots_adjust(left=0.30, right=0.99, top=0.80, bottom=0.03)
fig.savefig(out, dpi=300)
print("saved", out)
