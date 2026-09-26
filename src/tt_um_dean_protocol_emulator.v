/*
 * Copyright (c) 2026 dean
 * SPDX-License-Identifier: MIT
 *
 * Tiny Tapeout top-level wrapper. Hand-written on purpose so the TT pin
 * contract does not depend on Hardcaml's port naming. The Hardcaml-generated
 * core will be instantiated here once it exists. Until then every output is
 * driven to a constant 0 and all pins are inputs.
 *
 * Reset: rst_n is treated as an asynchronous input. rst_sync_n is asserted
 * asynchronously and released synchronously through two flops (reset
 * synchroniser). The flops use async reset-to-0, which maps to sg13cmos5l
 * dfrbp-type cells; no async-set flop is required.
 */
`default_nettype none

module tt_um_dean_protocol_emulator (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // Reset synchroniser: asynchronous assertion, synchronous release.
  reg [1:0] rst_sync;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) rst_sync <= 2'b00;
    else        rst_sync <= {rst_sync[0], 1'b1};
  end
  wire rst_sync_n = rst_sync[1];

  // Core instantiation goes here (Hardcaml-generated). Placeholder outputs:
  assign uo_out  = 8'h00;
  assign uio_out = 8'h00;
  assign uio_oe  = 8'h00;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, ui_in, uio_in, rst_sync_n, 1'b0};

endmodule
