`timescale 1ns / 1ps
module tb_minimal;
  reg clk, rst_n;
  wire [3:0] led;

  sim_top #(
      .sim_mod(1)
  ) dut (
      .clk_50m_in(clk),
      .reset_l(rst_n),
      .uart_rx(1'b1),
      .uart_tx(),
      .eth0_mdc(),
      .eth0_mdio(),
      .rgmii_rxc(clk),
      .rgmii_rx_ctl(1'b0),
      .rgmii_rxd(4'h0),
      .rgmii_txc(),
      .rgmii_tx_ctl(),
      .rgmii_txd(),
      .led(led)
  );

  initial begin
    $dumpfile("test.vcd");
    $dumpvars(0, tb_minimal);
    clk   = 0;
    rst_n = 0;
    #100 rst_n = 1;
    #100000;
    $display("done");
    $stop;
  end
  always #10 clk = ~clk;
endmodule
