#!/usr/bin/env python3
"""Merge paired free-init AIGER inputs: every use of the init input of free_rtl_imem_<k>[b]
is replaced by the init input of free_spec_imem_<k>[b]. The result is the original model
restricted to runs whose two instruction memories start equal (ASCII AIGER in, binary AIGER out).
usage: merge_init.py in.aag in.map out.aag"""
import sys, re
aag, mapf, out = sys.argv[1:4]
L = open(aag).read().split('\n')
hdr = list(map(int, L[0].split()[1:]))
M, I, Lt, O, A = hdr[:5]
B, C, J, F = (hdr[5:] + [0, 0, 0, 0])[:4]
assert J == 0 and F == 0, 'justice/fairness not supported'
inputs = [int(x) for x in L[1:1 + I]]
init_of = {}
for l in open(mapf):
    p = l.split()
    if p[0] == 'init':
        init_of[(p[3], int(p[2]))] = int(p[1])      # (name, bit) -> input index
sub = {}
for (n, b), idx in init_of.items():
    m = re.fullmatch(r'free_rtl_imem_(\d+)', n)
    if m:
        s = init_of[(f'free_spec_imem_{m.group(1)}', b)]
        sub[inputs[idx]] = inputs[s]
def r(lit):
    base, neg = lit & ~1, lit & 1
    return (sub.get(base, base)) | neg
k = 1 + I
latches = []
for j in range(Lt):
    p = L[k + j].split(); p[1] = str(r(int(p[1]))); latches.append(' '.join(p))
k += Lt
singles = [str(r(int(L[k + j]))) for j in range(O + B + C)]
k += O + B + C
ands = []
for j in range(A):
    a, b, c = map(int, L[k + j].split()); ands.append(f'{a} {r(b)} {r(c)}')
# binary AIGER output (ABC reads binary only). Requires the canonical literal order that the
# yosys writer uses: inputs 2..2I, latches 2(I+1)..2(I+L), AND lhs 2(I+L+1).. consecutive.
assert inputs == [2 * (j + 1) for j in range(I)], 'non-canonical input order'
for j, l in enumerate(latches):
    assert int(l.split()[0]) == 2 * (I + j + 1), 'non-canonical latch order'
def enc(x):
    b = bytearray()
    while x & ~0x7f:
        b.append((x & 0x7f) | 0x80); x >>= 7
    b.append(x); return bytes(b)
with open(out, 'wb') as f:
    f.write((' '.join(['aig'] + [str(x) for x in hdr]) + '\n').encode())
    for l in latches:
        f.write((' '.join(l.split()[1:]) + '\n').encode())
    for x in singles:
        f.write((x + '\n').encode())
    for j, a in enumerate(ands):
        lhs, r0, r1 = map(int, a.split())
        assert lhs == 2 * (I + Lt + j + 1), 'non-canonical AND order'
        if r0 < r1: r0, r1 = r1, r0
        assert lhs > r0 >= r1
        f.write(enc(lhs - r0) + enc(r0 - r1))
assert len(sub) == 1024, len(sub)
print(f'merged {len(sub)} init inputs')
