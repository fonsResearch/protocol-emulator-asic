# Architecture v1: options for decision (plan step 3)

Status: DECIDED (2026-10-17). Every item is marked DECIDED below, either by the user or by the agent where the user delegated it. Changes after this point go through doc/CHANGES.md. Inputs: `doc/concept/assume_guarantee.md`, `doc/contracts/language_v0.md`, `log/spike_report.md`, `log/build_path_report.md`.
Legend: **[F]** measured or cited; **[E]** estimate.

Decisions are grouped by what they block:
- **G**: consequences of the spike; they decide whether the concept proceeds as designed.
- **A**: architecture; they fix area and the ISA.
- **V**: verification items that must be settled before the ISA freeze.

Section 4 lists a dependency order.

---

## G. Spike consequences

### G1. How proofs reach real protocol timing

**DECIDED 2026-10-17: (a) timebase ticks**, delegated by the user to the agent. Reason: the only option that scales to held-out protocols without per-package manual work. It is conditional on the tick spike (U with a free tick input plus a prescaler lemma); if that spike fails, the fallback is (c).

[F] U proof time grows with window length: spec d = 8, 12, 16 took 315, 533 and 1,001 s. Real windows: 434 cycles for a UART bit at 115,200 baud and 50 MHz; 235 cycles for I2C Sm tLOW at 50 MHz.

| option | idea | benefit | cost / risk | verification consequence |
|---|---|---|---|---|
| (a) timebase ticks | driver WAITs and monitor windows count ticks from a programmable prescaler, not clock cycles; edges are still sampled every cycle | contract constants stay small for every baud rate; the prescaler is a reusable architecture feature (baud generation) | ISA change (WAIT in ticks or cycles, selectable); timing resolution is 1 tick; one prescaler or one per lane | [E] if every window in a package is in ticks, U can be proved with the tick input free (any tick pattern), which also covers the real prescaler; a separate lemma proves the prescaler's exact period for any divisor. Needs a spike to confirm |
| (b) scale-invariance proof | prove at small d; prove separately that behaviour depends only on counters reaching thresholds | no ISA change | the abstraction proof is research work; soundness needs care | an extra proof layer per package or per instruction class |
| (c) strengthened invariants | supply inductive invariants relating the program's WAIT counter to the monitor's window counter | no ISA change | manual per package; may be machine-assisted, with every invariant checked | invariants become part of each package's proof artefact |
| (d) accept small windows | prove U at small d; state real-rate behaviour as tested, not proved | none | the headline claim weakens to small-window proofs plus testing | the "Minimum" tier |

### G2. Monitor program store

**DECIDED 2026-10-17: (f) hybrid, as one engine design with two store types**, delegated by the user to the agent. Shipped protocols use ROM-store watchers: constant programs synthesise to about the size of a hardwired monitor (5,191 um^2 against 5,225 um^2, measured). Post-tape-out packages use a small compressed loadable store, sized against the area budget once A3 is decided. Consequence: V6 (b), the generic A1-mon for the loadable store, becomes required.

[F] Mapped estimates:
- hardwired UART monitor: 5,225 um^2;
- loadable store in flops: about 6,365 um^2 per 81-bit instruction slot (4 watchers x 16 slots = 418,377 um^2, 46% of the 6x4 core);
- the UART contract compiles to 27 instructions.

| option | benefit | cost / risk | effect on the claim |
|---|---|---|---|
| (a) hardwired monitors for the shipped protocols | about 5k um^2 each; simplest proofs | no on-chip monitoring for post-tape-out packages | new packages proved with assumptions stated, not monitored |
| (b) compressed encoding in flops | windows and codes via small constant tables, contract-local observable indices: about 45-50 bits per instruction [E] | still about 3.7k um^2 per slot [E]; 64 slots is about 25% of 6x4 [E] | full claim, small programs |
| (c) latch store | about half the flop area per bit [E, unmeasured] | latch timing and equivalence (E5) are harder; custom flow risk | full claim |
| (d) SRAM store plus per-watcher instruction cache | macro area: 1P 64x64 is 50,489 um^2 LEF [F] | one read per cycle against several watchers completing in one cycle: needs dual-port SRAM (2P 64x32 is 52,621 um^2 [F]) or a compiler restriction; cache logic adds an A1-mon obligation | full claim, larger programs |
| (e) parameterised window units | a fixed block of units configured by registers (trigger, predicate, window, role, code), chained | small [E: 20-40k um^2 for 8 units]; reprogrammable | less expressive; a UART frame needs many units or a counter extension | full claim within the block's expressiveness |
| (f) hybrid: hardwired for shipped, small loadable store for new | shipped protocols cheap; some post-tape-out monitoring | two monitor paths to verify | full claim for shipped, partial for new |

### G3. Concept go/no-go

**DECIDED 2026-10-17 (user): (a) proceed at the Full tier.**

Options:
- **(a)** Proceed at the Full tier, choosing G1 (a)/(b)/(c) and G2 (b)-(f).
- **(b)** Proceed at the Reduced tier: hardwired monitors, real-window proofs via G1.
- **(c)** Stop the concept and return to the A1-led plan without monitors. The spike code stays as a verification tool.

---

## A. Architecture

### A1. Tile size

**DECIDED 2026-10-17 (user): (b) 8x4 primary with a green 6x4 fallback build.**

[F] tt-support-tools d66cf17 accepts 8x4 (1724.16 x 710.64 um). Core area is 902,417 um^2 at 6x4 and 1,208,173 um^2 at 8x4. The organisers' email of 2026-10-16 says 8x4 is planned, with a template expected in mid-October, and to design to 6x4 until then.

Options:
- (a) 6x4 only;
- (b) 8x4 primary with a green 6x4 fallback build;
- (c) parametric RTL, decide at RTL freeze;
- (d) ask the organisers first (you send the email).

### A2. Protocol set and roles

**DECIDED 2026-10-17 (user): floor plus USB-LS TX.** UART TX/RX, SPI modes 0-3 as controller and target, I2C Sm/Fm as controller and target, and low-speed USB transmit; each with contracts, U and N1.

[F] Organisers: UART, SPI modes 0-3 and I2C 100/400 kHz first; USB-LS and 10BASE-T as stretch; controller+target and concurrency are a plus; fewer protocols with strong architecture and verification can be competitive.

Options:
- (a) floor only, each with contracts, U and N1;
- (b) floor plus one stretch protocol (USB-LS TX or 10BASE-T TX);
- (c) floor plus breadth (JTAG, SWD, 1-Wire, WS2812, ...);
- (d) a floor set plus held-out protocols implemented after RTL freeze (plan step 11).

### A3. Driver lanes: execution model and count

**DECIDED 2026-10-17 (user): two independent lanes**, each with its own program and tick, and pin ownership between them. Proof structure: A1 per lane plus a non-interference lemma.

| option | benefit | cost | proof consequence [E] |
|---|---|---|---|
| (a) one timed lane (extend v0.1) | smallest; A1 already proven at v0.1 | no simultaneous controller+target | whole-machine A1 as now |
| (b) N independent lanes, each with its own program | concurrency; isolation by construction | N x area; pin arbitration | A1 per lane plus a non-interference lemma |
| (c) one pipeline, interleaved threads | shared datapath; deterministic per-thread timing | pipeline control is the hard RTL | one larger A1; thread swap gives a timed-QED transform |

Count: 1, 2 or 4. The v0.1 core logic is 8,444 um^2 [F]; a v1 lane with a datapath and assists is roughly 15-40k um^2 [E].

### A4. Timing primitives (coupled to G1)

**DECIDED 2026-10-17, delegated by the user to the agent:** follows G1. WAIT counts prescaler ticks; each lane has its own prescaler (A3); fractional division is not in v1.

Options:
- (a) relative WAIT in cycles (as now);
- (b) WAIT in prescaler ticks (G1a);
- (c) absolute deadline register;
- (d) fractional divider.

Avoid sub-cycle output placement (half-cycle writes, delay lines): it is hard to verify formally and to time.

### A5. Protocol assists

**DECIDED 2026-10-17, delegated by the user to the agent:** open-drain mode, shifter, NRZI + bit stuffing, configurable CRC (CRC5/CRC16, polynomial register), a D+/D- pair output mode, and edge wait with timeout. Reasons: USB-LS at 40 cycles per bit leaves no budget for CRC or stuffing in firmware; the timeout bounds every wait, keeping U and N1 tractable.

Choose any subset:

| assist | needed for | verification note |
|---|---|---|
| shifter | SPI at speed | small unit proofs |
| configurable CRC | USB, CAN, Ethernet | reference model per polynomial |
| NRZI + bit stuffing | USB-LS | the spec must model the stuffing-induced timing exactly |
| Manchester encoder | 10BASE-T TX | |
| edge wait with timeout | I2C stretching, robust RX | |
| open-drain mode | I2C, 1-Wire | |
| host FIFOs | throughput | |

Every assist enters A1 and needs contract-language support for its observables.

### A6. Instruction memory (driver lanes)

**DECIDED 2026-10-17 (user): one RM_IHPSG13_1P_256x16_c2_bm_bist macro per lane.** This settles open decision 5 (macro core). Consequences:
- the PDN plugin must be redone for this macro's column geometry;
- the extra bit-mask and BIST pins need tie-offs;
- the DOUT/DIN electrical limits must be re-checked (compare the 64x16 A_DOUT max-cap issue);
- the E1/E5m chain needs this macro's functional model.

[F] LEF areas: 1P 64x16 15,240 um^2; 256x16 28,127; 512x16 45,309; 256x32 49,488; 2P 256x16 57,521. All except 64x16 and 2P 64x32 are `_bm_bist` variants with extra pins and new power-grid geometry for our plugin. Flop storage costs about 784 um^2 per 16-bit word plus the read mux [F, mapping].

Options:
- (a) flops, 64-128 words;
- (b) one 1P macro, 256-512 words, shared;
- (c) one macro per lane;
- (d) a 2P macro (load while running, two readers);
- (e) latches.

This also settles open decision 5 (flop core or macro core).

### A7. Datapath

**DECIDED 2026-10-17, delegated by the user to the agent:** (b) without data RAM: a 4 x 8-bit register file with compare (register or immediate) and branch on equal/zero, plus the v0.1 shift register and loop counter. Per-lane host TX/RX FIFOs (part of A8) carry data and are the monitors' stream taps. USB packets stream from the TX FIFO through the shifter.

Options:
- (a) the v0.1 registers (out, sr, lc) plus additions per protocol;
- (b) a small register file with compare-and-branch on data, needed for target roles (address match, ACK decisions);
- (c) a data RAM or mailbox.

### A8. Host interface

**DECIDED 2026-10-17, delegated by the user to the agent:** (b) an SPI target port: CS, SCK, MOSI on ui; MISO on uo. Its register map covers driver and monitor program load, per-lane FIFOs, run control and verdict readback. The host's SPI timing is an environment assumption, monitored as a blame contract; the SCK oversampling CDC point is a verification item.

Options:
- (a) the parallel strobe loader (as now, inside A1);
- (b) an SPI target port: 4 pins, natively driven by the RP2350, with readback. SCK is oversampled in the core clock, a CDC point that must be verified;
- (c) a nibble bus.

The interface must also expose the verdict block (fail and blame flags, first causes, timestamps).

### A9. Pin model

**DECIDED 2026-10-17, delegated by the user to the agent:** the 8 uio pins are protocol pins shared by both lanes under an ownership mask. A halted lane drives oe = 0 (idle by pull-up), which resolves open decision 6. A fixed set of spare uo pins are push-pull lane outputs (no crossbar). Two uo pins carry the live fail and blame flags for the demo board's display.

Options:
- protocol pins on `uio` with `oe` = 0 while halted (fixes open decision 6, and lets RUN drop between frames without a blame);
- open-drain emulation;
- pin ownership across lanes;
- the host/protocol pin budget (24 pins total [F]).

### A10. Clock

**DECIDED 2026-10-17 (user): 60 MHz** (16.67 ns period). USB-LS = 40 cycles per bit. Timing closure at 60 MHz in all corners is unverified; the current design has 10.50 ns slack at 20 ns (slow corner).

[F] No organiser target. The RP2350B generates the project clock; TT documents 1 Hz to 66.5 MHz. Run 5 slack at 20 ns is 10.50 ns (slow corner).

Integer cycles per protocol unit:

| clock | USB-LS bit | 10BASE-T half-bit |
|---|---|---|
| 40 MHz | 26.67 | 2 |
| 48 MHz | 32 | 2.4 |
| 50 MHz | 33.33 | 2.5 |
| 60 MHz | 40 | 3 |

Options: (a) 50 MHz; (b) 60 MHz; (c) 48 or 40 MHz; (d) any clock, with a fractional prescaler (G1a, A4d).

---

## V. Verification items to settle before the ISA freeze

1. **V1, blame response (language Q3).** (a) Report only. (b) Also release the pins and stop the lane on a blame, which must then be specified as a guarantee after the blame.
2. **V2, I2C arbitration (Q4).** (a) A blame (single-controller packages only). (b) A guarded branch with a release-within-k guarantee.
3. **V3, on-chip guarantee monitors (Q5).** (a) Always loaded when capacity allows. (b) Optional per package. (c) Never: offline only.
4. **V4, instruction-memory initial state (open decision 2).** (a) Hardware load gate: RUN is ignored until a full program has been loaded since reset, making PH5 a proved invariant. (b) Per-word valid bits. (c) Reachability decomposition. (d) State the assumption.
5. **V5, A1 cross-check engine (open decision 1).** (a) sby k-induction with invariants. (b) rIC3. (c) Pono. (d) Certified results checked by an independent checker. (e) Defer.
6. **V6, generic A1-mon.** (a) Per-contract translation validation only (as in the spike; sufficient for each package). (b) Also a generic proof, needed if monitor programs are loaded at run time (G2 (b)-(f)).
7. **V7, open decisions 3, 4 and 7** (A2 data correctness, reset-value mutants, COMBDLY lint). Their options are unchanged from `log/slice_report.md` section 5.

### V decisions (2026-10-17)

- **V1 (user): configurable per package.** Report only, or report and release the pins (oe = 0) and halt the lane. A package bit selects which. Both behaviours are specified and proved.
- **V2 (user): guarded branch.** Arbitration loss is legal; the chip must release SDA/SCL within k ticks and report it. Needs the guarded-branch extension in language v1.
- **V3 (delegated to the agent): on-chip guarantee monitors for the shipped protocols, in the ROM store.** Loadable packages run assumptions only. Keeps the silicon self-check claim at about 5k um^2 per protocol.
- **V4 (delegated to the agent): hardware load gate plus a bound fault.** RUN is ignored until a program of declared length has been loaded since reset, and fetching at or beyond the declared length faults the lane. Together these make PH5 a proved invariant.
- **V5 (user): certified results.** A certificate-producing engine, with witnesses checked by an independent checker (Certifaiger, Yu, Biere and Heljanko, CAV 2021, doi:10.1007/978-3-030-81688-9_17). Tool availability (rIC3 build, witness format for our models) is a step-5 task.
- **V6: generic A1-mon required**, as a consequence of G2.
- **V7:**
  - open decision 3 is resolved by design (data checked against host-FIFO streams);
  - open decision 4 is superseded by the v1 mutation campaign;
  - open decision 7 (user): post-process the emitted Verilog, with combinational `<=` rewritten to `=` and E2-E5 equivalence covering the rewrite.

## 4. Order

1. G3 (go/no-go).
2. G1 and A4 together (timing), then A1 (tile).
3. A2 (protocols), then A3 (lanes).
4. A6 (memory) and G2 (monitor store), which share the area budget.
5. A5, A7, A8, A9, A10.
6. V1-V7.

Steps 1-4 fix the area budget; the rest can follow in any order before the freeze.
