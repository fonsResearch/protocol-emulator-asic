# Freeze run on the frozen tree (plan step 12, 2026-11-11)

Tree: branch v2-inc5-usb after the step-11 commits (design sources as at core commit d9d97d2; the
only design-source change since then is the mutation-campaign hooks, which default to off).

## 1. Freeze identity

| check | result |
|---|---|
| core re-emitted from the current sources (PEMU_LIB=v2inc5 PEMU_LOADABLE=rom PEMU_SLOTS=5 PEMU_VPIPE=1 PEMU_PWIN=1 PEMU_LPIPE=1, then `tools/fix_combdly.py`) vs committed `src/pemu_core_v1m.v` | byte-identical (sha256 c43403cc3a96f4e153242f6774c809bf47b44b4465e78921eb14004a5dd2946e) |
| `src/*.v` since d9d97d2 | unchanged (`git diff --stat` empty) |
| gate-level netlist used below vs the sign-off netlist of CI run 42426292730 | sha256 b450fe7c24d63d1107968b43c271f7826458913ce80c18aab3c588620c75abb0, equal |

Hence the logged results that depend only on the netlist or on the emitted Verilog apply
unchanged to the frozen tree: E4/E5 equivalence, timing sign-off, precheck, and the mutation
campaign, which ran on this RTL with the hooks off (log/campaign_v2.md). These were not re-run
(user decision 2026-11-11).

## 2. `tools/reproduce.sh` tiers

| tier | steps | result | wall |
|---|---|---|---|
| quick | build, all expect tests, toolchain CLIs, host assets, freeze_verilog, MicroPython | 8/8 PASS | about 2 min |
| sim | demo board 17 scenarios, host package 11, 1-Wire 3, on RTL and on the sign-off netlist; verdicts vs committed records; RTL = GL | 21/21 PASS (MicroPython step skipped in this run only: not on PATH; it passed in quick) | 18 min |
| proofs, R1 | r1v2p_s5_u0..u4, u4_t5 (k-induction) PASS 2-4 s each; negatives u4_t4_neg FAIL depth 6, u3_smask_neg FAIL depth 5, replay ok | PASS | under 1 min |
| proofs, A2 sample | see section 3 | 7/7 as expected | 15 min |
| witness | not run in this pass | - | - |

## 3. A2 re-run on the frozen tree (sample)

The A2 part of the proofs tier was stopped after the UART packages (user decision 2026-11-11);
the other package results are cited from their logs (log/protocols_v1.md, log/increments_v2.md),
justified by section 1 and by the A2 inputs. The lane spec, contract library and compiler are
unchanged. In `formal/src/ag_pkg.ml` the U and N1 logic is unchanged since the USB runs
(75b0127); later commits add the Cover mode, a `free_chip` option that is off by default, and new
harnesses.

| harness | expected | result | depth | wall s (this run) | logged wall s |
|---|---|---|---|---|---|
| a2_uart_rx_d8_u | PASS | PASS (dprove) | | 665 | 681 |
| a2_uart_rx_d8_n1_cover_neg | FAIL | FAIL, replay ok | 80 | 47 | |
| a2_uart_rx_d8_late_neg | FAIL | FAIL, replay ok | 81 | 169 | |
| a2_uart_rx_d8_noassume_neg | FAIL | FAIL, dprove cex replayed (bad at frame 158) | 158 | 19 | |
| a2_uart_tx_d4_u | PASS | PASS (dprove) | | 9 | 9 |
| a2_uart_tx_d4_n1_cover_neg | FAIL | FAIL, replay ok | 3 | 0 | |
| a2_uart_tx_d4_badstart_neg | FAIL | FAIL, replay ok | 10 | 0 | |

## 4. Script fix found by this run

The A2 regex of the proofs tier also matched `a2_usb_g7`, which is bounded by design (dprove
times out; log/protocols_v1.md). That harness is expected to PASS, so it would have produced a
mismatch, and the tier could never pass. Fixed: the default set is the 21 harnesses with an
unbounded expectation (G7 negatives kept), and `A2_FILTER=<regex>` re-runs a subset. Validated
with `A2_FILTER='^a2_uart_tx_d4' tools/reproduce.sh proofs`: 0 failed steps.
