# Verification write-up (v2 tape-out candidate)

Design: `tt_um_dean_protocol_emulator`, Tiny Tapeout IHP SG13CMOS5L, 6x4 tiles, 30 MHz. Branch
v2-inc5-usb; design sources frozen at core commit d9d97d2; signed-off netlist from CI run
42426292730 (`final/nl`, sha256 b450fe7c...abb0). Architecture: `doc/architecture_v2.md`; ISA:
`doc/isa/isa_v1.md`; contract language: `doc/contracts/language_v1.md`; monitor ISA:
`doc/contracts/monitor_isa_v1.md`.

Every result below has a source log. Status words are used strictly:

| word | meaning |
|---|---|
| **proved** | unbounded model-checking proof (ABC dprove/PDR or k-induction) with a replayed negative control |
| **bounded** | bounded model checking, co-simulation and checkpoint BMC; no unbounded proof |
| **tested** | simulation evidence only (directed, randomised or differential) |
| **argued** | a written argument over proved or tested parts, not machine-checked |

## 1. What the chip claims

The chip runs protocol firmware on two timed lanes (ISA v1). Beside the lanes, a monitor engine
runs a contract for each enabled package: compiled watchers that check the pins and the host
streams every lane step. Each check has a role:

- **fail**: the chip broke its guarantee. A fail check may only read chip-driven observables
  (rule WF1).
- **blame**: the environment broke an assumption. A blame check may only read environment-driven
  observables (rule WF2).

The verdict block records the first fail and the first blame per lane, with code, unit and step
stamp, readable by the host (`doc/interface_v1.md`).

**Theorem U (per shipped package).** For every input sequence: if the chip records a fail with
stamp s_f, it has recorded a blame with stamp s_b <= s_f. In words, the chip never reports that it
broke the protocol unless the environment broke it first. The environment's behaviour is not a
hypothesis: it is checked in silicon by the blame checks.

**Side obligations**, because U alone is satisfied by a contract that blames everything:
- **N1, non-vacuity:** a run exists in which the package does real work (a push, a pop) with no
  fail and no blame (formal cover, replayed).
- **Witness obligation:** every check of every shipped contract can fire as the first verdict while
  the assumptions held until then (section 4). There are no dead checks.
- **Faithfulness** (the contract says what the standard says) cannot be proved. It is measured by
  independent oracles and contract mutation (section 5) and stated as a limit (section 8).

## 2. Proof chain

```
standard / datasheet ---------------- contract (Lang) -- compile --> monitor program (ROM)
                                            |
lane spec (Lane_circuit) || monitor spec (Mon_spec running the program), free environment
      |  A2: U and N1 by model checking, per package (section 3)
      v
A1:  lane RTL == lane spec            (all pins, every cycle, any program)        proved
R1:  monitor RTL == monitor spec      (every firing, unit, role, code, cycle)    proved
C3:  the top composes lane and monitor as the A2 harness does                    tested + argued
Lemma S: recorded first verdicts are the least stamps                            argued
      v
E4/E5: signed-off netlist == RTL      (sequential equivalence, liberty cells)    proved
      v
U and N1 hold on the netlist, under the physical assumptions PH1-PH8 (section 7)
```

| link | method | result | source |
|---|---|---|---|
| A1, lane RTL vs lane spec | ABC proofs per obligation (fetch, datapath, independence), v1; lane sources byte-identical in v2 | proved (carried: `git diff` empty for lane_rtl, prescaler16, sram256, spec_v1, a1_lane) | log/proofs_v1.md, log/proofs_v2.md 6, 8 |
| R1, pipelined 5-slot monitor lane vs Mon_spec | k-induction (`ENGINE=ind`), claim: unit j fires in cycle t + j + 1 iff Mon_spec fires in step t, same role and code | proved: r1v2p_s5_u0..u4 and u4_t5 (ticks 5 apart) PASS, 2-3 s each; negatives u4_t4_neg (depth 6) and u3_smask_neg (depth 5) FAIL with replay | log/proofs_v2.md 9 |
| top properties | dprove | proved: load gate, OWN disjointness, lane pin gate, run-after-reset (k3, k33); 4 negatives FAIL with replay | log/proofs_v2.md 6 |
| C3, composition | top RTL vs Psim (lane model + interpreter + compiled-program model) cycle by cycle: 9 directed scenarios, host-clear window sweep, 16 randomised environments, both lanes (7 scenarios), reset mid-run; shipped configuration re-checked per increment | tested: monitor inputs, pads, pins, verdict codes and stamps, pushes identical; the only divergence is the predicted one, a host clear 1..j+1 cycles after a blame of unit j, which is after the first blame and so leaves U unaffected | log/proofs_v2.md 7.1-7.4, 10 |
| C3 wiring lemma | the engine's lane view is built literally from the lemma's expressions in `Top_v1`; netlist wiring covered by E4/E5 | argued | log/proofs_v2.md 7.3 |
| Lemma S, stamp order | R1 + admission (P >= slots) + the verdict RTL: firings are recorded in nondecreasing stamp order | argued; every differential run agrees on stamps | log/proofs_v2.md 7.5 |
| COMBDLY post-process | Yosys equiv_simple + equiv_induct, Hardcaml Verilog vs fixed Verilog | proved | log/increments_v2.md 5 |
| E4/E5, netlist vs RTL | Yosys equiv_induct on the signed-off netlist with a per-build name map; controls N1, N4, N5 | proved: 2,748 / 2,748 pairs (E5 278 s, E4 257 s); all 2,456 gate flops paired; N1 0 proven, N4 19 unproven, N5 exactly mon_now[5] unproven | log/increments_v2.md 5.1 |
| sign-off | TT LibreLane flow, precheck, gate-level test | slow-corner setup +5.827 ns at 30 MHz, hold +0.075 ns, DRC/LVS/antenna 0, precheck and gl_test pass, 48.56 % utilisation | log/increments_v2.md 5.1 |

## 3. Per-package results (A2, spec level, free ticks: every prescaler setting)

| ROM | package | P at 30 MHz | U | N1 and negatives | assumptions beyond the contract |
|---|---|---|---|---|---|
| 0 | uart_tx d4 | 64 | proved (9 s) | N1 cover; 1 negative | none |
| 1 | uart_rx d8 m2 | 32 | proved (681 s) | N1; 2 negatives (late sampling, contract without assumption) | RX FIFO never full |
| 2 | spi_ctl m0 h2 | 7 | proved (65 s) | N1; 1 negative | RX never full |
| 3 | spi_tgt m0 h3 g6 | 7 | proved (898 s) | N1; 2 negatives | RX never full; a TX byte is ready for every frame |
| 4 | i2c_ctl Fm (6/4/3/6) | 7 | **bounded** (bmc3, 77 frames) | N1; 2 negatives | RX never full |
| 5 | i2c_ctl Sm (5/5/5/5) | 29 | **bounded** (bmc3, 76 frames) | none | RX never full |
| 6 | i2c_tgt Sm (19/22/19) | 5 | **bounded**: co-sim 2 x 15.36M cycles, 0 bad; 40 checkpoint-BMC windows, 0 hits | N1; 2 negatives | RX never full; config byte ready; **EA1** |
| 7 | usb_ls_tx | 19 | proved (1,246 s); packet contents G7 bounded | N1; 4 negatives | RX never full |

Every negative is a firmware or contract mutant that must fail, and does, with a replayed
counterexample. The harness list is in `formal/src/ag_pkg.ml`.

Times are wall-clock of the original runs (log/protocols_v1.md, log/increments_v2.md 3.2). The A2
inputs (`formal/src/ag_pkg.ml`, the contract library, compiler and lane spec) are unchanged since
those runs. Conditions C1-C4 under which spec-level A2 carries to the v2 chip are checked in
log/protocols_v2.md 1. Every package is also run on the v2 top RTL against Psim at its own divisor
(rtl_v1/test/test_c3_*.ml, test_inc*.ml), on the gate-level netlist (17 demo-board scenarios,
log/demo_v2.md), and through the host package (11 scenarios, doc/host.md).

## 4. Check witnesses

103 distinct checks over the 8 shipped contracts (80 fail, 23 blame). Each has a witness: a
concrete run in which that check is the monitor's first verdict, with the assumptions intact
until then. 94 come from formal covers (dprove, replayed); 9 come from a directed search in Psim,
confirmed on the chip RTL. There are 0 dead checks. All 80 fail witnesses are clean: no blame
fires in the same step. The reference interpreter agrees on all 103. Source: log/witness_v2.md,
log/witness_v2_table.md.

## 5. Oracle independence (mutation campaign)

Mutants of the shipped units (lane RTL 1,970, lane spec 1,623, monitor lane 1,789 sites) were
scored by spec-based oracles (differential simulation SIM, A1, R1b, C3) and spec-free oracles
(A2, sigrok protocol decoders SR). Full table: log/kill_matrix_v2.md; method: log/campaign_v2.md.

| unit | SIM, all mutants | sample (non-equivalent) | not killed by any oracle |
|---|---|---|---|
| lane_rtl | 78.4 % | 104: A1 104, SIM 92, C3 54, SR 51 | 0 |
| lane_spec | 74.7 % | 92: A1 91, SIM 87, A2 30 | 1 (A1 undecided at 900 s) |
| mon_lane | 45.7 % | 91: R1b 78, SIM 60, C3 21, SR 0 | 10 (6 later killed by 10x SIM; 4 open) |

The 4 open monitor survivors are bounded-oracle survivors only: a design with such a firing
divergence would falsify the unbounded R1 proof, which the shipped monitor passes.

**Contract mutants** (100 sampled on the 5 packages with unbounded A2): without witnesses, 63/100
were caught by no oracle. The directed scenarios exercised only 10 of 65 checks. With the
witnesses replayed as an oracle (W), 25/100 remain uncaught: 15 on statements that share their
code with the witnessed statement, and 10 bound changes no witness probes. 166 role-swap mutants
are rejected statically by WF2.

## 6. Held-out protocol (flexibility)

1-Wire was specified and run after the freeze with zero RTL changes. Its contract is expressible
in contract language v1, compiles, and fits the monitor ISA (2 units, 20 instructions, all 7
window values). The firmware (34 words) runs unmonitored on the chip RTL and on the gate-level
netlist; RTL and GL agree on every bus edge. It is not monitored on chip (the shipped monitor is
ROM-only) and has no A2 proof. Language limits found: no branch on elapsed time, one guard per
watcher, 7 window values. Source: log/flexibility_v2.md.

## 7. Assumptions that remain

**Physical, not monitored** (doc/concept/assume_guarantee.md 3.3): PH1 no metastability at the
input synchronisers; PH2 timing closure in every corner (signed off by STA, section 2); PH3
clock within tolerance; PH4 pads as modelled; PH5 instruction memory holds the loaded program
(the load gate is proved, the SRAM contents are not); PH6 SRAM macro as the IHP functional model;
PH7 the reset synchroniser as modelled; PH8 stable supply.

**Host stream** (outside the monitor): the RX FIFO of a running lane never fills (all packages
except UART TX); for SPI target and I2C target, a byte is in TX when the lane pops it. The host
package (`host/pemu`) guards the RX condition and reports a run in which RX reached 8 as invalid
(doc/host.md 3.1).

**EA1** (I2C target only, user decision 2026-10-19): environment-driven I2C conditions are at
least hd steps apart, and the bus stays idle until the target has popped its configuration byte.
This is an unmonitored environment assumption, so the I2C target claim is not unconditional.

## 8. Limits, stated plainly

- **Not tested with real devices or silicon.** All evidence is simulation and proof against
  models written from standards and datasheets. Pads, analogue bus behaviour and silicon defects
  are untested.
- Contract faithfulness is measured, not proved (section 5).
- Bounded, not proved: I2C controller (Fm, Sm), I2C target, USB packet contents (G7).
- Argued, not machine-checked: the C3 wiring lemma and Lemma S.
- The chip theorem is stated on stamps. The verdict pins are indicators: they can show a fail up
  to slots - 1 cycles before a same-step blame (doc/contracts/monitor_isa_v1.md 6).
- The shipped monitor is ROM-only (8 packages). Option-D window registers retune window values of
  ROM contracts from the host, but a protocol outside the ROM runs unmonitored. The loadable
  monitor did not route on 6x4 (log/increments_v2.md 2).

## 9. Defects found by the verification

Before RTL freeze, recorded in log/disagreements.md before any fix:
- D2-D12: contract or firmware defects found by co-simulation and by A2 counterexamples, mostly
  in I2C. Examples: a read-back through the synchroniser that rewrote SDA in a release step (D9),
  and a target that accepted a one-step SCL drop (D11).
- D13: the chip's monitor admission rule would have refused the v1 I2C target packages. No tool
  found it; the v2 harness audit did. Fixed by a static admissibility check per package.

After freeze (no RTL change needed):
- A non-draining host makes the I2C target fail (PUSH blocks per ISA). This was documented and
  guarded in the host package (log/witness_v2.md 3).
- Several protocol documents stated a weaker RX assumption than the proofs use; corrected.
- An earlier I2C target divisor note ("P <= 17") was wrong: P = 14 and 16 lose transactions
  silently at 30 MHz (Psim sweep).
- A host write to a full TX FIFO is dropped silently (log/flexibility_v2.md 4).

## 10. v1 to v2

v1 (8x4, 8 monitor units per lane, loadable monitor) did not close timing or routing. v2 restarted
on 6x4 with the same ISA and contract language, under rules derived from the measured v1 runs
(doc/decisions/v2_lessons.md):
- size from place-and-route probes, not synthesis;
- a column floorplan for the one horizontal signal layer;
- clock from post-route slow-corner slack with margin;
- admissibility checked, not assumed;
- the composition proved or tested;
- every CI run bounded to finish inside 6 h;
- growth by generator parameters.

The spec-level proofs (A2) carried over unchanged. Lane A1 carried because the lane sources are
byte-identical. The monitor R1, the composition C3 and E4/E5 were redone for v2.

## 11. Tools

Hardcaml (RTL, cyclesim, expect tests), Yosys and ABC (dprove, PDR, k-induction, bmc3), Yosys
equiv (E4/E5, COMBDLY), Icarus Verilog and cocotb 2.0 (RTL and gate-level board), libsigrokdecode
(spec-free decoder oracle), the TT LibreLane flow on GitHub Actions (hardening, precheck, gate
level), MicroPython 1.29 (host package check).

## 12. Use of AI tools

To be written at submission time.

## 13. Reproduction on the frozen tree

`tools/reproduce.sh all` covers:
- builds and expect tests;
- the freeze check: the `freeze_verilog` step re-emits the core from the current sources and
  requires it to be byte-identical to `src/pemu_core_v1m.v`;
- the demo board, host package and 1-Wire scenarios, on RTL and on the signed-off netlist;
- R1, package A2 (21 harnesses) and the check witnesses.

What was re-run on the frozen tree on 2026-11-11 (log/freeze_v2.md):
- **Freeze identity:** the re-emitted core is byte-identical to `src/pemu_core_v1m.v`, and the
  gate-level netlist used is the sign-off netlist (sha256 equal).
- **quick and sim:** all steps pass. 17 demo-board, 11 host-package and 3 1-Wire scenarios on
  RTL and gate level; RTL = GL; verdicts identical to the committed records.
- **R1:** all 6 harnesses and both negative controls, as logged.
- **A2, a sample:** UART RX and UART TX, i.e. U, N1 and every negative, 7/7 as expected, with U
  wall times within 3 % of the original runs.

Cited from the logs, not re-run: A2 for SPI, I2C and USB; the check witnesses; E4/E5; the
mutation campaign. This is justified by the freeze identity: the design sources emit the same
Verilog, and the netlist is the signed-off one. The A2 inputs are also unchanged where it matters:
the lane spec, contract library and compiler are the same, and the U and N1 logic of
`formal/src/ag_pkg.ml` is the same. Later changes to that file only add the Cover mode for
witnesses, a `free_chip` option that is off by default, and new harnesses.
