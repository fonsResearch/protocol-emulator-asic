"""Convert one inv_traces.exe record into an ABC write_cex -a style input prefix for a model.

usage: python trace2cex.py <traces.bin> <trace index> <cycles> <model.aig> <model.map> <out.cex>

The prefix starts from the zero state; it is used by ckpt_bmc.py (checkpoints) and can be
replayed with replay_cex.exe when its last frame is the first bad frame.
"""
import sys

import numpy as np

import aig as A


def record(path, idx):
    raw = np.fromfile(path, dtype=np.uint8)
    off = 0
    for k in range(idx + 1):
        n = int(raw[off:off + 4].view(np.uint32)[0])
        if k == idx:
            return raw[off + 4: off + 4 + 3 * n].reshape(n, 3)
        off += 4 + 3 * n
    raise IndexError(idx)


def write(rec, cycles, g, inputs, out):
    with open(out, "w") as f:
        f.write("0" * g.L + "\n")
        for c in range(min(cycles, rec.shape[0])):
            line = []
            for k in range(g.I):
                name, bit = inputs[k]
                fl = A.TRACE_FIELDS[name]
                if fl is None:
                    line.append("0")
                    continue
                byte, b = fl
                line.append(str((int(rec[c, byte]) >> (bit if b is None else b)) & 1))
            f.write("".join(line) + "\n")
        f.write("# DONE\n")


if __name__ == "__main__":
    tb, idx, cycles, model, mp, out = sys.argv[1:7]
    g = A.Aig(model)
    inputs, _, _ = A.read_map(mp)
    write(record(tb, int(idx)), int(cycles), g, inputs, out)
