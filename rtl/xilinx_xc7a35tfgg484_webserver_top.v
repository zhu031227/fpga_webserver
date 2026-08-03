`define FPGA_PLATFORM_XILINX
`include "define.sv"

// xilinx_xc7a35tfgg484_webserver_top — Xilinx Artix-7 3-port FPGA webserver
//
// Ports:
//   eth0 (RGMII): management port
//   eth1 (1000BASE-X via SFP1): LAN port
//   eth2 (1000BASE-X via SFP2): WAN port
//
// New: SFP wrapper, QSPI Flash IO, SFP control signals

module xilinx_xc7a35tfgg484_webserver_top #(
    parameter int sim_mod = 0,
    parameter script_file = "../tcl/InstructRAM.tcl"
) (
    input clk_50m_in,
    input reset_l,

    input  uart_rx,
    output uart_tx,

    // RGMII (eth0)
    output       rgmii_reset_l,
    input        rgmii_rxc,
    input        rgmii_rx_ctl,
    input  [3:0] rgmii_rxd,
    output       rgmii_txc,
    output       rgmii_tx_ctl,
    output [3:0] rgmii_txd,

    // eth0 MDIO
    output eth0_mdc,
    inout  eth0_mdio,

    // SFP1 (eth1, LAN) — 1000BASE-X
    output sfp1_tx_disable,
    input  sfp1_rxp,
    input  sfp1_rxn,
    output sfp1_txp,
    output sfp1_txn,

    // SFP2 (eth2, WAN) — 1000BASE-X
    output sfp2_tx_disable,
    input  sfp2_rxp,
    input  sfp2_rxn,
    output sfp2_txp,
    output sfp2_txn,

    // GT Reference Clock (125MHz differential, shared)
    input gtrefclk_p,
    input gtrefclk_n,

    // QSPI Flash (MX25L12845)
    output flash_cs_n,
    output flash_sclk,
    output flash_mosi,
    input  flash_miso,
    output flash_wp_n,
    output flash_rst_n,

    output [3:0] led_o
);

  localparam device_vendor = (sim_mod == 0) ? "xilinx" : "";

  localparam int second_event_period = 50000000;
  localparam int uart_baud_rate = 115200;
  localparam cpu_vendor = "xilinx";  //"intel";	"xilinx"; "uart"
  localparam int xilinx_idelay_value = 16;
  localparam int riscv_inst_en = 1;
  localparam instr_ram_type = "block";
  localparam int instr_addr_depth = 1024 * 16;
  localparam int instr_addr_width = $clog2(instr_addr_depth);
  localparam int init_blockram_size = 32;
  localparam int lcpu_init_instru = 1;
  localparam int amd_coe_init_instru = 0;
  localparam int intel_hex_init_instru = 0;
  localparam int cpu_buf_addr_width = 13;
  localparam cpu_buf_block_mode = "false";
  localparam int cpu_buf_block_addr_width = 2;
  localparam int cpu_buf_data_width = 8;
  localparam int cpu_buf_para_width = 1;
  localparam cpu_buf_data_ram_type = `LARGER_RAM;
  localparam cpu_buf_para_ram_type = `SMALL_RAM;
  localparam int stat_cnt_en = 1;

  // ============================================================
  // fpga_ila 调试系统
  //
  // ILA_TRANSPORT_EN 位掩码（任意组合，一版固件多通道同时在线）:
  //   bit0 = UART   (共享 uart_rx/tx，与 LCPU 控制台复用)
  //   bit1 = ETH    (GMII + UDP/IP，自动占用 eth0 GMII，webserver 让出)
  //   bit2 = JTAG   (BSCANE2 on USER2 —— 本工程暂不可用：LCPU 的
  //                  JTAG2AXI Debug Hub 已独占唯一 BSCAN 硬件块，
  //                  [Shape Builder 18-119] 冲突，故请勿置 bit2)
  //
  // GMII 归属自动推导：eth_mode = EN[1]（ETH 使能则 ILA 占用 GMII，
  // 否则归还 webserver），无需手工同步。
  // ============================================================
  localparam ILA_BAUD       = 921600; //115200; 921600; 3000000;
  localparam [2:0] ILA_TRANSPORT_EN = 3'b011;  // bit0=UART bit1=ETH bit2=JTAG
  localparam ILA_NUM_CORES  = 3;  // local_time + gmii rx + gmii tx
  localparam [47:0] ETH_MAC = 48'h10_11_12_13_14_15;
  localparam [31:0] ETH_IP  = {8'd192, 8'd168, 8'd1, 8'd89};
  localparam [15:0] ETH_PORT = 16'd5000;
  //localparam ILA_CLK_HZ     = 50_000_000;  // match clk_50m
  localparam ILA_CLK_HZ     = 125_000_000;  // match clk_125m
  localparam int eth_mode    = ILA_TRANSPORT_EN[1] ? 1 : 0;  // 自动：ETH 使能→ILA 占 GMII

  // --- Reset / PLL ---
  wire reset_l_synced;
  wire clk_50m, clk_125m, clk_200m, pll_locked;

  // --- RGMII → GMII (eth0) ---
  wire gmii0_rx_clk, gmii0_rx_dv;
  wire [7:0] gmii0_rxd;
  wire       gmii0_tx_en;
  wire [7:0] gmii0_txd;

  // eth_mode mux: route GMII to webserver (mode 0) or ILA debug (mode 1)
  wire       gmii0_rx_dv_ws;
  wire [7:0] gmii0_rxd_ws;
  wire       gmii0_tx_en_ws;
  wire [7:0] gmii0_txd_ws;
  wire       gmii0_rx_dv_ila;
  wire [7:0] gmii0_rxd_ila;
  wire       gmii0_tx_en_ila;
  wire [7:0] gmii0_txd_ila;

  // RX: rgmii2gmii drives gmii0_rx_* → mux to ws or ila
  assign gmii0_rx_dv_ws  = (eth_mode == 0) ? gmii0_rx_dv  : 1'b0;
  assign gmii0_rxd_ws    = (eth_mode == 0) ? gmii0_rxd    : 8'h0;
  assign gmii0_rx_dv_ila = (eth_mode == 1) ? gmii0_rx_dv  : 1'b0;
  assign gmii0_rxd_ila   = (eth_mode == 1) ? gmii0_rxd    : 8'h0;

  // TX: select source (webserver or ILA) → rgmii2gmii
  assign gmii0_tx_en = (eth_mode == 0) ? gmii0_tx_en_ws : gmii0_tx_en_ila;
  assign gmii0_txd   = (eth_mode == 0) ? gmii0_txd_ws   : gmii0_txd_ila;

  // --- 1000BASE-X wrapper → GMII (eth1, eth2) ---
  wire gmii1_rx_clk, gmii1_rx_dv, gmii1_rx_err;
  wire [7:0] gmii1_rxd;
  wire gmii1_tx_en, gmii1_tx_err;
  wire [7:0] gmii1_txd;

  wire gmii2_rx_clk, gmii2_rx_dv, gmii2_rx_err;
  wire [7:0] gmii2_rxd;
  wire gmii2_tx_en, gmii2_tx_err;
  wire [7:0] gmii2_txd;

  // SFP status
  wire sfp_resetdone, sfp_mmcm_locked;
  wire [15:0] sfp1_status, sfp2_status;

  // eth1/eth2 MDIO (unused for SFP, but connected)
  wire eth1_mdc, eth2_mdc;
  wire eth1_mdio, eth2_mdio;

  wire [ILA_NUM_CORES-1:0] ila_core_we;
  wire        ila_core_re;
  wire [15:0] ila_core_addr;
  wire [31:0] ila_core_wdata;
  wire [ILA_NUM_CORES*32-1:0] ila_core_rdata;
  wire        ila_jtag_clk;
  wire        ila_jtag_rst;

  // --- Reset controller ---
  clk_rst_ctrl #(
      .NUM_LOCK_INPUTS(1)
  ) u_clk_rst_ctrl (
      .clk(clk_50m_in),
      .async_rst_l(reset_l),
      .pll_locked(pll_locked),
      .rst_l(reset_l_synced)
  );

  // --- PLL ---
  generate
    if (sim_mod == 1 || device_vendor == "") begin : g_clk_bypass
      assign clk_50m = clk_50m_in;
      assign clk_125m = clk_50m_in;
      assign clk_200m = clk_50m_in;
      assign pll_locked = 1'b1;
    end else begin : g_clk_pll
      pll_50m u_pll (
          .inclk0(clk_50m_in),
          .c0(clk_50m),
          .c1(clk_125m),
          .c2(clk_200m),
          .locked(pll_locked)
      );
    end
  endgenerate

  // --- RGMII2GMII (eth0) ---
  rgmii2gmii #(
      .Xilinx_IDELAY_VALUE(xilinx_idelay_value),
      .vendor(device_vendor)
  ) u_rgmii2gmii (
      .reset_l(reset_l_synced),
      .clk_200m(clk_200m),
      .gmii_rx_clk(gmii0_rx_clk),
      .gmii_rx_dv(gmii0_rx_dv),
      .gmii_rxd(gmii0_rxd),
      .gmii_tx_clk(clk_125m),
      .gmii_tx_en(gmii0_tx_en),
      .gmii_txd(gmii0_txd),
      .rgmii_rxc(rgmii_rxc),
      .rgmii_rx_ctl(rgmii_rx_ctl),
      .rgmii_rxd(rgmii_rxd),
      .rgmii_txc(rgmii_txc),
      .rgmii_tx_ctl(rgmii_tx_ctl),
      .rgmii_txd(rgmii_txd)
  );
  assign rgmii_reset_l = reset_l_synced;

  // --- 1000BASE-X SFP wrapper (eth1 + eth2) ---
  // Uses shared GTPE2_COMMON + IBUFDS_GTE2 + MMCM
  sfp_1000basex_wrapper u_sfp_wrapper (
      .gtrefclk_p(gtrefclk_p),
      .gtrefclk_n(gtrefclk_n),
      .independent_clock_bufg(clk_200m),
      .reset(~reset_l_synced),  // active-high reset

      // SFP1 (eth1)
      .sfp1_txp(sfp1_txp),
      .sfp1_txn(sfp1_txn),
      .sfp1_rxp(sfp1_rxp),
      .sfp1_rxn(sfp1_rxn),
      .sfp1_tx_disable(sfp1_tx_disable),
      .gmii1_txd(gmii1_txd),
      .gmii1_tx_en(gmii1_tx_en),
      .gmii1_tx_er(gmii1_tx_err),
      .gmii1_rxd(gmii1_rxd),
      .gmii1_rx_dv(gmii1_rx_dv),
      .gmii1_rx_er(gmii1_rx_err),
      .sfp1_status_vector(sfp1_status),

      // SFP2 (eth2)
      .sfp2_txp(sfp2_txp),
      .sfp2_txn(sfp2_txn),
      .sfp2_rxp(sfp2_rxp),
      .sfp2_rxn(sfp2_rxn),
      .sfp2_tx_disable(sfp2_tx_disable),
      .gmii2_txd(gmii2_txd),
      .gmii2_tx_en(gmii2_tx_en),
      .gmii2_tx_er(gmii2_tx_err),
      .gmii2_rxd(gmii2_rxd),
      .gmii2_rx_dv(gmii2_rx_dv),
      .gmii2_rx_er(gmii2_rx_err),
      .sfp2_status_vector(sfp2_status),

      .resetdone(sfp_resetdone),
      .mmcm_locked_out(sfp_mmcm_locked)
  );

  // GMII RX clocks for eth1/eth2 come from the SFP wrapper
  assign gmii1_rx_clk = clk_125m;
  assign gmii2_rx_clk = clk_125m;

  // FPGA debug chain
  ila_hub_top #(
      .TRANSPORT_EN (ILA_TRANSPORT_EN),
      .ILA_BAUD   (ILA_BAUD),
      .ETH_MAC    (ETH_MAC),
      .ETH_IP     (ETH_IP),
      .ETH_PORT   (ETH_PORT),
      .NUM_CORES  (ILA_NUM_CORES),
      .ILA_CLK_HZ (ILA_CLK_HZ)
  ) u_ila_debug (
      .clk           (clk_125m), //clk_50m
      //.clk           (clk_50m),
      .rst           (~reset_l_synced),
      .uart_rxd      (uart_rx),
      .uart_txd      (uart_tx),
      .gmii_rx_clk   (gmii0_rx_clk),
      .gmii_rxd      (gmii0_rxd_ila),
      .gmii_rx_dv    (gmii0_rx_dv_ila),
      .gmii_txd      (gmii0_txd_ila),
      .gmii_tx_en    (gmii0_tx_en_ila),
      .core_reg_we   (ila_core_we),
      .core_reg_re   (ila_core_re),
      .core_reg_addr (ila_core_addr),
      .core_reg_wdata(ila_core_wdata),
      .core_reg_rdata(ila_core_rdata),
      .jtag_tms      (),
      .core_jtag_clk (ila_jtag_clk),
      .core_jtag_rst (ila_jtag_rst)
  );

  // --- ILA core 1: GMII eth0 RX debug ---
  soft_ila_top_fcapz #(
      .CORE_EN       (1),
      .DATA_DEPTH    (2048),
      .MAX_WINDOWS   (2),
      .SAMPLE_HZ     (125000000),
      .RST_ACTIVE_LOW(1),
      .NUM_PROBES    (2),
      .PROBE0_WIDTH  (1),
      .PROBE1_WIDTH  (8),
      .EXT_TRIG_EN   (1)
  ) u_ila_gmii_rx (
      .sample_clk    (gmii0_rx_clk),
      .rst_in        (reset_l_synced),
      .jtag_clk      (ila_jtag_clk),
      .probe0        (gmii0_rx_dv),
      .probe1        (gmii0_rxd),
      .trigger_in    (1'b0),
      .trigger_out   (),
      .armed_out     (),
      .reg_we        (ila_core_we[1]),
      .reg_re        (ila_core_re),
      .reg_addr      (ila_core_addr),
      .reg_wdata     (ila_core_wdata),
      .reg_rdata     (ila_core_rdata[1*32+:32])
  );

  // --- ILA core 2: GMII eth0 TX debug ---
  soft_ila_top_fcapz #(
      .CORE_EN       (1),
      .DATA_DEPTH    (4096),
      .MAX_WINDOWS   (2),
      .SAMPLE_HZ     (125000000),
      .RST_ACTIVE_LOW(1),
      .NUM_PROBES    (2),
      .PROBE0_WIDTH  (8),
      .PROBE1_WIDTH  (1),
      .EXT_TRIG_EN   (1)
  ) u_ila_gmii_tx (
      .sample_clk    (clk_125m),
      .rst_in        (reset_l_synced),
      .jtag_clk      (ila_jtag_clk),
      .probe0        (gmii0_txd),
      .probe1        (gmii0_tx_en),
      .trigger_in    (1'b0),
      .trigger_out   (),
      .armed_out     (),
      .reg_we        (ila_core_we[2]),
      .reg_re        (ila_core_re),
      .reg_addr      (ila_core_addr),
      .reg_wdata     (ila_core_wdata),
      .reg_rdata     (ila_core_rdata[2*32+:32])
  );

  // --- Webserver core ---
  webserver_wrapper #(
      .sim_mod(sim_mod),
      .script_file(script_file),
      .second_event_period(second_event_period),
      .uart_baud_rate(uart_baud_rate),
      .cpu_vendor(cpu_vendor),
      .device_vendor(device_vendor),
      .riscv_inst_en(riscv_inst_en),
      .instr_ram_type(instr_ram_type),
      .instr_addr_depth(instr_addr_depth),
      .instr_addr_width(instr_addr_width),
      .init_blockram_size(init_blockram_size),
      .lcpu_init_instru(lcpu_init_instru),
      .amd_coe_init_instru(amd_coe_init_instru),
      .intel_hex_init_instru(intel_hex_init_instru),
      .cpu_buf_addr_width(cpu_buf_addr_width),
      .cpu_buf_block_mode(cpu_buf_block_mode),
      .cpu_buf_block_addr_width(cpu_buf_block_addr_width),
      .cpu_buf_data_width(cpu_buf_data_width),
      .cpu_buf_para_width(cpu_buf_para_width),
      .cpu_buf_data_ram_type(cpu_buf_data_ram_type),
      .cpu_buf_para_ram_type(cpu_buf_para_ram_type),
      .stat_cnt_en(stat_cnt_en),
      .ILA_NUM_CORES(1)  // webserver_wrapper 内部只有 1 核
  ) u_webserver (
      .reset_l(reset_l_synced),
      .clk_50mhz(clk_50m),
      .clk_125mhz(clk_125m),
      .uart_rx(1'b0),
      .uart_tx(),

      // eth0 MDIO
      .eth0_mdc (eth0_mdc),
      .eth0_mdio(eth0_mdio),
      // eth1/eth2 MDIO
      .eth1_mdc (eth1_mdc),
      .eth1_mdio(eth1_mdio),
      .eth2_mdc (eth2_mdc),
      .eth2_mdio(eth2_mdio),

      // eth0 GMII (from RGMII bridge)
      .gmii_rx_clk(gmii0_rx_clk),
      .gmii_rx_dv(gmii0_rx_dv_ws),
      .gmii_rxd(gmii0_rxd_ws),
      .gmii_rx_err(1'b0),
      .gmii_txd(gmii0_txd_ws),
      .gmii_tx_en(gmii0_tx_en_ws),
      .gmii_tx_err(),

      // eth1 GMII (from SFP wrapper)
      .gmii1_rx_clk(gmii1_rx_clk),
      .gmii1_rx_dv(gmii1_rx_dv),
      .gmii1_rx_err(gmii1_rx_err),
      .gmii1_rxd(gmii1_rxd),
      .gmii1_txd(gmii1_txd),
      .gmii1_tx_en(gmii1_tx_en),
      .gmii1_tx_err(),

      // eth2 GMII (from SFP wrapper)
      .gmii2_rx_clk(gmii2_rx_clk),
      .gmii2_rx_dv(gmii2_rx_dv),
      .gmii2_rx_err(gmii2_rx_err),
      .gmii2_rxd(gmii2_rxd),
      .gmii2_txd(gmii2_txd),
      .gmii2_tx_en(gmii2_tx_en),
      .gmii2_tx_err(),

      // SPI Flash
      .flash_sclk (flash_sclk),
      .flash_mosi (flash_mosi),
      .flash_miso (flash_miso),
      .flash_cs_n (flash_cs_n),
      .flash_wp_n (flash_wp_n),
      .flash_rst_n(flash_rst_n),

      .led(led_o),

      // fpga_ila JTAG 调试总线
      .ila_jtag_clk  (ila_jtag_clk),
      .ila_jtag_rst  (ila_jtag_rst),
      .ila_core_we   (ila_core_we[0]),
      .ila_core_re   (ila_core_re),
      .ila_core_addr (ila_core_addr),
      .ila_core_wdata(ila_core_wdata),
      .ila_core_rdata(ila_core_rdata[0*32+:32])
  );
endmodule
