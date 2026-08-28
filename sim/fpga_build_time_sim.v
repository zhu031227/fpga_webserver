//-------------------------------------------------------------------
// fpga_build_time_sim.v — Simulation stub for fpga_build_time
//-------------------------------------------------------------------

module fpga_build_time (
    output wire [31:0] build_date,
    output wire [31:0] build_time
);

  assign build_date = 32'h20260625;
  assign build_time = 32'h00000001;
endmodule
