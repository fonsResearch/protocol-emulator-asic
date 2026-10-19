# Plan step 7 report: protocol packages with unconditional A2 (2026-10-19)

Detailed rows, traces and methods: `log/protocols_v1.md`. Defects: `log/disagreements.md`
(D2-D12). Everything below is measured unless marked [estimate].

## 1. Claim per package

A2 for a package = firmware + guarantee contract + assumption contract on the netlist of the
lane and monitor engine, ticks free (so for every prescaler value P):
- **U:** no fail fires unless a blame has fired in the same or an earlier cycle;
- **N1:** a guarantee event is reachable with no fail and no blame (non-vacuity witness, replayed);
- **negatives:** mutants and assumption-free contracts FAIL, witness replayed in cyclesim.

## 2. Status

| package (ROM library) | U | N1 / negatives | other proofs | status |
|---|---|---|---|---|
| UART TX d4 | PASS (dprove, 9 s) | FAIL as expected, replay ok | | **unbounded**, certified (rIC3 + Certifaiger) |
| UART RX d8 m2 | PASS (dprove, 681 s) | FAIL, replay ok; noassume: directed witness (BMC timeout) | sigrok oracle | **unbounded** |
| SPI controller m0-m3 | PASS x 4 (dprove, 59-77 s) | FAIL, replay ok | sigrok oracle | **unbounded** |
| SPI target m0, m2, m3 | PASS (dprove, 279-1,438 s) | FAIL, replay ok | | **unbounded** |
| SPI target m1 | dprove TIMEOUT 3,601 s | | CPOL symmetry lemma m3 to m1 (ind k=4, PASS) | **unbounded** via lemma |
| I2C controller Fm / Sm | bmc3 77 / 76 frames, no violation | N1 FAIL@172, h2 / nowired negatives FAIL | invariant mining did not converge | **bounded** (user decision); does not cover one transaction |
| I2C target Fm / Sm | with EA1: co-sim 7.68M cycles each, 0 bad; checkpoint BMC 78 windows to 40 frames | N1, noack, stretchhigh FAIL with EA1, replay ok | | **bounded**, and conditional on EA1 |
| USB-LS TX | PASS (dprove, 1,246 s) | N1, sync, nopush FAIL, replay ok | G7 contents: co-sim 15.36M cycles, 48 checkpoint windows (24-35 frames), 0 bad; rIC3 stopped at ~1,800 s | U **unbounded**; contents **bounded** |

Interface (`formal/src/top_props.ml`): `run_after_reset_k33` PASS, tight (k34 FAILs at frame
33): no lane runs within 33 cycles of reset release, for any host behaviour. This closes the
SPI-target start-up note (needs 3).

## 3. Assumptions the theorems rest on

- Host-stream harness constraints: RX FIFO never full (all packages); SPI target and I2C target
  config byte present at start (POP at pc 2 never meets an empty TX FIFO).
- **EA1 (I2C target only, unmonitored):** environment SDA changes while SCL is high are at
  least hd steps apart, and the environment releases SCL/SDA until the lane has popped its
  config byte. EA1 is a harness assumption, not a monitored contract (user decision, D12 fix
  option 4), so the I2C target theorem is not unconditional. On 512 clean traces EA1 excludes
  only 38, all target restarts on a busy bus.
- Physical assumptions (PH1-PH*, `doc/concept/assume_guarantee.md`), including static timing,
  which is plan step 8.

## 4. Defects found by the method in step 7

D2-D12 (11 entries): contract/protocol mismatches found by co-simulation (D2, D4-D7), firmware
timing against ISA v1 before writing firmware (D3), and by A2 formal runs (D8-D12; D12 =
I2C conditions one step apart plus a level-detected START missed by the frame watcher). The
USB CRC mutant (`a2_usb_u_sendc`) passes the on-chip contract and is caught only by the
proof-side G7 check, as designed (contents are a [P] property).

## 5. Contract language v1 limits found

- predicates have at most 3 literals;
- `elapsed` can only be ANDed (lower bounds only; an upper bound needs a window entry);
- a guard handler must start with a consuming statement;
- one guard per watcher, no nested guards.
The I2C contracts use the full budget (14/14 predicates, 7/7 windows, 14/15 codes).

## 6. Area (Yosys 0.69 + ABC, no wire load, SRAM macros excluded; `flow/map/map_v1m.sh`)

| ROM library | words | typ um2 | slow um2 | slow logic depth |
|---|---|---|---|---|
| 2 x UART TX (step 6) | 28 | 353,835 | 374,951 | 10.99 ns |
| 10 packages | 646 | 395,717 | 417,200 | 10.64 ns |
| **15 packages (this step)** | 1,173 | **449,671** | 471,786 | 10.66 ns |

- +371 flops from lib10 to 15 packages: lane-0 mark/history register bits that synthesis had
  pruned for lib10 become live with the I2C packages; about 18k um2 [estimate, flop cells only].
- Fit [estimate]: 89 % of the ~503k um2 8x4 budget (60 % density, 1.34x Yosys-to-route
  growth from one published IHP tile, not measured here). The first real number is the TT
  flow in plan step 8.
- The default emitted build (`top_macro_mon`) still carries the 2-package test library; which
  library ships is open (section 7).

## 7. Open items

1. Which ROM library goes into the step-8 build (all 15, or a subset) - a user decision.
2. I2C controller U and both I2C targets: bounded only; I2C target additionally rests on EA1.
3. USB G7 (contents): bounded only. Clean-traffic status-1 pushes (N <= 8 always generated)
   are unexplained; TX-FIFO overflow at short push gaps is suspected, not checked.
4. USB facts marked "(memory)" in `doc/protocols/usb_ls_v1.md` (DATA0/DATA1 values, LS 8-byte
   limit, CRC16 transmission details) and the abort form (no LS transmitter-abort rule found)
   need review against the USB 2.0 text.
5. V5 certification: only UART TX is certified; a2_usb_u (PDR invariant 8,876 clauses) is the
   next candidate.
6. Step-8 risks carried over: fetch path <= 12.95 ns slow vs 16.67 ns, A_ADDR hold (up to
   0.85 ns), power grid for the 256x16 bm_bist macro, A_DOUT max-cap, rename away from "PEMU".
