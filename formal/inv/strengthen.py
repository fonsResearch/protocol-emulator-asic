"""Write a strengthened AIGER model: bad' = bad | OR_j (G & ~c_j), and check that it extends
the original model (formal/inv/README.md).

Soundness argument (the only part of the flow that the theorem depends on, besides ABC /
Certifaiger): if the strengthened model has the same inputs, latches, latch next-state
functions and AND gates as the original (new gates only appended) and its bad literal is
OR(original bad, X), then every trace of the original model is a trace of the strengthened
one with bad'(t) >= bad(t). So "bad' never fires" implies "bad never fires". check_extension
verifies exactly these structural facts by re-reading both files.
"""
import sys

import aig as A


def _enc_delta(x):
    out = bytearray()
    while x & ~0x7F:
        out.append((x & 0x7F) | 0x80)
        x >>= 7
    out.append(x)
    return bytes(out)


class Builder:
    def __init__(self, g):
        self.g = g
        self.maxvar = g.M
        self.new_ands = []
        self.memo = {}
        for lhs, r0, r1 in g.ands:
            self.memo[(r0, r1)] = lhs

    def AND(self, a, b):
        if a == 0 or b == 0 or a == (b ^ 1):
            return 0
        if a == 1:
            return b
        if b == 1 or a == b:
            return a
        r0, r1 = max(a, b), min(a, b)
        if (r0, r1) in self.memo:
            return self.memo[(r0, r1)]
        self.maxvar += 1
        lhs = 2 * self.maxvar
        self.new_ands.append((lhs, r0, r1))
        self.memo[(r0, r1)] = lhs
        return lhs

    def OR(self, a, b):
        return self.AND(a ^ 1, b ^ 1) ^ 1

    def ANDn(self, ls):
        # balanced tree (a linear chain gives logic depth ~ number of lemmas)
        ls = list(ls)
        if not ls:
            return 1
        while len(ls) > 1:
            ls = [self.AND(ls[i], ls[i + 1]) if i + 1 < len(ls) else ls[i] for i in range(0, len(ls), 2)]
        return ls[0]

    def ORn(self, ls):
        return self.ANDn([l ^ 1 for l in ls]) ^ 1

    def XOR(self, a, b):
        return self.OR(self.AND(a, b ^ 1), self.AND(a ^ 1, b))

    def latch(self, k):
        return self.g.latch_lit(k)

    def reg_eq(self, idxs, v):
        return self.ANDn([self.latch(i) if (v >> b) & 1 else self.latch(i) ^ 1 for b, i in enumerate(idxs)])

    def reg_le(self, idxs, v):
        r = 1
        for b, i in enumerate(idxs):
            x = self.latch(i)
            r = self.OR(x ^ 1, r) if (v >> b) & 1 else self.AND(x ^ 1, r)
        return r

    def adder_eq(self, ia, ib, sign, v):
        xa = [self.latch(i) for i in ia]
        xb = [self.latch(i) for i in ib]
        carry = 0
        if sign < 0:
            xb = [x ^ 1 for x in xb]
            carry = 1
        out = []
        for a, b in zip(xa, xb):
            out.append(self.XOR(self.XOR(a, b), carry))
            carry = self.OR(self.AND(a, b), self.AND(carry, self.XOR(a, b)))
        return self.ANDn([o if (v >> k) & 1 else o ^ 1 for k, o in enumerate(out)])

    def cand(self, c):
        t = c[0]
        if t == "bit":
            x = self.latch(c[1])
            return x if c[2] else x ^ 1
        if t == "beq":
            e = self.XOR(self.latch(c[1]), self.latch(c[2])) ^ 1
            return e ^ 1 if c[3] else e
        if t == "eq":
            return self.reg_eq(c[1], c[2])
        if t == "in":
            return self.ORn([self.reg_eq(c[1], v) for v in c[2]])
        if t == "le":
            return self.reg_le(c[1], c[2])
        if t == "imp":
            return self.OR(self.cand(c[1]) ^ 1, self.cand(c[2]))
        if t == "not":
            return self.cand(c[1]) ^ 1
        if t == "and":
            return self.ANDn([self.cand(x) for x in c[1:]])
        if t == "lin":
            return self.adder_eq(c[1], c[2], c[3], c[4])
        raise ValueError(t)


def write_strengthened(g, cands, guard, out_path, include_orig=True):
    """Model with one bad literal: OR(original bads/outputs, G & ~c_j). With
    include_orig=False the bad literal is OR_j (G & ~c_j) only (lemma invariance check)."""
    b = Builder(g)
    old_bad = b.ORn(g.outputs + g.bads)
    G = b.ANDn([b.latch(i) ^ 1 for i in guard])
    viol = b.ORn([b.AND(G, b.cand(c) ^ 1) for c in cands])
    new_bad = b.OR(old_bad, viol) if include_orig else viol
    ands = g.ands + b.new_ands
    M = b.maxvar
    hdr = "aig %d %d %d 0 %d 1\n" % (M, g.I, g.L, len(ands))
    out = bytearray(hdr.encode())
    for nl in g.latch_next:
        out += b"%d\n" % nl
    out += b"%d\n" % new_bad
    for lhs, r0, r1 in ands:
        out += _enc_delta(lhs - r0) + _enc_delta(r0 - r1)
    with open(out_path, "wb") as f:
        f.write(bytes(out))
    return old_bad, viol, new_bad


def check_extension(orig_path, new_path):
    """Structural check that [new] extends [orig] (see module doc). Returns a message;
    raises on any violation."""
    g0, g1 = A.Aig(orig_path), A.Aig(new_path)
    assert g1.I == g0.I and g1.L == g0.L, "inputs/latches differ"
    assert g1.latch_next == g0.latch_next, "latch next-state functions differ"
    assert g1.ands[: len(g0.ands)] == g0.ands, "original AND gates not preserved"
    assert g1.O + g1.B == 1, "expected one bad literal"
    nb = (g1.outputs + g1.bads)[0]
    defs = {lhs: (r0, r1) for lhs, r0, r1 in g1.ands}
    # recompute OR(original bads/outputs) exactly as written: the new bad must be an OR whose
    # one disjunct is that literal. OR(x, y) = NOT AND(NOT x, NOT y).
    olds = g0.outputs + g0.bads
    assert nb & 1 == 1 and (nb ^ 1) in defs, "new bad is not an OR gate"
    r0, r1 = defs[nb ^ 1]
    disj = {r0 ^ 1, r1 ^ 1}
    # old bad as built by Builder.ORn: single literal, or NOT of an AND chain of negations
    if len(olds) == 1:
        old_bad = olds[0]
    else:
        raise AssertionError("multi-output originals not supported by the checker")
    assert old_bad in disj, "original bad is not a disjunct of the new bad"
    return "extension ok: %d original ANDs preserved, %d appended, bad' = OR(bad=%d, X)" % (
        len(g0.ands), len(g1.ands) - len(g0.ands), old_bad)


if __name__ == "__main__":
    print(check_extension(sys.argv[1], sys.argv[2]))
