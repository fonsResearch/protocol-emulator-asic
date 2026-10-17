# Contract language v0

Status: DRAFT v0 (2026-10-17), for review. Companion documents: `doc/concept/assume_guarantee.md` (why) and `doc/contracts/contracts_v0.md` (paper contracts for UART, SPI and I2C, written against this draft to test expressiveness).

## 1. Design constraints

The language must be all of the following at once:

1. **Deterministic.** A contract denotes one sequential machine; no nondeterministic choice. It then compiles directly to a monitor-engine program and to a circuit for the proof harness.
2. **Bounded work per cycle.** Each watcher does a compile-time-bounded amount of work per clock, so the engine can run it at speed.
3. **Finite state.** Counters and registers have declared widths; windows are bounded except in an explicit `idle` wait.
4. **Exact.** Semantics are defined per clock cycle on the same observations the driver lanes see (`doc/interface.md`), so the offline monitor and the on-chip monitor are the same object.

## 2. Observation model

Cycles are numbered as in `doc/isa/isa_v0.md` section 1. A monitor observes, in each cycle c:

| observable | declared as | value in cycle c | notes |
|---|---|---|---|
| chip output | `out x = uo[k]` (or `uio[k]` driven) | the value the chip drives during c | cycle-exact; no latency |
| chip output enable | part of `io x = uio[k]` | `x.oe` during c | |
| synchronised input | `in x = ui[k]` or `uio[k]` | pad value sampled at edge e_{c-1} (`s2`), as in `doc/interface.md` section 3 | latency Λ = 2 cycles relative to the pad |
| open-drain line | `od x = uio[k]` | `x.drive` = 1 when the chip pulls low (oe = 1, out = 0); `x.line` = synchronised pad level | `x.line` lags `x.drive` by Λ |
| push-pull bidirectional | `io x = uio[k]` | `x.out`, `x.oe`, `x.in` | |
| host write stream | `stream s : host_write(ch, w)` | `s.pending` (unconsumed element exists), `s.write` (event this cycle) | elements are w-bit values written at the host port, in order |
| host read stream | `stream s : host_read(ch, w)` | `s.push` (chip made an element available this cycle), `s.last` (that element) | |

Streams tap the host interface, never lane-internal state.

Derived per-cycle predicates for any 1-bit observable x: `rise x`, `fall x`, `changed x`, `stable x`. These compare cycle c with cycle c-1. At the first observed cycle, `changed x` is false.

**Pad-time uncertainty.** A synchronised input that changes value in observed cycle c changed on the pad in the interval (e_{c-2}, e_{c-1}]. Its pad time is known to within one cycle, offset by Λ. A chip output that changes in cycle c changed on the pad just after e_c, plus pad delay (PH4, a stated assumption). Section 6 says how windows are converted.

## 3. Syntax (text form: the printed view of the OCaml DSL, per Q1)

```
contract   ::= 'contract' NAME 'clock' HZ decl* watcher* 'end'
decl       ::= pin | param | stream | reg | let
pin        ::= ('out'|'in'|'od'|'io') NAME '=' PIN
param      ::= 'param' NAME '=' NUMBER UNIT            UNIT ::= 'ns' | 'us' | 'cycles'
             | 'param' NAME '=' 'policy' NUMBER UNIT    -- not from the standard; see 7
stream     ::= 'stream' NAME ':' ('host_write'|'host_read') '(' CH ',' W ')'
reg        ::= 'reg' NAME '[' W ']'                      -- watcher-local data register
let        ::= 'let' NAME '=' B                         -- named boolean over observables (macro)
watcher    ::= 'watcher' NAME 'base' CODE '{' reg* stmt* '}'

stmt       ::= consuming | instant | control
consuming  ::= 'await' E window
             | 'hold' B 'for' N check
             | 'hold' B 'until' E window
             | 'skip' N
instant    ::= 'expect' B check
             | 'take' NAME '<-' STREAM check            -- requires STREAM.pending
             | 'sample' NAME '[' IDX ']' '<-' B
             | 'match' NAME '==' STREAM '.last' check   -- compare with the element just pushed
             | 'mark' ANCHOR
             | 'raise' role CODE
control    ::= 'loop' '{' stmt* '}'
             | 'repeat' N '{' stmt* '}'
             | 'for' I 'in' N '..' N '{' stmt* '}'      -- unrolled at compile time
             | 'if' B '{' stmt* '}' ('else' '{' stmt* '}')?
window     ::= 'within' '[' T ',' T ']' ('since' ANCHOR)? check ('early' check)?
             | 'idle'                                   -- unbounded wait, never fires
check      ::= 'else' role CODE
role       ::= 'fail' | 'blame'
E, B       ::= boolean over current-cycle observables, derived predicates, constants,
               register bits NAME[IDX], 'elapsed' '(' ANCHOR ')' ('>='|'<=') T, and ! && ||
T, N       ::= integer cycles, or a param name (converted per section 6)
```

## 4. Semantics (per watcher, per cycle)

Each watcher holds:
- a program counter;
- an **anchor**: the last cycle consumed;
- up to K named anchors from `mark`;
- its registers;
- a status of `run` or `stopped`.

Watchers run in parallel. All read the same cycle-c observations.

### 4.1 Consuming statements

A consuming statement occupies one or more cycles after the current anchor. When it completes at cycle t, the anchor becomes t, and the next statement starts at cycle t+1.

- `await E within [lo, hi] else r C`: completes at the first cycle t > anchor with E true and t - anchor in [lo, hi].
  - If E becomes true with t - anchor < lo: with `early r' C'` that check fires; without it, the early occurrence is ignored and the wait continues.
  - If cycle anchor + hi passes with no completion, check `r C` fires.
  - `since a` measures from anchor `a` instead of the current anchor.
- `await E idle`: completes at the first t > anchor with E true. It never fires.
- `hold B for n else r C`: cycles anchor+1 .. anchor+n must all satisfy B. It fires at the first cycle that does not, and completes at anchor+n.
- `hold B until E within [lo, hi] else r C`: B must hold on every cycle until the first cycle t where E is true, and t - anchor must lie in [lo, hi]. It completes at t. B is not required at t.
- `skip n`: completes at anchor+n with no check.

### 4.2 Instant statements

Instant statements evaluate on the anchor cycle (the last consumed cycle) and do not advance it:

- `expect B`: checks B.
- `take v <- s`: pops the next element of s into v. Fires if `s.pending` is false.
- `sample v[i] <- B`: stores B in bit i of v.
- `match v == s.last`: requires `s.push` on the anchor cycle and compares the values. It fires if either fails.
- `mark a`: sets anchor a to the anchor cycle.
- `raise r C`: fires unconditionally.

At most K_chain instant statements may follow a consuming statement before the next one; the compiler checks this bound.

### 4.3 Control

- `loop` and `repeat` bodies must contain at least one consuming statement, so no zero-time loops.
- `if B` evaluates B on the anchor cycle.
- `for` is unrolled.

### 4.4 Firing

When a check `r C` fires in cycle c:
1. The watcher records (role r, code base+C, cycle c) in the verdict block and stops. A stopped watcher stays stopped until reset.
2. The verdict block is sticky:
   - `fail_flag`, `blame_flag`;
   - the first event of each role (code and cycle);
   - if both roles fire in the same cycle, both are recorded.

### 4.5 Reset

Reset release restarts every watcher at its first statement, with anchor = the cycle before the first observed cycle.

## 5. Roles and well-formedness

1. **WF1.** A `fail` check may constrain only chip-driven observables (`out`, `x.oe`, `x.out`, `x.drive`) and host-read streams. Environment observables may appear in its window events and conditions, as anchors, but not as the thing being required.
2. **WF2.** A `blame` check may constrain only environment-driven observables: synchronised inputs, `x.line`, `x.in`, and host-write streams. The host is part of the environment.
3. **WF3.** Codes are unique per contract. The cause code identifies the watcher and the check.
4. **WF4.** `idle` waits appear only where the protocol permits an unbounded wait. This is reviewed by hand and listed per contract.
5. **WF5.** No register is read before it is written on every path (compile-time check).

WF1 and WF2 are what make `F -> B` meaningful. Without them, a guarantee could be expressed as an assumption, or the reverse.

## 6. Time conversion (ns to cycles)

Parameters given in ns or µs are converted for the declared clock f (PH3). Rounding is chosen so that each role errs on the safe side:

| bound | in a `fail` check (strict) | in a `blame` check (lenient) |
|---|---|---|
| lower bound L | ceil(L·f) | floor(L·f) |
| upper bound U | floor(U·f) | ceil(U·f) |

Intervals between a chip output event and an observed input event additionally carry the pad-time uncertainty of section 2:
- `fail` windows are narrowed by 1 cycle and shifted by Λ;
- `blame` windows are widened by 1 cycle and shifted by Λ.

Intervals between two observed inputs need no Λ shift, since both are delayed equally. Pad delay (PH4) is not modelled. The compiler applies these rules from the declared kinds of the observables in each window, and they are tested separately.

## 7. Policy parameters

Some protocols allow unbounded waits: I2C clock stretching, UART idle, SPI chip-select idle. Where the chip must still make progress, the contract bounds the wait with a parameter marked `policy`, and exceeding it is a `blame`. Policy parameters are not claims about the standard. The write-up lists them per package, for example an I2C stretch timeout, which is not in UM10204.

## 8. Engine budget (parameters to be fixed by the spike and the architecture gate)

| parameter | meaning | first guess [E] |
|---|---|---|
| N_w | concurrent watchers per monitor engine | 4-8 |
| W | window counter width | 12 bits, plus a prescaled timer for policy timeouts |
| K | named anchors per watcher | 2 |
| R | register bits per watcher | 16 |
| K_chain | instant statements per cycle | 4 |
| L_prog | monitor program length | 64-128 instructions |

## 9. Open questions for review

1. **Q1, surface syntax. RESOLVED 2026-10-17 (user): (b)**, an OCaml embedded DSL is the source of truth, and the text form in section 3 is a pretty-printed view. Other options considered: (a) a parsed text form; (c) both.
2. **Q2, form of guarantees. RESOLVED 2026-10-17 (user): (c), both.** The exact form is an implementation property. The tolerance form (receiver-equivalent sampling for UART, min/max windows for SPI and I2C) is the standard-faithful G used for N3. Other options considered: (a) tolerance only; (b) exact only.
3. **Q3, blame response.** Report only, or also enforce: release the pins and stop the lane on a `blame`. Enforcement changes guarantees after a blame, so it has to be specified.
4. **Q4, multi-controller I2C.** Is arbitration loss a `blame` (single-controller packages only), or a guarded branch in which the chip has a guarantee to release the bus within k cycles?
5. **Q5, on-chip guarantee monitors.** Always loaded alongside A when engine capacity allows, or optional per package.
