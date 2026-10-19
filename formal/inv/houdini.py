"""Candidate mining and Houdini filtering on an AIGER model (I2C invariant-mining flow,
formal/inv/README.md).

Candidates are state predicates c(s), each guarded by G(s) = no blame so far and environment
ok (latches h_blame_seen = h_env_bad = 0): the lemma is G -> c. They are mined from the
distinct guarded states that formal/inv/aig.py's simulator collected, then filtered:
  base:  every candidate holds in all states reachable in < k steps from the zero initial
         state (BMC);
  step:  Houdini with k-induction: the largest subset S such that S and not-bad holding in
         k consecutive states implies S and not-bad in the next state.
The surviving set is a proof only after formal/inv/strengthen.py has written it into the
model as bad' = bad | (G & ~c) and ABC (and Certifaiger) have proved bad' unreachable.
"""
import itertools
import numpy as np
from pysat.solvers import Solver

import aig as A


# ---------------------------------------------------------------- states and registers

def load_states(states_path, g):
    NW = (g.L + 63) // 64
    raw = np.fromfile(states_path, dtype=np.uint64).reshape(-1, NW)
    bits = np.unpackbits(raw.view(np.uint8).reshape(raw.shape[0], -1), axis=1, bitorder="little")[:, : g.L]
    return bits


def reg_values(bits, idxs):
    v = np.zeros(bits.shape[0], dtype=np.int64)
    for b, i in enumerate(idxs):
        v |= bits[:, i].astype(np.int64) << b
    return v


# ---------------------------------------------------------------- candidate language
# ("eq", idxs, v)          register == v
# ("in", idxs, [v...])     register in set
# ("le", idxs, v)          register <= v (unsigned)
# ("imp", c1, c2)          c1 -> c2
# ("lin", a, b, sign, v)   (a + sign*b) mod 2^w == v   (w = width of a = width of b)
# ("bit", i, val)          latch i == val
# ("beq", i, j, neg)       latch i == latch j (xor neg)
# The guard is added by the encoder.

def ev(c, bits, cache):
    """evaluate a candidate on the state matrix (bool vector)"""
    t = c[0]
    if t == "bit":
        return bits[:, c[1]] == c[2]
    if t == "beq":
        return (bits[:, c[1]] ^ bits[:, c[2]]) == c[3]
    def rv(idxs):
        k = tuple(idxs)
        if k not in cache:
            cache[k] = reg_values(bits, idxs)
        return cache[k]
    if t == "eq":
        return rv(c[1]) == c[2]
    if t == "in":
        return np.isin(rv(c[1]), np.array(c[2]))
    if t == "le":
        return rv(c[1]) <= c[2]
    if t == "imp":
        return ~ev(c[1], bits, cache) | ev(c[2], bits, cache)
    if t == "not":
        return ~ev(c[1], bits, cache)
    if t == "and":
        r = np.ones(bits.shape[0], bool)
        for x in c[1:]:
            r &= ev(x, bits, cache)
        return r
    if t == "lin":
        w = len(c[1])
        return ((rv(c[1]) + c[3] * rv(c[2])) & ((1 << w) - 1)) == c[4]
    raise ValueError(t)


def show(c, names):
    t = c[0]
    n = lambda idxs: names.get(tuple(idxs), "?")
    if t == "bit":
        return "L%d=%d" % (c[1], c[2])
    if t == "beq":
        return "L%d %s L%d" % (c[1], "!=" if c[3] else "==", c[2])
    if t == "eq":
        return "%s=%d" % (n(c[1]), c[2])
    if t == "in":
        return "%s in {%s}" % (n(c[1]), ",".join(map(str, c[2])))
    if t == "le":
        return "%s<=%d" % (n(c[1]), c[2])
    if t == "imp":
        return "(%s -> %s)" % (show(c[1], names), show(c[2], names))
    if t == "not":
        return "!(%s)" % show(c[1], names)
    if t == "and":
        return " & ".join(show(x, names) for x in c[1:])
    if t == "lin":
        return "%s %s %s == %d" % (n(c[1]), "+" if c[3] > 0 else "-", n(c[2]), c[4])
    return str(c)


def _groups(kns, regs, rv, n):
    """split state rows by the joint value of the key registers; yields (rows, key cand)"""
    comb = np.zeros(n, dtype=np.int64)
    for k in kns:
        comb = (comb << len(regs[k])) | rv(regs[k])
    order = np.argsort(comb, kind="stable")
    bounds = np.flatnonzero(np.diff(comb[order])) + 1
    for grp in np.split(order, bounds):
        kc = [("eq", regs[k], int(rv(regs[k])[grp[0]])) for k in kns]
        yield grp, (kc[0] if len(kc) == 1 else ("and",) + tuple(kc))


def mine(bits, regs, keys, max_set=4, counters=(), lin_keys=(), bit_keys=()):
    """Templates (all over guarded states):
    T1 constant latch bits;      T2 equal/complement latch-bit pairs;
    T3 domain of each register with <= 64 observed values;
    T4 for each key register K and value v: K=v -> R in S (|S| <= max_set) else K=v -> R <= max;
    T5 for each (key tuple, value) and counter pair (a, b): K=v -> a +- b == const;
    T6 for each key register K and value v: K=v -> latch bit constant, and K=v -> latch bit
       i == (or !=) latch bit j (first occurrence of each column class), for bits not
       globally constant."""
    L = bits.shape[1]
    cands = []
    col_const = []
    for i in range(L):
        u = np.unique(bits[:, i])
        if len(u) == 1:
            cands.append(("bit", i, int(u[0])))
            col_const.append(i)
    # T2: hash columns
    var_cols = [i for i in range(L) if i not in set(col_const)]
    seen = {}
    for i in var_cols:
        col = bits[:, i]
        key = col.tobytes()
        if key in seen:
            cands.append(("beq", seen[key], i, 0))
            continue
        nkey = (1 - col).tobytes()
        if nkey in seen:
            cands.append(("beq", seen[nkey], i, 1))
            continue
        seen[key] = i
    cache = {tuple(idxs): reg_values(bits, idxs) for idxs in regs.values()}
    rv = lambda idxs: cache[tuple(idxs)]
    multi = {n: idxs for n, idxs in regs.items() if 1 < len(idxs) <= 12}
    # T3
    for n, idxs in multi.items():
        u = np.unique(rv(idxs))
        if 1 < len(u) <= 64 and len(u) < (1 << len(idxs)):
            cands.append(("in", idxs, [int(x) for x in u]))
    # T4 (keys: register names or tuples of names; T4 adds upper and lower bounds)
    for kn in keys:
        kns = (kn,) if isinstance(kn, str) else tuple(kn)
        for grp, kc in _groups(kns, regs, rv, bits.shape[0]):
            for n, idxs in regs.items():
                if n in kns:
                    continue
                vals = rv(idxs)[grp]
                u = np.unique(vals)
                full = 1 << len(idxs)
                if len(u) >= full:
                    continue
                if len(u) <= max_set:
                    cands.append(("imp", kc, ("in", idxs, [int(x) for x in u])))
                elif len(idxs) > 1:
                    mx, mn = int(u.max()), int(u.min())
                    if mx < full - 1:
                        cands.append(("imp", kc, ("le", idxs, mx)))
                    if mn > 0:
                        cands.append(("imp", kc, ("not", ("le", idxs, mn - 1))))
    # T5
    for ktuple in lin_keys:
        kvs = [rv(regs[k]) for k in ktuple]
        comb = np.zeros(bits.shape[0], dtype=np.int64)
        for k, kv in zip(ktuple, kvs):
            comb = (comb << len(regs[k])) | kv
        order = np.argsort(comb, kind="stable")
        bounds = np.flatnonzero(np.diff(comb[order])) + 1
        for grp in np.split(order, bounds):
            if len(grp) < 2:
                continue
            kc = [("eq", regs[k], int(kv[grp[0]])) for k, kv in zip(ktuple, kvs)]
            kc = kc[0] if len(kc) == 1 else ("and",) + tuple(kc)
            for a, b in counters:
                ia, ib = regs[a], regs[b]
                w = max(len(ia), len(ib))
                if len(ia) != len(ib):
                    continue
                va, vb = rv(ia)[grp], rv(ib)[grp]
                for sign in (1, -1):
                    s = (va + sign * vb) & ((1 << w) - 1)
                    if np.all(s == s[0]) and len(np.unique(va)) > 1:
                        cands.append(("imp", kc, ("lin", ia, ib, sign, int(s[0]))))
    # T6
    const_set = set(col_const)
    for kn in bit_keys:
        kidx = regs[kn]
        kset = set(kidx)
        kv = rv(kidx)
        order = np.argsort(kv, kind="stable")
        bounds = np.flatnonzero(np.diff(kv[order])) + 1
        for grp in np.split(order, bounds):
            v = int(kv[grp[0]])
            kc = ("eq", kidx, v)
            sub = bits[grp]
            seen = {}
            for i in var_cols:
                if i in kset:
                    continue
                col = sub[:, i]
                if col.min() == col.max():
                    cands.append(("imp", kc, ("bit", i, int(col[0]))))
                    continue
                key = col.tobytes()
                if key in seen:
                    cands.append(("imp", kc, ("beq", seen[key], i, 0)))
                    continue
                nkey = (1 - col).tobytes()
                if nkey in seen:
                    cands.append(("imp", kc, ("beq", seen[nkey], i, 1)))
                    continue
                seen[key] = i
    return cands


# ---------------------------------------------------------------- CNF encoding

class Enc:
    """Tseitin encoding of k+1 AIG frames into one incremental solver."""

    def __init__(self, g, solver="cadical153"):
        self.g = g
        self.s = Solver(name=solver)
        self.nv = 1
        self.TRUE = self.new()
        self.s.add_clause([self.TRUE])
        self.frames = []  # per frame: dict aig var -> solver lit
        self.memo = {}

    def new(self):
        self.nv += 1
        return self.nv

    def AND(self, a, b):
        if a == -self.TRUE or b == -self.TRUE or a == -b:
            return -self.TRUE
        if a == self.TRUE:
            return b
        if b == self.TRUE or a == b:
            return a
        k = (min(a, b), max(a, b))
        if k in self.memo:
            return self.memo[k]
        x = self.new()
        self.s.add_clause([-x, a]); self.s.add_clause([-x, b]); self.s.add_clause([x, -a, -b])
        self.memo[k] = x
        return x

    def OR(self, a, b):
        return -self.AND(-a, -b)

    def ANDn(self, ls):
        r = self.TRUE
        for l in ls:
            r = self.AND(r, l)
        return r

    def ORn(self, ls):
        return -self.ANDn([-l for l in ls])

    def XOR(self, a, b):
        return self.OR(self.AND(a, -b), self.AND(-a, b))

    def lit(self, f, aiglit):
        v = self.frames[f][aiglit >> 1]
        return -v if aiglit & 1 else v

    def add_frame(self, init_zero=False):
        g = self.g
        m = {0: -self.TRUE}
        f = len(self.frames)
        for k in range(g.I):
            m[1 + k] = self.new()
        for k in range(g.L):
            if f == 0:
                m[1 + g.I + k] = -self.TRUE if init_zero else self.new()
            else:
                m[1 + g.I + k] = self.lit(f - 1, g.latch_next[k])
        self.frames.append(m)
        for lhs, r0, r1 in g.ands:
            a = -m[r0 >> 1] if r0 & 1 else m[r0 >> 1]
            b = -m[r1 >> 1] if r1 & 1 else m[r1 >> 1]
            m[lhs >> 1] = self.AND(a, b)
        return f

    def latch(self, f, k):
        return self.frames[f][1 + self.g.I + k]

    def bad(self, f):
        return self.ORn([self.lit(f, o) for o in self.g.outputs + self.g.bads])

    # candidate encodings
    def reg_eq(self, f, idxs, v):
        return self.ANDn([self.latch(f, i) if (v >> b) & 1 else -self.latch(f, i) for b, i in enumerate(idxs)])

    def reg_le(self, f, idxs, v):
        # unsigned x <= v, msb first: le = (x_b < v_b) | (x_b == v_b & le_rest)
        r = self.TRUE
        for b, i in enumerate(idxs):  # lsb first build
            x = self.latch(f, i)
            if (v >> b) & 1:
                r = self.OR(-x, r)  # x_b=0 -> less (true); x_b=1 -> rest
            else:
                r = self.AND(-x, r)
        return r

    def adder_eq(self, f, ia, ib, sign, v):
        xa = [self.latch(f, i) for i in ia]
        xb = [self.latch(f, i) for i in ib]
        carry = -self.TRUE
        if sign < 0:  # a - b = a + ~b + 1
            xb = [-x for x in xb]
            carry = self.TRUE
        out = []
        for a, b in zip(xa, xb):
            s = self.XOR(self.XOR(a, b), carry)
            carry = self.OR(self.AND(a, b), self.AND(carry, self.XOR(a, b)))
            out.append(s)
        return self.ANDn([o if (v >> k) & 1 else -o for k, o in enumerate(out)])

    def cand(self, f, c):
        t = c[0]
        if t == "bit":
            x = self.latch(f, c[1])
            return x if c[2] else -x
        if t == "beq":
            e = -self.XOR(self.latch(f, c[1]), self.latch(f, c[2]))
            return -e if c[3] else e
        if t == "eq":
            return self.reg_eq(f, c[1], c[2])
        if t == "in":
            return self.ORn([self.reg_eq(f, c[1], v) for v in c[2]])
        if t == "le":
            return self.reg_le(f, c[1], c[2])
        if t == "imp":
            return self.OR(-self.cand(f, c[1]), self.cand(f, c[2]))
        if t == "not":
            return -self.cand(f, c[1])
        if t == "and":
            return self.ANDn([self.cand(f, x) for x in c[1:]])
        if t == "lin":
            return self.adder_eq(f, c[1], c[2], c[3], c[4])
        raise ValueError(t)

    def guarded(self, f, c, guard):
        g = self.ANDn([-self.latch(f, i) for i in guard])
        return self.OR(-g, self.cand(f, c))


def base_filter(g, cands, guard, depth, log=print):
    """drop candidates violated in a state reachable from init within [depth] steps"""
    e = Enc(g)
    alive = set(range(len(cands)))
    for f in range(depth + 1):
        e.add_frame(init_zero=(f == 0))
        lits = {j: e.guarded(f, cands[j], guard) for j in alive}
        while True:
            sel = e.new()
            e.s.add_clause([-sel] + [-lits[j] for j in alive])
            if not e.s.solve(assumptions=[sel]):
                break
            m = e.s.get_model()
            mv = lambda l: (m[abs(l) - 1] > 0) == (l > 0)
            dead = [j for j in alive if not mv(lits[j])]
            alive -= set(dead)
            log("  base frame %d: dropped %d, alive %d" % (f, len(dead), len(alive)))
        # keep surviving candidates as facts in this frame for later frames' speed
        for j in alive:
            e.s.add_clause([lits[j]])
    return sorted(alive)


def houdini(g, cands, guard, k, alive, log=print, max_iter=100000, why=None, prop=True):
    """k-induction Houdini. Returns (alive, cti) where cti is a model in which only not-bad
    fails at the last frame (no candidate can be dropped), or None if alive is inductive.
    prop=False: not-bad is neither assumed nor checked; the result is k-inductive on its own.
    prop="assume": not-bad is assumed in the k hypothesis frames but not checked; the result S
    is k-inductive relative to not-bad (S holds up to the first bad), the seed for IC3."""
    e = Enc(g)
    for _ in range(k + 1):
        e.add_frame()
    alive = set(alive)
    lits = [{j: e.guarded(f, cands[j], guard) for j in alive} for f in range(k + 1)]
    nb = [-e.bad(f) for f in range(k + 1)]
    if prop:
        for f in range(k):
            e.s.add_clause([nb[f]])
    act = {}
    for j in alive:
        a = e.new()
        act[j] = a
        for f in range(k):
            e.s.add_clause([-a, lits[f][j]])
    it = 0
    while it < max_iter:
        it += 1
        sel = e.new()
        e.s.add_clause([-sel] + ([-nb[k]] if prop is True else []) + [-lits[k][j] for j in alive])
        ok = e.s.solve(assumptions=[sel] + [act[j] for j in alive])
        if not ok:
            log("  houdini k=%d: inductive, %d candidates, %d iterations" % (k, len(alive), it))
            return sorted(alive), None
        m = e.s.get_model()
        mv = lambda l: (m[abs(l) - 1] > 0) == (l > 0)
        dead = [j for j in alive if not mv(lits[k][j])]
        if why is not None and dead:
            # provenance: iteration -> (dropped candidates, CTI trajectory incl. inputs)
            traj = [[mv(e.latch(f, i)) for i in range(g.L)] for f in range(k + 1)]
            ins = [[mv(e.frames[f][1 + i]) for i in range(g.I)] for f in range(k + 1)]
            why.append((dead, traj, ins))
        if not dead:
            log("  houdini k=%d: property CTI (no candidate to drop), %d alive" % (k, len(alive)))
            cti = [[mv(e.latch(f, i)) for i in range(g.L)] for f in range(k + 1)]
            return sorted(alive), cti
        alive -= set(dead)
        if it % 20 == 1 or len(dead) > 50:
            log("  houdini k=%d it %d: dropped %d, alive %d" % (k, it, len(dead), len(alive)))
    raise RuntimeError("houdini iteration limit")
