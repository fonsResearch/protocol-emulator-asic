# Monitor engine ISA v1

Status: DRAFT (2026-10-18), plan step 6. This document fixes the items that `language_v1.md` section C8 left to this step. User decisions: 8 watcher units per lane; a loadable store in one extra RM_IHPSG13_1P_256x16_c2_bm_bist shared by both lanes, used by 4 loadable-capable units (2 per lane) with a minimum-divisor rule. Choices made here are marked **[choice]**.

Implementations, all from this document:
- `monitor_v1/src/lang.ml`: language v1 EDSL;
- `interp.ml`: reference semantics on the EDSL tree;
- `mprog.ml`: this ISA, with encoding;
- `compile.ml`: EDSL to ISA;
- `mmodel.ml`: ISA reference model;
- later, the engine RTL and the ISA spec circuit.

## 1. Structure

- **Global sources (48)**, as seen by the monitor in each cycle:
  - `uo_out[7:0]`, `uio_out[7:0]` and `uio_oe[7:0]`, from the cycle they are driven;
  - `ui_in[7:0]` and `uio_in[7:0]` through the monitor's own 2-flop synchronisers (s2);
  - `drive[7:0]` = `uio_oe & ~uio_out`, i.e. pulls low, the open-drain view under ISA v1.0.2;
  - `tx_pop` and `rx_push`: the lane's FIFO events in this step (chip-driven) **[choice]**. Without them, a watcher cannot see a stream event that happens while it is inside a hold: a stream-anchored watcher then silently skips frames.

  Index map: uo 0-7, uio_out 8-15, uio_oe 16-23, ui 24-31, uio_in 32-39, drive 40-47, tx_pop 48, rx_push 49 (50 global sources).
- **Package context, one per lane.** Each lane L has one active package. The context holds:
  - a remap table of 16 local observables, each mapping to a global source (6 bits, 50 used). It is written by the host, so a package is relocatable to its owned pins;
  - a predicate bank (section 3);
  - a window table: 8 entries × 12 bits, entry 0 = 0;
  - a code table: 16 entries × (role 1 + code 8), entry 0 = none;
  - stream bindings: the lane's own `tx_pop` and `rx_push` events and their data.
- **Context source [choice].** A lane's context comes either from ROM (the package index selects constant tables, at about ROM cost) or, for a loadable package, from context registers.
  - The context registers are filled from the loadable store at package start: a header with predicates 1-14, the window table and the code table, 632 bits per lane, about 31k um^2 per lane [estimate].
  - A loadable package's watchers run in units 6-7 only; units 0-5 of that lane are idle.
- **Watcher units.** 8 per lane. Unit k of lane L runs watcher k of the active package of lane L.
  - Units 0-5 fetch only from their ROM slice.
  - Units 6 and 7 of each lane can also fetch from the loadable store (section 7) **[choice: which units are loadable-capable]**.
- **Time base.** A unit of lane L evaluates only in steps of lane L: cycles with L's tick = 1. Ticks occur only while L runs (ISA v1.0.2). The `cycles` time base is used only by the fixed host_spi monitor, which is not part of the engine **[choice]**.
- **Restart rule [choice, flagged for review].** All units, the predicate-bank history and the stream state of lane L return to their reset state in every cycle in which lane L is not running. This mirrors the lane reset (ISA v1.0.2): a stopped lane restarts its program at `pc` 0, and its package's watchers restart with it. The verdict block is not cleared by this rule.

## 1a. Implementation: time-multiplexed units (user decision 2026-10-18, option C)

- **Structure.** Per lane, the observation front end and the predicate bank are evaluated in parallel once per step, as in sections 2-3. A single unit datapath serves the 8 unit states in slots: unit u is evaluated in cycle t + u, where t is the tick cycle. Slot 0 uses the live bank and stream events; slots 1-7 use copies latched at t. Code: `monitor_v1/src/mon_lane.ml`. The unit next-state function (`Mon_spec.unit_step`) is shared with the parallel spec circuit `Mon_spec`.
- **Assumption T8.** While a package runs, the ticks of a lane are at least 8 cycles apart, i.e. at least 8 cycles from one step to the next. Violations are visible: the `overrun` output is asserted by a tick that arrives while slots are still pending. T8 becomes a loader admission rule (ISA prescaler setting) and an assumption of the refinement proof.
- **Restart rule, implementation.** Applied lazily. Every non-running cycle sets a per-unit mask; a unit whose mask bit was set before the current step reads its reset state at its slot. A non-running cycle inside a slot window does not change the units that are still to be processed in that step.
- **Refinement statement.** A firing of unit u in step t of `Mon_spec` appears in `Mon_lane` in cycle t + u, with the same role and code, and `Mon_lane` fires nothing else. This holds for steps whose window t..t+7 contains no reset cycle. A reset clears the verdict, so an in-flight step cut short by reset has no observable effect.
- **Verdict timestamps.** Firings are stamped with the step cycle t, not the slot cycle, so verdict contents equal those of the parallel engine.
- **Blame release latency [choice, flagged for review].** All monitor blames reach the lane through a register, so a blame found in step t is consumed by the lane at its next step. The parallel engine would gate step t itself, combinationally. Theorem U is unaffected (a fail still needs a blame at or before it). The cost: the lane executes one more step after a blame. The benefit: no combinational monitor-to-lane path, and the same latency for every unit.
- **Measured (Yosys/ABC, IHP sg13cmos5l, free tables, one lane, no wire load):** parallel `Mon_spec` 190,884 um^2 typ (579 flops); time-multiplexed `Mon_lane` 118,782 um^2 typ (626 flops); logic delay at the slow corner 7.67 ns and 7.41 ns respectively. The instruction-fetch path is excluded, because fetch is a free input in this measurement.

## 2. Observation per step

For lane L:
1. In each step s of L, the local observables o[0..15] are the remapped global sources in that cycle.
2. For each local observable the bank keeps the values at steps s-1, s-2 and s-3 (3 flops each, 0 before they have been observed).
3. Literal kinds are computed against step s-1:
   - level;
   - rise (now 1, previous 0);
   - fall;
   - changed.

   At the first step after restart, the previous value is invalid and rise, fall and changed are false. The delay d ∈ 0..3 selects the value d steps earlier, with edges taken between d and d+1 steps earlier.

## 3. Predicate bank

- **Contents.** 16 predicates per package; predicate 0 = true, predicate 15 = false **[choice]**. Predicates 1-14 each have 3 literals and two mode bits: (l0 op1 l1) op2 l2, with op1, op2 ∈ {AND, OR}. This covers, for example, `(!oe || out) && !pop` **[choice]**.
- **Literal.** Local observable 4 bits, kind 2, delay 2, negate 1 = 9 bits. Predicate = 3 × 9 + 2 = 29 bits. Unused literal slots repeat a used literal ((a op b) op b = a op b), so no constant literal exists in the encoding.
- **Evaluation.** All 16 are evaluated once per step of the lane, so each unit only selects predicate bits.
- **Unit-local modifier.** Each instruction has one modifier on its requirement predicate (section 4):
  - mode 0: none;
  - mode 1: AND register bit b;
  - mode 2: XNOR register bit b (equality with a sampled bit);
  - mode 3: AND elapsed(m) ≥ window[j].
- **Idle take [choice].** TAKE with check index 0 never fires, which gives the language's `take_idle`.

  Mode 3 takes argument m (1 bit) and j (3 bits).

## 4. Instruction (full format, 82 bits; stored as 6 × 16-bit words in the loadable store)

| field | bits | meaning |
|---|---|---|
| op | 3 | 0 AWAIT, 1 AWAIT_IDLE, 2 HOLD_FOR, 3 HOLD_UNTIL, 4 SKIP, 5 TAKE_TX, 6 TAKE_RX, 7 reserved |
| pe | 4 | event predicate (AWAIT, HOLD_UNTIL; TAKE: ignored) |
| pr | 4 | requirement predicate (HOLD_FOR, HOLD_UNTIL), with the modifier |
| pc_ | 4 | condition predicate (`when`), 0 = true |
| mod | 2 | modifier mode (section 3) |
| marg | 4 | modifier argument |
| mon | 2 | modifier applies to: bit 0 the requirement predicate, bit 1 the expect predicate |
| lo, hi | 3 + 3 | window-table indices; HOLD_FOR and SKIP use hi as n |
| since | 2 | 0 anchor, 1 mark 0, 2 mark 1 |
| chk | 4 | code-table index of the timeout or violation check |
| early | 4 | code-table index of the early check, 0 = none (early events are then ignored) |
| mark | 2 | on completion: none, mark 0, mark 1 |
| smp | 1 + 4 + 4 | on completion: enable, register bit, predicate |
| mat | 1 + 4 | on completion: match register byte 0 against the stream element pushed in this step; check index |
| exp | 4 + 4 | on completion: expect predicate with the modifier applied; check index. The expect is present iff exp != 0 or mon bit 1 is set (exp = 0 with mon bit 1 is a bare register-bit or elapsed-time requirement) |
| bp | 4 | on completion: branch predicate, 0 = never |
| next, alt | 7 + 7 | successor addresses; 127 = STOP (stop silently) |
| tsel | 1 | TAKE destination: register byte 0 or 1 |

Total: 82 bits (an earlier draft of this table was mis-added as 74/76). The `mon` field was added after the differential test found that a single modifier applied to every predicate changes an unmodified `expect` folded into a modified hold. Instants that follow a consuming statement in the source are folded into its completion bundle. The bundle runs in a fixed order: mark, sample, match, expect, branch. The compiler rejects a source order that cannot be folded, and more than one instant of a kind per consuming statement **[choice]**. `raise r C` after a consuming statement folds as `expect false`.

## 5. Unit state and step semantics

State:
- `pc` (7 bits);
- `k`: steps since the anchor (12 bits, saturating);
- `m0`, `m1`: steps since each mark (12 bits, saturating);
- `reg`: 16 bits;
- `stopped`.

Watcher header (per unit, from ROM or the loadable header):
- start pc;
- guard: predicate, range start and end pc, handler pc, enable.

In each step of the lane, for a unit that is not stopped:
1. `k`, `m0` and `m1` increment (saturating), so they count this step. Let κ = `k`, or the mark selected by `since`.
2. **Guard.** If the guard is enabled, `pc` lies in its range and the guard predicate holds, then `pc` ← handler and `k` ← 0. Nothing else happens in this step: the handler runs from the next step, with the anchor at this step.
3. **Operation.** Let E = pe ∧ pc_, and R = ¬pc_ ∨ (pr with the modifier).
   - AWAIT: complete if E ∧ κ ≥ lo. Otherwise fire `early` if E ∧ κ < lo and an early check exists. Otherwise fire `chk` if ¬E ∧ κ ≥ hi.
   - AWAIT_IDLE: complete if E.
   - HOLD_FOR n: fire `chk` if ¬R; otherwise complete if κ ≥ n.
   - HOLD_UNTIL: complete if E ∧ κ ≥ lo (R is not required at completion). Otherwise fire `early` if E ∧ κ < lo with an early check. Otherwise fire `chk` if ¬R. Otherwise fire `chk` if κ ≥ hi.
   - SKIP n: complete if κ ≥ n.
   - TAKE_TX and TAKE_RX: like AWAIT with E = the lane's pop or push event. On completion the event's data byte goes into register byte `tsel`.
4. **Completion bundle**, in order:
   - mark;
   - sample: `reg[b]` ← predicate;
   - match: requires a push event in this step with data = `reg[7:0]`, else fire `mat.chk`;
   - expect: predicate false fires `exp.chk`;
   - successor: `pc` ← `alt` if `bp` holds, else `next`;
   - `k` ← 0.

   If the successor is STOP, the unit stops silently.
5. **Firing** records (role, code, cycle) in the verdict and stops the unit. If several units fire in the same cycle, the one with the lowest index (lane 0 before lane 1, then unit index) provides the first cause of each role **[choice]**.

## 6. Verdict block and blame release

- **State.** Sticky `fail_flag` and `blame_flag`; first-fail and first-blame cause codes (8 bits) with 32-bit cycle timestamps; and the lane attribution of the first blame.
- **Clearing.** The verdict is cleared by CTRL.CLR_VERDICT.
- **Blame release (ISA section 3, decision V1).** A blame fired by a unit of lane L asserts `blame_in` of lane L in that cycle.

## 7. Loadable store and fetch

- **Store.** One RM_IHPSG13_1P_256x16_c2_bm_bist with 256 words. A program is a header plus instructions, at 6 words per instruction.
- **Unit side.** Each loadable-capable unit has an 82-bit instruction register (IR) and a fetch state. After a completion that changes `pc`, the unit requests the 6 words of the new instruction. A single arbiter serves requests in fixed order, one SRAM read per cycle with 1-cycle latency.
- **Minimum divisor [choice].** A package that uses loadable units may be started only if P ≥ 6·u + 1, where u is the number of its units running from the loadable store (u ≤ 2 per lane, so P ≥ 13 for one lane). If both lanes use loadable units, P ≥ 25 on each. This guarantees that the IR holds the new instruction before the next step. The loader refuses RUN otherwise (FLAGS bit 4, interface v1.1).
- **Proof obligation (V6).** In every step of a loadable unit, IR = store[pc] (fetch lemma, as L1 for the lane). The engine datapath equals the ISA model for any instruction (as L2).

## 8. Host interface (interface v1.1, registers 0x40-0x7F) [choice]

| addr | name | access | content |
|---|---|---|---|
| 0x40 | VERDICT | R | bit0 fail, bit1 blame, bit2 first-blame lane |
| 0x41, 0x42 | FIRST_FAIL, FIRST_BLAME | R | cause codes |
| 0x44-0x47 | FAIL_TIME | R | 32-bit cycle count, LSB first |
| 0x48-0x4B | BLAME_TIME | R | 32-bit cycle count |
| 0x50 + 8L | PKG | R/W while lane L halted | bit7 enable, [3:0] ROM package index |
| +1 | LOAD_UNITS | R/W | bit0/1: units 6/7 of lane L run from the loadable store |
| +2 | LOAD_BASE6, LOAD_BASE7 | R/W | loadable header word address >> 2 (+2 and +3) |
| 0x60 + 16L .. | REMAP | R/W while halted | 16 bytes: local observable i → global source [5:0] |
| 0x7C | LSTORE_ADDR | W | loadable store word address (auto-increment) |
| 0x7D | LSTORE_DATA | W, P | low byte, then high byte of a 16-bit word |

Per C9, the theorem of a package covers exactly the ROM index, remap, loadable contents and P with which it was proved.
