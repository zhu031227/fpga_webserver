// sgmii2mac_sync_block_ex — multi-stage synchronization flip-flops
// Adapted from AMD example design: FD primitives → standard Verilog
// for cross-simulator compatibility (Verilator, Vivado XSIM, etc.)

`timescale 1ps / 1ps

module sgmii2mac_sync_block_ex #(
    parameter INITIALISE = 2'b00
) (
    input  clk,
    input  data_in,
    output data_out
);

  reg data_sync1;
  reg data_sync2;
  reg data_sync3;
  reg data_sync4;
  reg data_sync5;
  reg data_sync6;

  // NOTE: missing vendor-specific FD primitives → use standard always blocks.
  // Vivado still infers ASYNC_REG from the shift-register pattern.

  always @(posedge clk) begin
    data_sync1 <= data_in;
    data_sync2 <= data_sync1;
    data_sync3 <= data_sync2;
    data_sync4 <= data_sync3;
    data_sync5 <= data_sync4;
    data_sync6 <= data_sync5;
  end

  assign data_out = data_sync6;
endmodule
