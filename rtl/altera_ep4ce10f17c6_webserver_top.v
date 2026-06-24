// altera_ep4ce10f17c6_webserver_top — altera cyclone iv e fpga webserver top module
//
// target: ep4ce10f17c6
// phy interface: gmii (direct 8-bit sdr, no rgmii conversion needed)
// clock: 50 mhz input → pll → 50 / 125 / 200 mhz
//
// platform-specific:
//   - altera pll (pll_50m)
//   - gmii signals connected directly (no rgmii2gmii)

module altera_ep4ce10f17c6_webserver_top #(
    parameter int sim_mod = 0
) (
    input clk_50m_in,
    input reset_l,

    input  uart_rx,
    output uart_tx,

    // gmii interface (direct)
    output       eth0_greset,
    output       eth0_gtx_clk,
    input        eth0_rxc,
    input        eth0_rxdv,
    input        eth0_rxer,
    input  [7:0] eth0_rxd,
    output [7:0] eth0_txd,
    output       eth0_txen,
    output       eth0_txer,

    // mdio
    output eth0_mdc,
    inout  eth0_mdio,

    output [3:0] led_o
);

  localparam string device_vendor = (sim_mod == 0) ? "Intel" : "";

  // --- reset synchronizer (async assert, sync deassert) ---
  wire       reset_l_synced;

  // --- pll clocks ---
  wire       clk_50m;
  wire       clk_125m;
  wire       clk_200m;
  wire       pll_locked;

  // --- gmii rx register stage ---
  reg        gmii_rx_dv_r;
  reg        gmii_rx_err_r;
  reg  [7:0] gmii_rxd_r;

  // --- gmii tx register stage ---
  reg  [7:0] gmii_txd_r;
  reg        gmii_tx_en_r;
  reg        gmii_tx_err_r;
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

  always @(posedge eth0_rxc) begin
    gmii_rx_dv_r  <= eth0_rxdv;
    gmii_rx_err_r <= eth0_rxer;
    gmii_rxd_r    <= eth0_rxd;
  end

  always @(posedge clk_125m) begin
    eth0_txd  <= gmii_txd_r;
    eth0_txen <= gmii_tx_en_r;
    eth0_txer <= gmii_tx_err_r;
  end

  assign eth0_greset  = reset_l_synced;
  assign eth0_gtx_clk = clk_125m;

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

      // internal gmii (direct from phy, registered)
      .gmii_rx_clk(eth0_rxc),
      .gmii_rx_dv (gmii_rx_dv_r),
      .gmii_rx_err(gmii_rx_err_r),
      .gmii_rxd   (gmii_rxd_r),

      .gmii_txd   (gmii_txd_r),
      .gmii_tx_en (gmii_tx_en_r),
      .gmii_tx_err(gmii_tx_err_r),

      .led(led_o)
  );
endmodule
