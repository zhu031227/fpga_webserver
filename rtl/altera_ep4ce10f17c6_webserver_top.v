// altera_ep4ce10f17c6_webserver_top — Altera Cyclone IV E FPGA WebServer top module
//
// Target: EP4CE10F17C6
// PHY interface: GMII (direct 8-bit SDR, no RGMII conversion needed)
// Clock: 50 MHz input → PLL → 50 / 125 / 200 MHz
//
// Platform-specific:
//   - Altera PLL (pll_50m)
//   - GMII signals connected directly (no rgmii2gmii)

module altera_ep4ce10f17c6_webserver_top #(
    parameter sim_mod = 0
) (
    input  clk_50m_in,
    input  reset_l,

    input  uart_rx,
    output uart_tx,

    // GMII interface (direct)
    output       Eth0_GRESET,
    output       Eth0_GTX_CLK,
    input        Eth0_RXC,
    input        Eth0_RXDV,
    input        Eth0_RXER,
    input  [7:0] Eth0_RXD,
    output [7:0] Eth0_TXD,
    output       Eth0_TXEN,
    output       Eth0_TXER,

    // MDIO
    output Eth0_MDC,
    inout  Eth0_MDIO,

    output [3:0] led_o
);

  localparam device_vendor = (sim_mod == 0) ? "Intel" : "";

  // --- Reset synchronizer (analysis_report fix: async assert, sync deassert) ---
  reg [1:0] reset_sync;
  wire reset_l_synced;

  always @(negedge reset_l or posedge clk_50m_in)
    if (reset_l == 1'b0) begin
      reset_sync <= 2'b00;
    end else begin
      reset_sync <= {reset_sync[0], 1'b1};
    end

  assign reset_l_synced = reset_sync[1];

  // --- PLL clocks ---
  wire clk_50m;
  wire clk_125m;
  wire clk_200m;

  generate
    if (sim_mod == 1 || device_vendor == "") begin : clk_bypass
      assign clk_50m  = clk_50m_in;
      assign clk_125m = clk_50m_in;
      assign clk_200m = clk_50m_in;
    end else begin : clk_pll
      PLL_50M U_PLL (
          .inclk0(clk_50m_in),
          .c0    (clk_50m),
          .c1    (clk_125m),
          .c2    (clk_200m),
          .locked()
      );
    end
  endgenerate

  // --- GMII RX register stage ---
  reg        gmii_rx_dv_r;
  reg        gmii_rx_err_r;
  reg [7:0]  gmii_rxd_r;

  always @(posedge Eth0_RXC) begin
    gmii_rx_dv_r  <= Eth0_RXDV;
    gmii_rx_err_r <= Eth0_RXER;
    gmii_rxd_r    <= Eth0_RXD;
  end

  // --- GMII TX register stage ---
  reg [7:0] gmii_txd_r;
  reg       gmii_tx_en_r;
  reg       gmii_tx_err_r;

  always @(posedge clk_125m) begin
    Eth0_TXD  <= gmii_txd_r;
    Eth0_TXEN <= gmii_tx_en_r;
    Eth0_TXER <= gmii_tx_err_r;
  end

  assign Eth0_GRESET  = reset_l_synced;
  assign Eth0_GTX_CLK = clk_125m;

  // --- WebServer core wrapper ---
  webserver_wrapper #(
      .debug_en(0),
      .lcpu_inst_en(1),
      .pll_bypass(sim_mod == 1)
  ) u_webserver (
      .clk           (clk_50m_in),
      .reset_l       (reset_l_synced),
      .clk_50Mhz_in  (clk_50m),
      .clk_125Mhz_in (clk_125m),
      .clk_200Mhz_in (clk_200m),

      .uart_rx  (uart_rx),
      .uart_tx  (uart_tx),

      .Eth0_MDC  (Eth0_MDC),
      .Eth0_MDIO (Eth0_MDIO),

      // Internal GMII (direct from PHY, registered)
      .gmii_rx_clk (Eth0_RXC),
      .gmii_rx_dv  (gmii_rx_dv_r),
      .gmii_rx_err (gmii_rx_err_r),
      .gmii_rxd    (gmii_rxd_r),

      .gmii_tx_clk (clk_125m),
      .gmii_txd    (gmii_txd_r),
      .gmii_tx_en  (gmii_tx_en_r),
      .gmii_tx_err (gmii_tx_err_r),

      .Led(led_o)
  );

endmodule
