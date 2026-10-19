"""Checkpoint BMC: find a deep counterexample of <model> by short BMC runs started from states
reached by a known input prefix (for example the trace of a mutant control that shares the
model's behaviour up to the mutated instruction).

usage: python ckpt_bmc.py <model.aig> <prefix.cex> <workdir> <frames,...> <bmc depth> <timeout s>

For each checkpoint frame f: simulate the prefix inputs 0..f-1 on the model (zero initial
state), write an AIG whose initial state is the state at f (latches starting at 1 are stored
complemented, so the file keeps AIGER zero-init semantics), run ABC bmc3 from it, and on a hit
write <workdir>/full_<f>.cex = prefix frames 0..f-1 + the BMC frames, starting from the zero
state of the ORIGINAL model. Only a cyclesim replay of that full trace on the original harness
(replay_cex.exe) counts as evidence; nothing here is trusted.
"""
import os
import re
import subprocess
import sys

import aig as A


def read_cex(path):
    lines = [l.strip() for l in open(path)]
    frames = []
    for l in lines[1:]:
        if not l or l.startswith("#") or l == ".":
            break
        frames.append(l)
    return lines[0], frames


def simulate(g, frames):
    """latch values (list of 0/1) after applying input frames from the zero state"""
    val = [0] * (g.M + 1)
    lat = [0] * g.L

    def lit(l):
        return val[l >> 1] ^ (l & 1)

    for fr in frames:
        for k in range(g.I):
            val[1 + k] = int(fr[k])
        for k in range(g.L):
            val[1 + g.I + k] = lat[k]
        for lhs, r0, r1 in g.ands:
            val[lhs >> 1] = lit(r0) & lit(r1)
        lat = [lit(n) for n in g.latch_next]
    return lat


def write_with_init(g, init, path):
    """Same model, initial state [init], zero-init encoding: latch k with init 1 is replaced
    by its complement q' = ~q (next' = ~next), and every use of q reads ~q'."""
    flip = {1 + g.I + k for k in range(g.L) if init[k]}

    def m(l):
        return l ^ 1 if (l >> 1) in flip else l

    # AND inputs may change polarity; binary AIGER needs lhs > r0 >= r1 (still holds: only the
    # sign bit changes, the variable order is unchanged), so re-sort each pair.
    ands = []
    for lhs, r0, r1 in g.ands:
        a, b = m(r0), m(r1)
        ands.append((lhs, max(a, b), min(a, b)))
    nexts = [m(n) ^ (1 if init[k] else 0) for k, n in enumerate(g.latch_next)]
    bads = [m(b) for b in g.outputs + g.bads]
    out = bytearray(("aig %d %d %d 0 %d %d\n" % (g.M, g.I, g.L, len(ands), len(bads))).encode())
    for n in nexts:
        out += b"%d\n" % n
    for b in bads:
        out += b"%d\n" % b
    from strengthen import _enc_delta
    for lhs, r0, r1 in ands:
        out += _enc_delta(lhs - r0) + _enc_delta(r0 - r1)
    with open(path, "wb") as f:
        f.write(bytes(out))


def main():
    model, prefix, wd, fl, depth, tmo = sys.argv[1:7]
    g = A.Aig(model)
    l0, frames = read_cex(prefix)
    os.makedirs(wd, exist_ok=True)
    for f in [int(x) for x in fl.split(",")]:
        st = simulate(g, frames[:f])
        p = os.path.join(wd, "ck_%d.aig" % f)
        write_with_init(g, st, p)
        cx = os.path.join(wd, "ck_%d.cex" % f)
        r = subprocess.run(
            ["perl", "formal/glimit.pl", tmo, "yosys-abc", "-c",
             "read_aiger %s; bmc3 -F %s -T %s; write_cex -a %s" % (p, depth, tmo, cx)],
            capture_output=True, text=True)
        o = re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr)
        hit = re.search(r"asserted in frame (\d+)", o)
        print("checkpoint %d: %s" % (f, ("bad at +%s" % hit.group(1)) if hit else "no hit"), flush=True)
        if hit:
            _, suf = read_cex(cx)
            full = os.path.join(wd, "full_%d.cex" % f)
            with open(full, "w") as fo:
                fo.write(l0 + "\n")
                for fr in frames[:f] + suf:
                    fo.write(fr + "\n")
                fo.write("# DONE\n")
            print("  full trace %s: %d frames (bad expected at frame %d)" % (full, f + len(suf), f + len(suf) - 1))
            return


if __name__ == "__main__":
    main()
