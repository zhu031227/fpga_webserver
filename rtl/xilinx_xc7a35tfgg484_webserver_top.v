// xilinx_xc7a35tfgg484_webserver_top — xilinx artix-7 fpga webserver top module
//
// target: xc7a35t-fgg484-2
// phy interface: rgmii (converted to internal gmii via rgmii2gmii)
// clock: 50 mhz input → mmcm pll → 50 / 125 / 200 mhz
//
// platform-specific:
//   - xilinx mmcm pll (pll_50m)
//   - rgmii2gmii for rgmii-to-gmii conversion
//   - idelay/oddr primitives for rgmii ddr i/o

module xilinx_xc7a35tfgg484_webserver_top #(
    parameter int sim_mod = 0,
    parameter int xilinx_idelay_value = 16
) (
    input clk_50m_in,
    input reset_l,

    input  uart_rx,
    output uart_tx,

    // rgmii interface
    output       rgmii_reset_l,
    input        rgmii_rxc,
    input        rgmii_rx_ctl,
    input  [3:0] rgmii_rxd,
    output       rgmii_txc,
    output       rgmii_tx_ctl,
    output [3:0] rgmii_txd,

    // mdio
    output eth0_mdc,
    inout  eth0_mdio,

    output [3:0] led_o
);

  localparam string device_vendor = (sim_mod == 0) ? "AMD" : "";

  // --- reset synchronizer (async assert, sync deassert) ---
  wire       reset_l_synced;

  // --- pll clocks ---
  wire       clk_50m;
  wire       clk_125m;
  wire       clk_200m;
  wire       pll_locked;

  // --- rgmii to gmii conversion ---
  wire       gmii_rx_clk;
  wire       gmii_rx_dv;
  wire [7:0] gmii_rxd;
  wire       gmii_tx_en;
  wire [7:0] gmii_txd;

  // PLL lock-gated reset controller
  clk_rst_ctrl #(
      .NUM_LOCK_INPUTS(1)
  ) u_clk_rst_ctrl (
      .clk        (clk_50m_in),
      .async_rst_l(reset_l),
      .pll_locked (pll_locked),
      .rst_l      (reset_l_synced)
  );

  generate
    if (sim_mod == 1 || device_vendor == "") begin : g_clk_bypass
      assign clk_50m = clk_50m_in;
      assign clk_125m = clk_50m_in;
      assign clk_200m = clk_50m_in;
      assign pll_locked = 1'b1;
    end else begin : g_clk_pll
      pll_50m u_pll (
          .inclk0(clk_50m_in),
          .c0    (clk_50m),
          .c1    (clk_125m),
          .c2    (clk_200m),
          .locked(pll_locked)
      );
    end
  endgenerate

  rgmii2gmii #(
      .xilinx_idelay_value(xilinx_idelay_value),
      .vendor(device_vendor)
  ) u_rgmii2gmii (
      .reset_l (reset_l_synced),
      .clk_200m(clk_200m),

      .gmii_rx_clk(gmii_rx_clk),
      .gmii_rx_dv (gmii_rx_dv),
      .gmii_rxd   (gmii_rxd),

      .gmii_tx_clk(clk_125m),
      .gmii_tx_en (gmii_tx_en),
      .gmii_txd   (gmii_txd),

      .rgmii_rxc   (rgmii_rxc),
      .rgmii_rx_ctl(rgmii_rx_ctl),
      .rgmii_rxd   (rgmii_rxd),
      .rgmii_txc   (rgmii_txc),
      .rgmii_tx_ctl(rgmii_tx_ctl),
      .rgmii_txd   (rgmii_txd)
  );

  assign rgmii_reset_l = reset_l_synced;

  // --- webserver core wrapper ---
  webserver_wrapper #(
      .lcpu_inst_en(1),
      .pll_bypass  (sim_mod == 1)
  ) u_webserver (
      .clk          (clk_50m_in),
      .reset_l      (reset_l_synced),
      .clk_50mhz_in (clk_50m),
      .clk_125mhz_in(clk_125m),
      .clk_200mhz_in(clk_200m),

      .uart_rx(uart_rx),
      .uart_tx(uart_tx),

      .eth0_mdc (eth0_mdc),
      .eth0_mdio(eth0_mdio),

      // internal gmii (from rgmii2gmii)
      .gmii_rx_clk(gmii_rx_clk),
      .gmii_rx_dv (gmii_rx_dv),
      .gmii_rx_err(1'b0),
      .gmii_rxd   (gmii_rxd),

      .gmii_txd   (gmii_txd),
      .gmii_tx_en (gmii_tx_en),
      .gmii_tx_err(),

      .led(led_o)
  );
endmodule
