// Replay vectors.hex into the core and compare against expected.hex every cycle.
// Outputs are Moore (registered), so they are compared before each rising edge.
`timescale 1ns/10ps
`ifndef TOP
`define TOP pemu_core
`endif
module tb_vectors;
  localparam MAXC = 16384;
  reg [19:0] vec [0:MAXC-1];
  reg [23:0] exp [0:MAXC-1];
  reg clock = 0;
  reg rst_sync_n = 0;
  reg [7:0] ui_in = 0, uio_in = 0;
  wire [7:0] uo_out, uio_out, uio_oe;
  integer n, c, errors;

  `TOP dut (.clock(clock), .rst_sync_n(rst_sync_n), .ui_in(ui_in), .uio_in(uio_in),
            .uo_out(uo_out), .uio_out(uio_out), .uio_oe(uio_oe));

  initial begin
    for (n = 0; n < MAXC; n = n + 1) vec[n] = 20'hxxxxx;
    $readmemh("vectors.hex", vec);
    $readmemh("expected.hex", exp);
    n = 0; while (n < MAXC && vec[n] !== 20'hxxxxx) n = n + 1;
    errors = 0;
    for (c = 0; c < n; c = c + 1) begin
      {rst_sync_n, ui_in, uio_in} = vec[c][16:0];
      #5;
      // Reset is a synchronous clear: before the first clock edge with rst_sync_n low the
      // registers (and so the pins) are undefined. Only cycle 0 is exempt; every later cycle
      // must match exactly, including X checks (!==).
      if (c > 0 && {uio_oe, uio_out, uo_out} !== exp[c]) begin
        errors = errors + 1;
        if (errors <= 5) $display("MISMATCH cycle %0d: got %h expected %h", c, {uio_oe, uio_out, uo_out}, exp[c]);
      end
      clock = 1; #5; clock = 0;
    end
    $display("RESULT top=%m cycles=%0d errors=%0d", n, errors);
    $finish;
  end
endmodule
