# v2 increments (plan v5 step 7)

Rule (plan): one increment at a time. Each gets RTL, verification, local synthesis and a bounded CI probe.
It is accepted only if CI stays green and the slow-corner timing closes at the chosen clock.
Work happens on branch `v2-inc1-i2c`; `v2-6x4` stays the frozen minimum until it is tagged.

## T. Timing option: registered firing record (`Mon_engine ~verdict_pipe`, default off)

The verdict block records a registered copy of each lane's firing (fire, role, code, unit, stamp),
one cycle later. The aim is to cut the unit-step cone off the verdict registers, which were the worst
slow-corner endpoints of round-1 CI (log/ci_results_v2.md section 2). blame_to_lane stays on the
unregistered firing, so the C3 blame-arrival argument (log/proofs_v2.md section 7) is unchanged.
Verdict pins and registers see a firing one cycle later, and stamps are unchanged.

- The default build is unchanged: v2min with the option off emits byte-identical Verilog (sha1 prefix c89129a596831b5c).
- Cost: +24 flops on v2min and +26 on v2inc1 (fire, role, code, unit per lane). The registered stamp merges
  with the existing step-latched stamp. Area +2,157 um2 (v2min) and +1,405 um2 (v2inc1), Yosys typ.
- Tests with the option on: the cross-lane verdict scenarios B, C, D, G (`test_c3_two.ml`) and the I2C
  scenarios (`test_inc1.ml`). All match Psim, with identical stamps, codes, lane bits and blame routing.
- Still to do before acceptance: top_props re-run on a pipelined top (no verdict property is expected
  to depend on it), regenerated gate-level vectors (uo[1]/uo[2] move by one cycle), spec text
  (monitor_isa_v1.md section 6: in-flight window and pin latency).

## 1. I2C controller, Fm and Sm (ROM packages 4 and 5)

- `Rom_lib.v2_inc1_with_p`: Fm P = 8 (step 0.273 us, SCL 367 kHz; P = 7 would give 412 kHz, over the
  Fm limit), Sm P = 32 (step 1 us, as in v1). The contract encodes only UM10204 minimum times, so the
  longer Fm step keeps it valid. Admissible at 5 slots (`test_rom_lib_v2.ml`). Both packages have 3 units.
- Chip level (`test_inc1.ml`, v2 top RTL with library v2_inc1 vs Psim, I2C target peer on the wired-AND
  bus): Fm clean, clock stretch 200, NACK of write byte 1, target data delay 30/50/70, and Sm clean and
  stretch 600. All are identical in the monitor-input stream, pins, verdict and pushes. Status bytes are
  00, or 02 on the NACK. Read data C3 5A. Data delay 70 (beyond the 54-cycle low phase) is blamed 0x77,
  identically on chip and Psim. U holds in every scenario.
- A2: the v1 results are bounded (bmc3 77 / 76 frames) and are carried as bounded under C1-C4.

Local synthesis (Yosys; slow = slow corner, no wires):

| build | std cells typ (um2) | util. | flops | depth, map_v1m.sh slow (sized) | depth, reduced script (no sizing) |
|---|---|---|---|---|---|
| v2min | 217,934 | 25.8 % | 1,933 | 9.10 ns | 18.24 ns |
| v2min + T | 220,091 | 26.0 % | 1,957 | 8.35 ns | 15.06 ns |
| v2inc1 | 251,429 | 29.7 % | 2,173 | 9.85 ns | 21.75 ns |
| v2inc1 + T | 252,834 | 29.9 % | 2,199 | ABC failure (see below) | 21.14 ns |

Utilisation is std cells / (6x4 core - 2 macros). The step-2 probe had zero GRT overflow up to 29.2 %.
The ABC script of `flow/map/map_v1m.sh slow` fails deterministically on v2inc1 + T ("node has no fanout"
after buffer/upsize). The reduced script `strash; dch; map -D; topo; stime -p` was therefore run on all four for a like-for-like comparison.

Findings:
1. T removes the verdict path as the critical path on v2min (-17 %, reduced script).
2. I2C adds about 3 ns to the unit-step cone itself (reduced script, v2inc1 + T vs v2min). T then saves
   only 3 %, so the new critical path is not in the verdict block. It is most likely the wider ROM fetch
   mux and counters; the path has not been traced.
3. Estimate, not measured: with round-1's routed-slow / reduced-script ratio (27.6 / 18.24 = 1.51),
   v2inc1 + T would need about 32 ns at the slow corner, more than 30.30 ns at 33 MHz. Round-2 CI (33 MHz)
   calibrates this ratio. Then decide between (a) a lower clock for increments, (b) shortening the
   ROM fetch path (a pipelined fetch changes Mon_lane slot timing and needs a new R1), or
   (c) a CI probe of v2inc1 + T to measure directly.
