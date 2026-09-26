// Formal wrapper: turn the Hardcaml observer's [bad] output into an assertion.
module formal_top (input clock);
  wire bad;
  ctr dut (.clock(clock), .bad(bad));
  always @* assert (!bad);
endmodule
