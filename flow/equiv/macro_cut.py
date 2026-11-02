#!/usr/bin/env python3
"""SRAM-macro cut for the v1m equivalence check (flow/equiv/run_equiv_v1m.sh).

Every RM_IHPSG13_1P_256x16_c2_bm_bist instance is removed. Its data output becomes a new input port
`mdout_l<k>` (16 bits) of the module that held it. All other pins except A_CLK are concatenated in
a fixed order onto a new output port `mpin_l<k>` (89 bits). The miter drives `mdout_l<k>` of both
designs from one shared free input and compares `mpin_l<k>` along with the chip outputs. Equivalence
then holds for every SRAM output sequence, which covers the real macro, provided the macro inputs
(compared) agree.

usage:
  macro_cut.py rtl  <core.v> <wrapper.v> <out_core.v> <out_wrapper.v>
  macro_cut.py gate <netlist.v> <out.v> [--flip-addr0]   (netlist: flat top module)
"""
import re
import sys

MACRO = "RM_IHPSG13_1P_256x16_c2_bm_bist"
PINS = [  # (name, width), compared in this order (MSB first in the concatenation)
    ("A_MEN", 1), ("A_WEN", 1), ("A_REN", 1), ("A_ADDR", 8), ("A_DIN", 16), ("A_DLY", 1), ("A_BM", 16),
    ("A_BIST_CLK", 1), ("A_BIST_EN", 1), ("A_BIST_MEN", 1), ("A_BIST_WEN", 1), ("A_BIST_REN", 1),
    ("A_BIST_ADDR", 8), ("A_BIST_DIN", 16), ("A_BIST_BM", 16),
]
NPIN = sum(w for _, w in PINS)


def parse_pins(body):
    pins = {}
    i = 0
    while True:
        m = re.compile(r"\.(\w+)\s*\(").search(body, i)
        if not m:
            return pins
        j = m.end()
        depth = 1
        k = j
        while depth:
            c = body[k]
            depth += c == "("
            depth -= c == ")"
            k += 1
        pins[m.group(1)] = body[j:k - 1].strip()
        i = k


def cut(text):
    """returns (new text, list of lane indices cut)"""
    lanes = []
    pat = re.compile(MACRO + r"\s+(\\?\S+)\s*\((.*?)\)\s*;", re.S)

    def rep(m):
        name = m.group(1)
        lane = int(re.search(r"u_imem_l(\d)", name).group(1))
        pins = parse_pins(m.group(2))
        missing = [p for p, _ in PINS + [("A_DOUT", 16)] if p not in pins]
        if missing:
            raise SystemExit(f"{name}: missing pins {missing}")
        lanes.append(lane)
        # a trailing space terminates escaped identifiers (\\core._12789 )
        cat = ", ".join(pins[p] + " " for p, _ in PINS)
        return (f"assign {pins['A_DOUT']} = mdout_l{lane};\n"
                f"  assign mpin_l{lane} = {{{cat}}};\n")

    new = pat.sub(rep, text)
    return new, sorted(lanes)


def add_ports_nonansi(text, module, lanes):
    m = re.search(r"module\s+" + re.escape(module) + r"\s*\(", text)
    if not m:
        raise SystemExit(f"module {module} not found")
    close = text.index(");", m.end())
    names = "".join(f", mdout_l{l}, mpin_l{l}" for l in lanes)
    decl = "".join(f"\n  input [15:0] mdout_l{l};\n  output [{NPIN - 1}:0] mpin_l{l};" for l in lanes)
    return text[:close] + names + ");" + decl + text[close + 2:]


def main():
    mode = sys.argv[1]
    if mode == "gate":
        src, out = sys.argv[2], sys.argv[3]
        t = open(src).read()
        t, lanes = cut(t)
        top = re.search(r"module\s+(\S+)\s*\(", t).group(1)
        t = add_ports_nonansi(t, top, lanes)
        if "--flip-addr0" in sys.argv:  # negative control: invert one SRAM address bit
            t, n = re.subn(r"(assign mpin_l0 = \{[^}]*?\{)(\s*)([^,}]+)", r"\1\2~\3", t, count=1)
            if n != 1:
                raise SystemExit("flip-addr0 edit did not apply")
        open(out, "w").write(t)
    else:
        core, wrap, out_core, out_wrap = sys.argv[2:6]
        t = open(core).read()
        t, lanes = cut(t)
        t = add_ports_nonansi(t, "pemu_core_v1m", lanes)
        open(out_core, "w").write(t)
        w = open(wrap).read()
        ports = "".join(f"\n    input  wire [15:0] mdout_l{l},\n    output wire [{NPIN - 1}:0] mpin_l{l}," for l in lanes)
        w = re.sub(r"(module\s+tt_um_dean_protocol_emulator\s*\()", r"\1" + ports, w, count=1)
        conn = "".join(f"\n      .mdout_l{l}(mdout_l{l}),\n      .mpin_l{l}(mpin_l{l})," for l in lanes)
        w = re.sub(r"(pemu_core_v1m\s+core\s*\()", r"\1" + conn, w, count=1)
        open(out_wrap, "w").write(w)
    print(f"{mode}: cut lanes {lanes}, {NPIN} compared macro-input bits per macro")


if __name__ == "__main__":
    main()
