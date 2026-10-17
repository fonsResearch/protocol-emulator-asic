# Concept: assume-guarantee protocol engine

Status: DRAFT v0 (2026-10-17), for review. Nothing here is frozen. Architecture parameters (tile size, lane count, memory, clock, protocol set) are open decisions; see section 6.

Legend: **[F]** established by a run or a cited source; **[E]** estimate; **[D]** design proposal, not yet decided.

## 1. Claim

Every protocol the chip runs ships as a *package*: a program, a guarantee contract and an assumption contract. For every package, including packages written after tape-out, we prove a theorem about the taped-out netlist:

> On every cycle, either the pins and the host-visible data meet the guarantee contract, or the chip has already raised an assumption flag recording which environment assumption was broken, and when.

Environment assumptions do not appear as hypotheses of the theorem. They are checked in silicon by the chip's monitor engine. What remains assumed is listed in section 3.3. All of it is physical, and none of it is about the peer device or the host.

## 2. Package model

| part | written from | runs where | role |
|---|---|---|---|
| program P | the protocol, by the firmware author | driver lane(s) | produces the protocol |
| guarantee contract G | the protocol standard (or the peer datasheet when no standard exists), by a context isolated from P | offline in the proof; optionally on-chip as a self-check | what the chip promises |
| assumption contract A | the standard or datasheet, by the same isolated context as G | on-chip monitor engine, always | what the chip relies on from the peer and the host |

G and A are written in one contract language (`doc/contracts/language_v0.md`) and compiled to monitor-engine programs. Each check in a contract carries a role:
- `fail`: the chip is at fault. This is a guarantee check, allowed only on chip-driven observables.
- `blame`: the environment is at fault. This is an assumption check, allowed only on environment-driven observables.

One watcher may contain both kinds, because many assumption checks depend on protocol phase (for example, an I2C ACK slot versus a transmitted 1 bit).

## 3. The theorem and its side obligations

### 3.1 Main theorem U(P, G, A)

Let cycles be numbered from the first cycle after reset release (`doc/interface.md` section 1). Let the input sequence (raw `ui_in`, `uio_in` and `rst_n` on every cycle) be arbitrary. Define:

- `F(c)`: some `fail` check has fired at or before cycle c;
- `B(c)`: some `blame` check has fired at or before cycle c.

Both are sticky until reset.

**U(P, G, A):** for every input sequence and every cycle c, `F(c) -> B(c)`. In words, no `fail` without an earlier or same-cycle `blame`.

If reset is asserted again, every component restarts, monitors included, and U applies afresh from the next release.

### 3.2 Side obligations (U alone is not enough)

U is trivially satisfied by an assumption contract that blames everything. Three further obligations prevent that:

1. **N1, non-vacuity (proved).** Against a reference peer model R_P, written from the datasheet or standard by a third context, B never fires. Every host request also completes within its stated bound; that bound is expressed as `fail` checks with finite windows in G. Proof: the same harness as U, with the environment constrained by R_P.
2. **N2, assumption leniency (tested, not provable).** A never blames a trace that an independent conformance oracle accepts. Oracles: sigrok protocol decoders on simulated traces, several independently written peer models, and mutation of A (a strengthened A that no oracle catches is a finding).
3. **N3, guarantee faithfulness (tested, not provable).** G says what the standard says. Evidence: authorship isolated from P, spec-free oracles (decoders), and contract mutants scored in the kill matrix.

N2 and N3 are the honest limit: a contract is a reading of prose, and no proof can establish that the reading is right. The write-up states this.

### 3.3 Remaining assumptions (stated, not monitored)

| id | assumption | why it cannot be monitored on-chip |
|---|---|---|
| PH1 | asynchronous inputs are stable around the sampling edge (no metastability) | sub-cycle analogue behaviour |
| PH2 | static timing closes at the operating clock in every corner, IO constraints included | a property of the physical design, checked by STA |
| PH3 | the clock frequency is within the declared tolerance | contracts convert ns to cycles for a declared clock |
| PH4 | pads behave per the PDK IO cell models (drive, thresholds, edge rates) | analogue |
| PH5 | instruction-memory contents equal the loaded program | decision 2 in `log/slice_report.md`; a hardware load gate [D] would turn this into a proved invariant |
| PH6 | the SRAM macro, if used, behaves as the IHP functional model | the macro is outside our logic |
| PH7 | the wrapper's reset synchroniser behaves as modelled | currently checked by replay only [F] |
| PH8 | supply is stable | analogue |

Every proof report lists the subset it relies on.

## 4. Proof chain

```
standard / datasheet
   |  (isolated authorship; N2, N3 by oracles)
   v
G, A  --compile-->  monitor programs M_G, M_A
                          |
S1(P) || S1-mon(M_G) || S1-mon(M_A), free environment
   |  U proved by model checking (ABC dprove), negative controls, cex replay
   |  N1 proved with the environment constrained by R_P
   v
A1:      RTL driver lanes  == S1      (all pins, every cycle, any loaded program)
A1-mon:  RTL monitor engine == S1-mon (all observables, every cycle, any loaded monitor program)
   |  pins and verdicts identical, so U and N1 hold on the RTL
   v
E5:      final SG13CMOS5L netlist == RTL (sequential equivalence, liberty cell semantics)
   |
   v
U and N1 hold on the netlist, under PH1-PH8
```

Composition is sound because the A1 and A1-mon observation relations include every signal the monitors read: pins, synchronised inputs and host-interface events. The on-chip checker and the checker used in the proof are the same compiled program. They are linked by A1-mon, not by a second implementation.

## 5. What the chip demonstrates

- **Emulator:** driver lanes run protocol programs, as now.
- **Conformance checker:** the assumption monitors judge the attached device against the standard and report the first violation with a cause code and cycle stamp.
- **Self-check:** the optional on-chip guarantee monitors cover what the proofs cannot: pads, electrical timing, silicon defects. Silicon arrives after judging, so this is shown in simulation and stated as a capability.
- **Post-tape-out flexibility:** a new protocol is a new package. The toolchain proves U and N1 for it on the frozen design with no RTL change.

## 6. Architecture outline [D]

Fixed by the concept:
- one or more **driver lanes**, timed engines in the v0.1 lineage;
- a **monitor engine** that executes compiled contract programs;
- a **verdict block**: sticky `fail`/`blame` flags, first-cause code, cycle timestamp, host-readable;
- host-interface **stream taps**, the monitors' only source of reference data. They tap the host port, never lane-internal state, so a lane bug cannot hide behind its own data.

Open, decided at the architecture gate (plan step 3):
- number of driver lanes and monitor engines;
- execution model and timing primitives;
- protocol assists;
- instruction-memory technology and size;
- datapath;
- host interface;
- pin model;
- clock;
- tile size;
- whether a `blame` may also trigger enforcement (release the pins, halt the lane) or only report;
- the hardware load gate (PH5).

## 7. Prior art

- **Runtime validation that a verified model's assumptions hold, so offline proofs transfer to the running system:** ModelPlex, Mitsch and Platzer, RV 2014, doi:10.1007/978-3-319-11164-3_17, and FMSD 2016, doi:10.1007/s10703-016-0241-z. This concept applies the same principle to cycle-exact pin protocols, with the monitor implementation itself proved against the RTL.
- **Reprogrammable hardware monitors for bounded-time temporal properties:** arXiv:2603.19851.
- **End-to-end hardware/software verification of an embedded system with I/O (SPI):** Erbsen et al., PLDI 2021, doi:10.1145/3453483.3454065. That work verifies over architectural I/O events; ours is over cycle-exact pins.
- **Processor refinement against an ISA specification:** Reid et al., CAV 2016, doi:10.1007/978-3-319-41540-6_3.
- **ISA-level timing instructions:** Lickly et al., CASES 2008, doi:10.1145/1450095.1450117.
- **Independence of separately written versions:** Knight and Leveson, TSE 1986, doi:10.1109/tse.1986.6312924; for LLM-generated code, arXiv:2607.02808.

## 8. Hard to verify, and how we treat it

1. **Contract faithfulness (N2, N3).** Not provable. Measured by oracles and mutation; stated as a limit.
2. **Cost of U.** Unmeasured. After a `blame` the property holds trivially, which prunes the search, but the environment is fully free. Measured in the feasibility spike (plan step 2).
3. **Latency alignment.** Monitors see inputs through the 2-flop synchroniser. Intervals between a chip output edge and an observed input edge are known only to within one cycle. The compiler must widen `blame` windows and narrow `fail` windows by that uncertainty, and that rule needs its own tests.
4. **I2C.** Wired-AND lines, clock stretching (unbounded in the standard, bounded here by an explicit policy parameter, so a `blame`), and arbitration. Contracts are drafted on paper first (`doc/contracts/contracts_v0.md`).
5. **Scaling of A1 and A1-mon** to a v1 lane and a monitor engine. Fallback: per-instruction refinement with a completeness check.
