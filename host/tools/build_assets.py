#!/usr/bin/env python3
"""Build host/assets/ from the toolchain (doc/host.md section 4); --check compares instead.

  library.json            pemu_cc json
  programs/<name>.json    pemu_asm asm -f json of the shipped firmware (pemu_asm shipped) and of
                          toolchain/examples/*.s (as ex_<name>) and flex_v2/firmware/*.s (as flex_<name>)
  windows/<name>.json     pemu_cc retune for the listed variants

Needs `dune build ./toolchain` first. Exit 1 on --check if anything differs.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "_build" / "default" / "toolchain" / "bin"
OUT = ROOT / "host" / "assets"
RETUNE = {"uart_tx_d6": (0, "uart_tx:d=6,pin=0")}


def run(*args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True).stdout


def build(out):
    (out / "programs").mkdir(parents=True, exist_ok=True)
    (out / "windows").mkdir(parents=True, exist_ok=True)
    (out / "library.json").write_text(run(BIN / "pemu_cc.exe", "json"))
    with tempfile.TemporaryDirectory() as t:
        run(BIN / "pemu_asm.exe", "shipped", t)
        srcs = [(p.stem, p) for p in sorted(Path(t).glob("*.s"))]
        srcs += [("ex_" + p.stem, p) for p in sorted((ROOT / "toolchain" / "examples").glob("*.s"))]
        srcs += [("flex_" + p.stem, p) for p in sorted((ROOT / "flex_v2" / "firmware").glob("*.s"))]
        for name, p in srcs:
            run(BIN / "pemu_asm.exe", "asm", p, "-f", "json", "-o", out / "programs" / f"{name}.json", "--werror")
    for name, (rom, variant) in RETUNE.items():
        txt = run(BIN / "pemu_cc.exe", "retune", rom, variant)
        w = json.loads(txt.splitlines()[0].split(" ", 1)[1])
        (out / "windows" / f"{name}.json").write_text(json.dumps({"rom": rom, "variant": variant, "windows": w}) + "\n")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        with tempfile.TemporaryDirectory() as t:
            build(Path(t))
            new = {p.relative_to(t): p.read_text() for p in Path(t).rglob("*.json")}
            old = {p.relative_to(OUT): p.read_text() for p in OUT.rglob("*.json")}
            diff = sorted(str(k) for k in set(new) | set(old) if new.get(k) != old.get(k))
            print("host/assets: %d files, %s" % (len(new), "up to date" if not diff else "DIFFER: " + ", ".join(diff)))
            sys.exit(1 if diff else 0)
    build(OUT)
    print("host/assets: %d files written" % len(list(OUT.rglob("*.json"))))


if __name__ == "__main__":
    main()
