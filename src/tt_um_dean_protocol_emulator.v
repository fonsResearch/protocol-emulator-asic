/*
 * Copyright (c) 2026 dean
 * SPDX-License-Identifier: MIT
 *
 * Tiny Tapeout top-level wrapper. Hand-written on purpose so the TT pin
 * contract does not depend on Hardcaml's port naming. It instantiates the
 * Hardcaml-generated core (src/pemu_core_macro.v, IHP-macro variant: instruction
 * memory is one RM_IHPSG13_1P_64x16_c2 instance, core.u_imem; emitted by
 * rtl/bin/generate.exe) and adds only the reset synchroniser. ena is ignored.
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

  pemu_core_macro core (
      .clock     (clk),
      .rst_sync_n(rst_sync_n),
      .ui_in     (ui_in),
      .uio_in    (uio_in),
      .uo_out    (uo_out),
      .uio_out   (uio_out),
      .uio_oe    (uio_oe)
  );

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, 1'b0};

endmodule
