"""AIGER (binary) reader, yosys map reader and a generated bit-parallel C simulator.

Part of the I2C invariant-mining flow (formal/inv/README.md). Nothing in this file is
trusted by the final proof: the strengthened model is proved by ABC and checked by
Certifaiger, and formal/inv/check_extension.py checks that it extends the original model.
"""
import os
import subprocess
import sys
from collections import defaultdict


class Aig:
    def __init__(self, path):
        with open(path, "rb") as f:
            data = f.read()
        nl = data.index(b"\n")
        hdr = data[:nl].decode().split()
        if hdr[0] != "aig":
            raise ValueError("binary AIGER expected")
        M, I, L, O, A = map(int, hdr[1:6])
        extra = list(map(int, hdr[6:])) + [0, 0, 0, 0]
        B = extra[0]
        if any(extra[1:4]):
            raise ValueError("C/J/F sections not supported: %s" % hdr)
        self.M, self.I, self.L, self.O, self.A, self.B = M, I, L, O, A, B
        self.header = hdr
        pos = nl + 1
        self.body_start = pos
        lines = []
        for _ in range(L + O + B):
            e = data.index(b"\n", pos)
            lines.append(data[pos:e].decode())
            pos = e + 1
        self.latch_next = []
        for k in range(L):
            parts = lines[k].split()
            nxt = int(parts[0])
            init = int(parts[1]) if len(parts) > 1 else 0
            if init != 0:
                raise ValueError("latch %d has non-zero init %d" % (k, init))
            self.latch_next.append(nxt)
        self.outputs = [int(lines[L + k]) for k in range(O)]
        self.bads = [int(lines[L + O + k]) for k in range(B)]
        self.ands_start = pos
        self.ands = []
        lhs = 2 * (I + L + 1)
        for _ in range(A):
            d0, pos = _delta(data, pos)
            d1, pos = _delta(data, pos)
            r0 = lhs - d0
            r1 = r0 - d1
            self.ands.append((lhs, r0, r1))
            lhs += 2
        self.tail = data[pos:]

    def input_lit(self, k):
        return 2 * (1 + k)

    def latch_lit(self, k):
        return 2 * (1 + self.I + k)


def _delta(data, pos):
    x = 0
    i = 0
    while True:
        ch = data[pos]
        pos += 1
        x |= (ch & 0x7F) << (7 * i)
        if ch & 0x80 == 0:
            return x, pos
        i += 1


def read_map(path):
    """yosys write_aiger -map: input/latch/output lines (kind idx bit name)."""
    inputs, latches, outputs = {}, {}, {}
    for line in open(path):
        p = line.split()
        if len(p) != 4:
            continue
        kind, idx, bit, name = p[0], int(p[1]), int(p[2]), p[3]
        if kind == "input":
            inputs[idx] = (name, bit)
        elif kind == "latch":
            # several aliases may name one latch; keep the first user name, else the first
            prev = latches.get(idx)
            if prev is None or (prev[0].startswith("_") and not name.startswith("_")):
                latches[idx] = (name, bit)
        elif kind == "output":
            outputs[idx] = (name, bit)
    return inputs, latches, outputs


def registers(latches):
    """register name -> list of latch indices ordered by bit (lsb first)."""
    regs = defaultdict(dict)
    for idx, (name, bit) in latches.items():
        regs[name][bit] = idx
    out = {}
    for name, bits in regs.items():
        w = max(bits) + 1
        if sorted(bits) != list(range(w)):
            # partially removed register: keep present bits as separate 1-bit registers
            for b, idx in bits.items():
                out["%s[%d]" % (name, b)] = [idx]
        else:
            out[name] = [bits[b] for b in range(w)]
    return out


TRACE_FIELDS = {  # input name -> (byte in record, bit or None for a whole byte)
    "rst_sync_n": (0, 0), "run": (0, 1), "tick": (0, 2), "tx_push": (0, 3), "rx_pop": (0, 4),
    "clear_fault": (0, 5), "uio_in": (1, None), "tx_wdata": (2, None), "clock": None,
}


def gen_sim_c(aig, inputs, guard_latches, path):
    """C simulator: replays inv_traces.exe records on the AIG, 64 traces per machine word.
    Writes every distinct latch state in which all [guard_latches] are 0 (no blame so far,
    environment ok) and counts cycles where the AIG output differs from the recorded bad."""
    W = (aig.L + 63) // 64
    o = []
    o.append("#include <stdio.h>\n#include <stdlib.h>\n#include <stdint.h>\n#include <string.h>")
    o.append("#define NL %d\n#define NW %d\n#define NV %d" % (aig.L, W, aig.M + 1))
    o.append("static uint64_t v[NV];")
    o.append("#define LIT(l) (v[(l)>>1] ^ (((l)&1) ? ~0ULL : 0ULL))")
    o.append("static uint64_t hs_mask; static uint64_t *hs; static uint8_t *hs_used; static long n_states=0, hs_cap;")
    o.append("""
static uint64_t hsh(const uint64_t *s){uint64_t h=1469598103934665603ULL;for(int i=0;i<NW;i++){h^=s[i];h*=1099511628211ULL;h^=h>>29;}return h;}
static FILE *outf;
static void insert(const uint64_t *s){
  uint64_t h=hsh(s)&hs_mask;
  while(hs_used[h]){ if(!memcmp(hs+h*NW,s,8*NW)) return; h=(h+1)&hs_mask; }
  if(n_states*4 >= hs_cap*3){ static int warned=0; if(!warned){fprintf(stderr,"state table full\\n");warned=1;} return; }
  hs_used[h]=1; memcpy(hs+h*NW,s,8*NW); n_states++; fwrite(s,8,NW,outf);
}""")
    o.append("static void step_comb(void){")
    for lhs, r0, r1 in aig.ands:
        o.append("v[%d]=LIT(%d)&LIT(%d);" % (lhs >> 1, r0, r1))
    o.append("}")
    o.append("int main(int argc,char**argv){")
    o.append(' FILE*f=fopen(argv[1],"rb"); fseek(f,0,SEEK_END); long sz=ftell(f); fseek(f,0,SEEK_SET);')
    o.append(" uint8_t*buf=malloc(sz); if(fread(buf,1,sz,f)!=(size_t)sz) return 2; fclose(f);")
    o.append(' outf=fopen(argv[2],"wb"); int lg=atoi(argv[3]); hs_cap=1L<<lg; hs_mask=hs_cap-1;')
    o.append(" hs=calloc(hs_cap*NW,8); hs_used=calloc(hs_cap,1);")
    o.append(" long off=0, ntr=0; long *toff=malloc(sizeof(long)*100000); int *tlen=malloc(sizeof(int)*100000);")
    o.append(" while(off<sz){ int n=buf[off]|(buf[off+1]<<8)|(buf[off+2]<<16)|(buf[off+3]<<24); toff[ntr]=off+4; tlen[ntr]=n; ntr++; off+=4+3L*n; }")
    o.append(" long mism=0, cyc=0, guarded=0, bads=0;")
    o.append(" for(long b0=0;b0<ntr;b0+=64){ int nb=(ntr-b0<64)?(int)(ntr-b0):64; int n=tlen[b0];")
    o.append("  for(int j=1;j<nb;j++) if(tlen[b0+j]!=n){fprintf(stderr,\"unequal trace lengths\\n\");return 3;}")
    o.append("  memset(v,0,sizeof v); uint64_t lanes=(nb==64)?~0ULL:((1ULL<<nb)-1);")
    o.append("  for(int c=0;c<n;c++){")
    for k in range(aig.I):
        name, bit = inputs[k]
        fld = TRACE_FIELDS.get(name, "missing")
        if fld == "missing":
            raise ValueError("input %s not in trace format" % name)
        lit = aig.input_lit(k)
        if fld is None:
            o.append("   v[%d]=0;" % (lit >> 1))
            continue
        byte, b = fld
        sh = bit if b is None else b
        o.append("   {uint64_t w=0; for(int j=0;j<nb;j++) w|=(uint64_t)((buf[toff[b0+j]+3L*c+%d]>>%d)&1)<<j; v[%d]=w;}" % (byte, sh, lit >> 1))
    o.append("   step_comb();")
    o.append("   uint64_t outw=0;")
    for ol in aig.outputs + aig.bads:
        o.append("   outw|=LIT(%d);" % ol)
    o.append("   {uint64_t w=0; for(int j=0;j<nb;j++) w|=(uint64_t)((buf[toff[b0+j]+3L*c]>>6)&1)<<j; mism+=__builtin_popcountll((w^outw)&lanes); bads+=__builtin_popcountll(outw&lanes);}")
    # guard: all guard latches 0 (before latch update = current state)
    g = " & ".join("~LIT(%d)" % aig.latch_lit(k) for k in guard_latches) or "~0ULL"
    o.append("   uint64_t gw=(%s)&lanes;" % g)
    o.append("   for(int j=0;j<nb;j++) if((gw>>j)&1){ uint64_t s[NW]; memset(s,0,sizeof s);")
    o.append("     for(int k=0;k<NL;k++) s[k>>6]|=((v[%d+k]>>j)&1)<<(k&63); insert(s); guarded++; }" % (1 + aig.I))
    o.append("   uint64_t nx[NL];")
    for k, nl in enumerate(aig.latch_next):
        o.append("   nx[%d]=LIT(%d);" % (k, nl))
    o.append("   memcpy(&v[%d],nx,sizeof nx);" % (1 + aig.I))
    o.append("   cyc+=nb; }")
    o.append(" }")
    o.append(' printf("traces %ld cycles %ld guarded %ld distinct %ld bad %ld bad_mismatch %ld\\n",ntr,cyc,guarded,n_states,bads,mism);')
    o.append(" fclose(outf); return mism?1:0; }")
    with open(path, "w") as f:
        f.write("\n".join(o) + "\n")


def build_sim(aig_path, map_path, workdir):
    aig = Aig(aig_path)
    inputs, latches, _ = read_map(map_path)
    regs = registers(latches)
    guard = regs["h_blame_seen"] + regs["h_env_bad"]
    os.makedirs(workdir, exist_ok=True)
    c = os.path.join(workdir, "aigsim.c")
    exe = os.path.join(workdir, "aigsim")
    gen_sim_c(aig, inputs, guard, c)
    subprocess.run(["cc", "-O1", "-o", exe, c], check=True)
    return exe


if __name__ == "__main__":
    print(build_sim(sys.argv[1], sys.argv[2], sys.argv[3]))
