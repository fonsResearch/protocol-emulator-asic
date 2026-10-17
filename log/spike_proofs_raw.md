# Spike proof runs, raw prove_one.sh rows (2026-10-17)

Command: formal/prove_one.sh <harness> <verilog dir> <aig dir> <timeout> <expected>, after emit_formal.exe (formal/src/ag_harness.ml).

## Main run
| harness | expected | engine | result | depth/frames | inputs/latches/ands | wall s | cex replay |
|---|---|---|---|---|---|---|---|
| u_spec_uart_d3 | PASS | dprove | PASS |  | i/o = 18/ 1 lat = 79 and = 1254 | 43 |  |
| n1_spec_uart_d3 | PASS | dprove | PASS |  | i/o = 18/ 1 lat = 80 and = 1255 | 29 |  |
| a1mon_uart_d3 | PASS | dprove | PASS |  | i/o = 42/ 1 lat = 87 and = 1229 | 1 |  |
| u_rtl_uart_d3 | PASS | dprove | PASS |  | i/o = 34/ 1 lat = 107 and = 1240 | 26 |  |
| u_spec_uart_d4 | PASS | dprove | PASS |  | i/o = 18/ 1 lat = 81 and = 1311 | 12 |  |
| n1_spec_uart_d4 | PASS | dprove | PASS |  | i/o = 18/ 1 lat = 82 and = 1312 | 8 |  |
| a1mon_uart_d4 | PASS | dprove | PASS |  | i/o = 42/ 1 lat = 91 and = 1292 | 1 |  |
| u_rtl_uart_d4 | PASS | dprove | PASS |  | i/o = 34/ 1 lat = 109 and = 1275 | 51 |  |
| u_spec_uart_delay1_d4 | PASS | dprove | PASS |  | i/o = 18/ 1 lat = 88 and = 1385 | 34 |  |
| u_spec_uart_delay2_neg_d4 | FAIL | dprove | FAIL | 11 | i/o = 18/ 1 lat = 88 and = 1383 | 0 | replay ok |
| u_spec_uart_noassume_neg_d4 | FAIL | dprove | FAIL | 5 | i/o = 18/ 1 lat = 78 and = 1289 | 0 | replay ok |
| u_spec_uart_badprog_neg_d4 | FAIL | dprove | FAIL | 10 | i/o = 18/ 1 lat = 81 and = 1312 | 0 | replay ok |
| n1_spec_uart_overstrong_neg_d4 | FAIL | dprove | FAIL | 2 | i/o = 18/ 1 lat = 84 and = 1324 | 1 | replay ok |
| a1mon_uart_variant_d4 | PASS | dprove | PASS |  | i/o = 42/ 1 lat = 110 and = 1469 | 0 |  |
| a1mon_window_neg_d4 | FAIL | dprove | PASS |  | i/o = 42/ 1 lat = 91 and = 1292 | 0 |  |
| a1mon_code_neg_d4 | FAIL | dprove | FAIL | 3 | i/o = 42/ 1 lat = 91 and = 1297 | 0 | replay ok |

## A1-mon rerun after moving the planted window bug into every unit (replaces the a1mon rows above)

| a1mon_uart_d3 | PASS | dprove | PASS |  | i/o = 42/ 1 lat = 87 and = 1229 | 1 |  |
| a1mon_uart_d4 | PASS | dprove | PASS |  | i/o = 42/ 1 lat = 91 and = 1292 | 1 |  |
| a1mon_uart_variant_d4 | PASS | dprove | PASS |  | i/o = 42/ 1 lat = 110 and = 1469 | 0 |  |
| a1mon_window_neg_d4 | FAIL | dprove | FAIL | 4 | i/o = 42/ 1 lat = 91 and = 1285 | 0 | replay ok |
| a1mon_code_neg_d4 | FAIL | dprove | FAIL | 3 | i/o = 42/ 1 lat = 91 and = 1297 | 0 | replay ok |

## Scaling (timeout 1800 s)

| u_spec_uart_d6 | PASS | dprove | PASS |  | i/o = 18/ 1 lat = 81 and = 1312 | 6 |  |
| u_rtl_uart_d6 | PASS | dprove | PASS |  | i/o = 34/ 1 lat = 109 and = 1282 | 38 |  |
| u_spec_uart_d8 | PASS | dprove | PASS |  | i/o = 18/ 1 lat = 83 and = 1333 | 315 |  |
| u_rtl_uart_d8 | PASS | dprove | PASS |  | i/o = 34/ 1 lat = 111 and = 1306 | 373 |  |
| u_spec_uart_d12 | PASS | dprove | PASS |  | i/o = 18/ 1 lat = 83 and = 1333 | 533 |  |
| u_spec_uart_d16 | PASS | dprove | PASS |  | i/o = 18/ 1 lat = 85 and = 1366 | 1001 |  |
