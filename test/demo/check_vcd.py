"""Decode demo waveforms (.vcd.gz) and report end time, clock cycles and value-change counts of
the top-level buses, so a shipped waveform is known to be complete and readable.
usage: python3 check_vcd.py results/rtl/*.vcd.gz"""
import gzip
import sys


def summary(path):
    ids, last, changes, clk_rise, prev = {}, 0, {}, 0, {}
    with gzip.open(path, "rt") as f:
        for line in f:
            if line.startswith("$var"):
                p = line.split()
                ids[p[3]] = p[4]
            elif line.startswith("#"):
                last = int(line[1:])
            elif line.startswith("b"):
                v, i = line[1:].split()
                n = ids.get(i)
                if n and prev.get(n) != v:
                    changes[n] = changes.get(n, 0) + 1
                    prev[n] = v
            elif line[:1] in ("0", "1") and ids.get(line[1:].strip()) == "clk" and line[0] == "1":
                clk_rise += 1
    return last, clk_rise, changes


def settled(path):
    """settled values of all buses at the end of every time step in which clk rises or falls
    (same-step ordering and redundant writes, which differ between RTL and GL dumps, drop out)"""
    ids, cur, out, t, edge = {}, {}, [], None, False
    names = ("ui_in", "uio_in", "uio_out", "uio_oe", "uo_out", "rst_n")

    def flush():
        if edge:
            out.append((t,) + tuple(cur.get(n) for n in names))

    with gzip.open(path, "rt") as f:
        for line in f:
            if line.startswith("$var"):
                p = line.split()
                ids[p[3]] = p[4]
            elif line.startswith("#"):
                flush()
                t, edge = int(line[1:]), False
            elif line.startswith("b"):
                v, i = line[1:].split()
                if i in ids:
                    cur[ids[i]] = int(v, 2) if set(v) <= {"0", "1"} else v
            elif line[:1] in ("0", "1", "x", "z") and line[1:].strip() in ids:
                n = ids[line[1:].strip()]
                cur[n] = line[0]
                if n == "clk":
                    edge = True
    flush()
    return out


if __name__ == "__main__" and len(sys.argv) > 1 and sys.argv[1] == "--compare":
    # --compare dirA dirB: settled bus values at every clock edge must match per scenario
    from pathlib import Path
    da, db = Path(sys.argv[2]), Path(sys.argv[3])
    bad = 0
    for fa in sorted(da.glob("*.vcd.gz")):
        sa, sb = settled(fa), settled(db / fa.name)
        # GL starts with X on outputs until the first clocked reset edge: compare from the first
        # edge at which both have fully defined outputs
        def start(s):
            return next(k for k, r in enumerate(s) if all(isinstance(x, int) for x in r[3:6]))
        ka, kb = start(sa), start(sb)
        diff = [k for k, (x, y) in enumerate(zip(sa[max(ka, kb):], sb[max(ka, kb):])) if x != y]
        same_len = len(sa) == len(sb)
        ok = same_len and not diff
        bad += not ok
        print(f"{fa.name}: {len(sa)} edges, defined from edge {ka}/{kb}, "
              f"{'identical' if ok else f'{len(diff)} differing edges, first {diff[:1]}'}")
    print(f"{bad} scenarios differ")
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    for p in sys.argv[1:]:
        last, cyc, c = summary(p)
        names = ("ui_in", "uio_in", "uio_out", "uio_oe", "uo_out")
        print(f"{p}: end {last / 1e3:.0f} ns, {cyc} clock cycles, changes "
              + " ".join(f"{k}={c.get(k, 0)}" for k in names))
