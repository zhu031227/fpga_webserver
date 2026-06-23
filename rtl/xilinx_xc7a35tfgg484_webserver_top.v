// xilinx_xc7a35tfgg484_webserver_top — Xilinx Artix-7 FPGA WebServer top module
//
// Target: XC7A35T-FGG484-2
// PHY interface: RGMII (converted to internal GMII via rgmii2gmii)
// Clock: 50 MHz input → MMCM PLL → 50 / 125 / 200 MHz
//
// Platform-specific:
//   - Xilinx MMCM PLL (pll_50m)
//   - rgmii2gmii for RGMII-to-GMII conversion
//   - IDELAY/ODDR primitives for RGMII DDR I/O

module xilinx_xc7a35tfgg484_webserver_top #(
    parameter sim_mod = 0,
    parameter Xilinx_IDELAY_VALUE = 16
) (
    input  clk_50m_in,
    input  reset_l,

    input  uart_rx,
    output uart_tx,

    // RGMII interface
    output       rgmii_reset_l,
    input        rgmii_rxc,
    input        rgmii_rx_ctl,
    input  [3:0] rgmii_rxd,
    output       rgmii_txc,
    output       rgmii_tx_ctl,
    output [3:0] rgmii_txd,

    // MDIO
    output Eth0_MDC,
    inout  Eth0_MDIO,

    output [3:0] led_o
);

  localparam device_vendor = (sim_mod == 0) ? "AMD" : "";

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
  wire pll_locked;

  generate
    if (sim_mod == 1 || device_vendor == "") begin : clk_bypass
      assign clk_50m  = clk_50m_in;
      assign clk_125m = clk_50m_in;
      assign clk_200m = clk_50m_in;
      assign pll_locked = 1'b1;
    end else begin : clk_pll
      pll_50m u_pll (
          .inclk0(clk_50m_in),
          .c0    (clk_50m),
          .c1    (clk_125m),
          .c2    (clk_200m),
          .locked(pll_locked)
      );
    end
  endgenerate

  // --- RGMII to GMII conversion ---
  wire        gmii_rx_clk;
  wire        gmii_rx_dv;
  wire [7:0]  gmii_rxd;
  wire        gmii_tx_en;
  wire [7:0]  gmii_txd;
  wire        gmii_tx_err;

  rgmii2gmii #(
      .Xilinx_IDELAY_VALUE(Xilinx_IDELAY_VALUE),
      .vendor(device_vendor)
  ) u_rgmii2gmii (
      .reset_l(reset_l_synced),
      .clk_200m(clk_200m),

      .gmii_rx_clk(gmii_rx_clk),
      .gmii_rx_dv (gmii_rx_dv),
      .gmii_rxd   (gmii_rxd),

      .gmii_tx_clk(clk_125m),
      .gmii_tx_en (gmii_tx_en),
      .gmii_txd   (gmii_txd),

      .rgmii_rxc    (rgmii_rxc),
      .rgmii_rx_ctl (rgmii_rx_ctl),
      .rgmii_rxd    (rgmii_rxd),
      .rgmii_txc    (rgmii_txc),
      .rgmii_tx_ctl (rgmii_tx_ctl),
      .rgmii_txd    (rgmii_txd)
  );

  assign rgmii_reset_l = reset_l_synced;

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

      // Internal GMII (from rgmii2gmii)
      .gmii_rx_clk (gmii_rx_clk),
      .gmii_rx_dv  (gmii_rx_dv),
      .gmii_rx_err (1'b0),
      .gmii_rxd    (gmii_rxd),

      .gmii_tx_clk (clk_125m),
      .gmii_txd    (gmii_txd),
      .gmii_tx_en  (gmii_tx_en),
      .gmii_tx_err (gmii_tx_err),

      .Led(led_o)
  );

endmodule
