// pll_bypass — Simulation PLL bypass module
// Routes input clock directly to all PLL outputs, asserts locked=1
module pll_50m (
    input  inclk0,
    output c0,
    output c1,
    output c2,
    output locked
);
  assign c0     = inclk0;
  assign c1     = inclk0;
  assign c2     = inclk0;
  assign locked = 1'b1;
endmodule
