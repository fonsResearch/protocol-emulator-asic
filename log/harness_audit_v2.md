# Harness audit for the v2 restart (plan v5 step 1, 2026-10-26)

Question: if v2 keeps ISA v1, interface semantics and contract language v1 (option A, agent choice
for user review) but replaces the microarchitecture, which v1 results carry over unchanged?
Method: read every harness in `formal/src` and the co-simulation, and record what each one
instantiates (spec circuit or RTL) and which v1 implementation facts its statement depends on.
Facts are from the source files named; "carries" is a judgement under the conditions in section 2.

## 1. Per harness

| harness (file) | obligation | instantiates | v2 status (option A) |
|---|---|---|---|
| `ag_pkg.ml` | A2 for all 15 packages: U, N1, host-stream assumptions, EA1, `od_wired` | **spec**: `spec_v1/Lane_circuit` + `monitor_v1/Mon_spec`; wiring mirrors `Top_v1` (lane pads through a 2-flop synchroniser, monitor synchronises itself, OWN masking, blame registered one cycle) | **carries** if conditions C1-C4 hold; results that were bounded stay bounded |
| `usb_check.ml` | proof-side USB-LS contents checker (G7/G9) | part of the A2 harness, no chip logic | carries |
| `ag_v1.ml` | A2 UART TX on the lane spec with the v0-era monitor circuit | spec | carries (historical; superseded by `ag_pkg`) |
| `ag_harness.ml` | v0.1 spike (U, N1, A1MON, URTL) | v0.1 spec and RTL | not part of the v2 chain |
| `a1_lane.ml` | A1 lane: L1 fetch, L2 datapath, L3 independence, monolithic cross-check | **RTL** `Lane_rtl` + `Sram256` vs spec `Lane_circuit` | **redo** on the v2 lane RTL; the decomposition and the SRAM ghost rules are reusable if the macro type keeps the same port rules |
| `mon_ref.ml` | R1(j): `Mon_lane` refines `Mon_spec`, unit j fires at t + j, assumption T8 (steps at least 8 cycles apart) | **RTL** `Mon_lane` vs spec `Mon_spec` | **redo**: the statement (slot schedule t + j, T8) is specific to the v1 engine; the spec side and the harness pattern are reused |
| `mon_fetch.ml` | F0/F1t: loadable fetch timing (units 6, 7; min_p 13) | **RTL** `Mon_lane`, `Mon_engine.fetcher` | **redo/generalise** if more units become loadable or state moves to SRAM |
| `presc16.ml` | prescaler definitional lemma | RTL `Prescaler16` | carries if the prescaler is kept |
| `top_props.ml` | load gate, OWN disjointness, lane pin gating, RUN 0 for 33 cycles after reset | **RTL** `Top_v1`, `Lane_rtl` | **redo** on the v2 top; harness pattern reusable |
| E4/E5 (`flow/equiv`) | RTL = synthesis netlist = final netlist | netlists | rerun per netlist (scripted) |
| `protocols_v1/src/psim.ml` + tests | co-simulation with peers and sigrok cross-check | **models** (`Lane_model`, monitor interpreter + compiled model) | carries; does not exercise the chip top (see D13) |
| `formal/mutation`, `formal/inv`, `ckpt_bmc.py`, `replay_cex` | campaign and tools | tools | carry; rerun on v2 |

Spec-level code that carries unchanged: `spec_v1` (Isa1, Lane_model, Lane_circuit, Programs_v1),
`monitor_v1` Lang, Interp, Mon_spec, Library_v1 and the Compile front end. The 82-bit word
encoding and store image are back-end details that change if the v2 store format changes.

## 2. Conditions under which the A2 results carry

- **C1** The v2 lanes implement `Lane_circuit` (ISA v1.0.2) exactly: proved by the v2 A1.
- **C2** The v2 monitor refines `Mon_spec` per step for every shipped package: proved by a v2 R1
  with its own slot schedule and its own environment bound (v1: T8).
- **C3** The v2 top composes lane and monitor as the `ag_pkg` harness does: pad synchroniser
  depths, OWN masking of the monitor's view, blame one cycle later. This was argued in v1 (the
  harness comment mirrors `Top_v1`) but **not proved as a lemma**. v2 adds a composition lemma
  on the top RTL.
- **C4** Every shipped package's divisor P is admissible in the configuration it ships in, so
  the environment bound of C2 holds whenever the package runs monitored. **v1 violates C4 for the
  I2C target packages (D13, log/disagreements.md):** they need P = 3, while admission requires
  P >= 7.

## 3. Consequences for v2

- Carries (spec level): A2 for 15 packages, the USB checker, the bounded I2C/USB evidence, the
  contract defects D2-D12 and their fixes. These were most of the step-7 effort (judgement; not
  measured).
- Must be redone: lane A1, monitor R1/F0/F1, top properties, equivalence, plus a new
  composition lemma (C3) and a static admissibility check (C4).
- The monitor's slot schedule decides which packages ship monitored. At P = 3 a step lasts 4 cycles,
  so a v2 engine that serves 8 units one per cycle cannot monitor the I2C target. This is an input to
  the step-3 decision gate.
