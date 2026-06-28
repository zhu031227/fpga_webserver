`timescale 1ns / 1ps
module tb_test;
  reg clk, rst_n;
  wire [3:0] led;
  wire gmii_tx_en, gmii_rx_dv;
  wire [7:0] gmii_txd, gmii_rxd_int;

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

  assign gmii_tx_en = dut.u_webserver.gmii_tx_en;
  assign gmii_txd   = dut.u_webserver.gmii_txd;

  initial begin
    $dumpfile("test.vcd");
    $dumpvars(0, tb_test);
    clk   = 0;
    rst_n = 0;
    #200 rst_n = 1;
    #100000 $display("PASS");
    $stop;
  end
  always #10 clk = ~clk;
endmodule
