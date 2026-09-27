// Assertion wrapper for the A1 harness (sby cross-check). bad must never be 1.
module a1_wrap(input clock, input rst_sync_n, input [7:0] ui_in, input [7:0] uio_in);
  wire bad;
  a1_miter u (.clock(clock), .rst_sync_n(rst_sync_n), .ui_in(ui_in), .uio_in(uio_in), .bad(bad));
  always @* assert (!bad);
endmodule
