"""Compare two demo result sets (default results/rtl vs results/gl): every scenario record
(verdict codes and stamps, pushed data, peer-side logs and fault instants) must be identical.
Also prints the per-scenario table used in log/demo_v2.md.
usage: python3 compare_runs.py [dirA dirB]"""
import json
import sys
from pathlib import Path

a = Path(sys.argv[1] if len(sys.argv) > 1 else "results/rtl")
b = Path(sys.argv[2] if len(sys.argv) > 2 else "results/gl")
OFFSET = 4  # STAMP_OFFSET in test_demo.py
RELEASE = 10

fault_key = {
    "uart_rx_fast_peer": lambda d: d["frame0"][0],
    "spi_ctl_slow_target": lambda d: d["miso_changes"][0],
    "spi_tgt_early_cs": lambda d: d["fault_cycle"],
    "i2c_ctl_slow_target": lambda d: d["target_high_changes"][0],
    "i2c_ctl_late_ack": lambda d: d["target_high_changes"][0],
    "i2c_tgt_short_start_hold": lambda d: d["starts"][0] + 60,
}

diffs = 0
print("| scenario | verdict | stamp | board time - fault instant (cycles) | RTL = GL |")
print("|---|---|---|---|---|")
for fa in sorted(a.glob("*.json")):
    fb = b / fa.name
    da = json.loads(fa.read_text())
    db = json.loads(fb.read_text()) if fb.exists() else None
    same = da == db
    diffs += not same
    n = fa.stem
    v = da.get("verdict") or da.get("window_verdict")
    if v["fail"]:
        verdict, stamp = "fail %02X lane %d" % (v["fail_code"], v["fail_lane"]), v["fail_time"]
    elif v["blame"]:
        verdict, stamp = "blame %02X lane %d" % (v["blame_code"], v["blame_lane"]), v["blame_time"]
    else:
        verdict, stamp = "clean", None
    lat = ""
    if n in fault_key and v["blame"]:
        lat = str(RELEASE + v["blame_time"] + OFFSET - fault_key[n](da))
    print(f"| {n} | {verdict} | {'' if stamp is None else stamp} | {lat} | {'yes' if same else 'NO' if db else 'missing'} |")
print(f"\n{diffs} differing or missing records")
sys.exit(1 if diffs else 0)
