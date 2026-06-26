//-------------------------------------------------------------------
// pll_50m_bypass.v — PLL bypass for iverilog simulation
//
// Bypasses the Xilinx MMCM PLL, passing inclk0 to all outputs
// with zero delay. locked asserted after startup period.
//-------------------------------------------------------------------

module pll_50m (
    input  inclk0,
    output c0,
    output c1,
    output c2,
    output locked
);

  assign c0 = inclk0;
  assign c1 = inclk0;
  assign c2 = inclk0;

  reg       locked_r;
  reg [7:0] startup_cnt;

  initial begin
    locked_r    = 1'b0;
    startup_cnt = 8'd0;
  end

  always @(posedge inclk0) begin
    if (!locked_r) begin
      if (startup_cnt < 8'd200)
        startup_cnt <= startup_cnt + 1;
      else
        locked_r <= 1'b1;
    end
  end

  assign locked = locked_r;

endmodule
