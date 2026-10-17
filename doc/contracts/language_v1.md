# Contract language v1 (changes from v0)

Status: FROZEN v1 (2026-10-17); approval delegated by the user to the agent. Base document: `doc/contracts/language_v0.md`. Everything not changed here stays as in v0. Choices made in this draft are marked **[choice]**.

## C1. Time unit: steps of a lane (decision G1)

- Every watcher declares a time base: `ticks L0`, `ticks L1` or `cycles`.
- A watcher on `ticks L` evaluates only in steps of lane L: cycles where L's tick is 1 (ISA section 1). Its windows count steps, and edge predicates compare consecutive steps.
- Package contracts use their lane's ticks. Only the built-in `host_spi` contract uses `cycles`.
- Consequence (proved in the tick spike for UART TX): a package's U and N1 are proved once with the tick free, and hold for every divisor P.
- Real time is recovered by the prescaler lemma: consecutive steps are exactly P+1 cycles apart.

## C2. Conditions versus requirements (spike finding 4)

- New form: `require R when C`. It applies inside hold, await and expect; the plain forms are `require R when true`.
- WF1/WF2 apply only to the requirement R. The condition C may read any observable.
- Example (SPI target): `hold require !miso.oe when cs_n@1 for n else fail 1`. While the delayed select input is high (deselected), MISO must be released. The condition is an input, the requirement a chip output.

## C3. Delayed observables (contracts_v0 gap)

`x@k`, for k in 1..3, is the value of observable x k steps earlier (0 before the watcher has seen k steps). It costs k flops per used observable.

## C4. Guarded branch (decision V2, I2C arbitration)

```
guard E { body } on { handler }
```

- `body` runs as usual.
- In any step where E holds (evaluated before the body's statement for that step), the body is abandoned and `handler` runs from the next step.
- One level of guard per watcher [choice]. The handler may not contain another guard.
- I2C use:
  - guard E = "we released SDA (`!sda.drive`) and the line is low (`!sda.line@k`) while SCL is high";
  - handler = `await !sda.drive && !scl.drive within [1, k_release] else fail ...` (release both lines in time), then report via the arbitration stream.

## C5. Streams bound to lane FIFOs [choice]

- `stream s : tx_pop(L)` yields the bytes lane L pops from its host TX FIFO, in order, with a `pop` event.
- `stream s : rx_push(L)` yields the bytes it pushes to its RX FIFO, with a `push` event.
- FIFO order and contents equal the host's writes and reads by the ISA and interface semantics, which A1 covers. The monitor taps the FIFO ports, not lane registers.
- `take v <- s` waits for the next pop and is a `fail` check if none occurs within its window. `match v == s.last` as in v0.

## C6. Registers, mark/elapsed, sample/match

These were specified in v0 and are now required. They were not implemented in the spike.

## C7. Time conversion

- Windows are written in steps. Where a package states a standard's bound in ns, the conversion depends on the clock (60 MHz) and the package's declared divisor P: steps = ns x f / (P+1), with v0 section 6's strict/lenient rounding by role.
- The synchroniser offset (Λ = 2 cycles) becomes ceil(2/(P+1)) steps of uncertainty for output-to-input intervals.
- A package's N2 tests run at its declared P.

## C8. Engine encoding

To be fixed at plan step 6:
- compressed instructions (G2): windows and codes through small per-watcher tables; contract-local observable indices with a per-watcher remap table (makes ROM contracts relocatable to the owned pins);
- the per-package parameter table;
- the lane attribution bit for blame release (V1).

## C9. Proof scope (from interface section 7)

A package's theorem covers the exact monitor programs, remap tables and parameter values it was proved with.
