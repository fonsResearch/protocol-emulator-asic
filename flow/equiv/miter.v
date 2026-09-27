// Generic two-core output miter: bad = any output differs. A and B are core module names.
`ifndef CORE_A
`define CORE_A pemu_core
`endif
`ifndef CORE_B
`define CORE_B pemu_core_b
`endif
module eq_miter (input clock, input rst_sync_n, input [7:0] ui_in, input [7:0] uio_in,
                 output bad);
  wire [7:0] ao, aio, aoe, bo, bio, boe;
  `CORE_A a (.clock(clock), .rst_sync_n(rst_sync_n), .ui_in(ui_in), .uio_in(uio_in),
             .uo_out(ao), .uio_out(aio), .uio_oe(aoe));
  `CORE_B b (.clock(clock), .rst_sync_n(rst_sync_n), .ui_in(ui_in), .uio_in(uio_in),
             .uo_out(bo), .uio_out(bio), .uio_oe(boe));
  assign bad = (ao != bo) | (aio != bio) | (aoe != boe);
endmodule
