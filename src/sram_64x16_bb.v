/*
 * SPDX-License-Identifier: MIT
 *
 * Synthesis black box for the IHP SG13 64x16 single-port SRAM hard macro (no BIST/bit-mask
 * variant). Port list from the PDK LEF/model at IHP-Open-PDK 2bbec755. Excluded from
 * simulation (`SIM`), where the PDK behavioural model (-DFUNCTIONAL) is used instead.
 * Pattern from the organiser-referenced CMOS5L SRAM walkthrough (kdp1965, 2026-09-29).
 */
`ifndef SIM
(* blackbox *)
module RM_IHPSG13_1P_64x16_c2 (
    input  wire        A_CLK,
    input  wire        A_MEN,
    input  wire        A_WEN,
    input  wire        A_REN,
    input  wire  [5:0] A_ADDR,
    input  wire [15:0] A_DIN,
    input  wire        A_DLY,
    output wire [15:0] A_DOUT
);
endmodule
`endif
