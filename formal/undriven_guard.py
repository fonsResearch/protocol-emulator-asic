#!/usr/bin/env python3
"""Exit 1 (and print offending names) if the Yosys log reports an undriven bit that is not a
top-level input port of the harness. usage: undriven_guard.py <top> <yosys.log> <harness.v>"""
import re, sys
top, log, v = sys.argv[1:4]
ports = set(re.findall(r'^\s*input\s+(?:\[\d+:0\]\s+)?(\w+)\s*;', open(v).read(), re.M))
names = set(re.findall(r'undriven bit ' + re.escape(top) + r'\.\\(\S+)', open(log).read()))
bad = sorted(n for n in names if n not in ports)
if bad:
    print(','.join(bad)); sys.exit(1)
