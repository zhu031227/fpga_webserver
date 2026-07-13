// webserver_wrapper — 3-port FPGA webserver core with MAC whitelist L2 bridge
//
// Ports:
//   eth0 (RGMII):  management, RX→CPU only
//   eth1 (GMII):   LAN port (from 1000BASE-X), L2 bridge → eth2 with whitelist
//   eth2 (GMII):   WAN port (from 1000BASE-X), L2 bridge → eth1 (unconditional)
//
// New modules: cpu_channel_tri, mac_whitelist_top, lcpu_sflash

`include "define.sv"

module webserver_wrapper #(
    parameter int sim_mod                  = 0,
    parameter     script_file              = "../tcl/InstructRAM.tcl",
    parameter int second_event_period      = 50000000,
    parameter int uart_baud_rate           = 115200,
    parameter     cpu_vendor               = "xilinx",
    parameter     device_vendor            = "xilinx",
    parameter int riscv_inst_en            = 1,
    parameter     instr_ram_type           = "block",
    parameter int instr_addr_depth         = 1024 * 5,
    parameter int instr_addr_width         = $clog2(instr_addr_depth),
    parameter int init_blockram_size       = 32,
    parameter int lcpu_init_instru         = 1,
    parameter int amd_coe_init_instru      = 0,
    parameter int intel_hex_init_instru    = 0,
    parameter int cpu_buf_addr_width       = 12,
    parameter     cpu_buf_block_mode       = "false",
    parameter int cpu_buf_block_addr_width = 2,
    parameter int cpu_buf_data_width       = 8,
    parameter int cpu_buf_para_width       = 1,
    parameter     cpu_buf_data_ram_type    = "block",
    parameter     cpu_buf_para_ram_type    = "distributed",
    parameter int stat_cnt_en              = 1
) (
    input reset_l,
    input clk_50mhz,
    input clk_125mhz,

    input  uart_rx,
    output uart_tx,

    // eth0 MDIO
    output eth0_mdc,
    inout  eth0_mdio,

    // eth1 MDIO (NEW)
    output eth1_mdc,
    inout  eth1_mdio,

    // eth2 MDIO (NEW)
    output eth2_mdc,
    inout  eth2_mdio,

    // eth0 GMII (RGMII bridge → internal)
    input        gmii_rx_clk,
    input        gmii_rx_dv,
    input        gmii_rx_err,
    input  [7:0] gmii_rxd,
    output [7:0] gmii_txd,
    output       gmii_tx_en,
    output       gmii_tx_err,

    // eth1 GMII (from 1000BASE-X wrapper, NEW)
    input        gmii1_rx_clk,
    input        gmii1_rx_dv,
    input        gmii1_rx_err,
    input  [7:0] gmii1_rxd,
    output [7:0] gmii1_txd,
    output       gmii1_tx_en,
    output       gmii1_tx_err,

    // eth2 GMII (from 1000BASE-X wrapper, NEW)
    input        gmii2_rx_clk,
    input        gmii2_rx_dv,
    input        gmii2_rx_err,
    input  [7:0] gmii2_rxd,
    output [7:0] gmii2_txd,
    output       gmii2_tx_en,
    output       gmii2_tx_err,

    // SPI Flash (NEW)
    output flash_sclk,
    output flash_mosi,
    input  flash_miso,
    output flash_cs_n,
    output flash_wp_n,
    output flash_rst_n,

    output [3:0] eth_greset,
    output [3:0] led
);

  // ============================================================
  // Build time / local time / second event
  // ============================================================
  wire [                31:0] fpga_build_date;
  wire [                31:0] fpga_build_time;
  wire [                63:0] local_time_counter;
  wire [                31:0] local_time_l = local_time_counter[31:0];
  wire [                31:0] local_time_h = local_time_counter[63:32];
  wire                        second_event;

  // ============================================================
  // CPU subsystem
  // ============================================================
  wire                        cpu_req;
  wire                        cpu_rhwl;
  wire [                31:0] cpu_wdata;
  wire [                31:0] cpu_address;
  wire [                31:0] cpu_rdata;
  wire                        cpu_ack;

  // pram: mux between LCPU (reg_webserver) and bootloader
  wire                        pram_wr_lcpu;
  wire [instr_addr_width-1:0] pram_addr_lcpu;
  wire [                31:0] pram_wdata_lcpu;
  wire [                31:0] pram_rdata;

  wire                        pram_wr   = bootloader_status[0] ? bl_pram_wr   : pram_wr_lcpu;
  wire [instr_addr_width-1:0] pram_addr = bootloader_status[0] ? bl_pram_addr : pram_addr_lcpu;
  wire [                31:0] pram_wdata = bootloader_status[0] ? bl_pram_wdata : pram_wdata_lcpu;

  // ============================================================
  // Register signals (50MHz domain)
  // ============================================================
  wire                        get_local_time;
  wire [                31:0] debug_rw_0;
  wire [                31:0] debug_rw_1;
  wire [                31:0] debug_ro_0;
  wire [                31:0] debug_ro_1;
  wire [                 7:0] recv_pkt_drop_cnt_src;  // 125MHz
  wire [                 7:0] recv_pkt_drop_cnt;  // 50MHz, Gray synced
  wire [                31:0] debug_wc_0;
  wire                        debug_wc_0_ind;
  wire [                31:0] debug_wc_1;
  wire                        debug_wc_1_ind;
  wire [                31:0] debug_rc_0;
  wire                        debug_rc_0_ind;
  wire [                31:0] debug_rc_1;
  wire                        debug_rc_1_ind;

  // Local config (50MHz domain, from reg_webserver)
  wire [                31:0] local_mac_h;
  wire [                15:0] local_mac_l;
  wire [                31:0] local_ip_50m;
  wire [                31:0] local_netmask_50m;
  wire [                31:0] local_gateway_50m;
  wire                        local_config_save;
  wire                        local_config_save_ind;
  wire                        local_config_load;
  wire                        local_config_load_ind;
  wire                        local_config_valid;

  // Whitelist global control (50MHz → 125MHz CDC)
  wire [                 1:0] wl_ctrl_50m;
  wire [                 1:0] wl_ctrl_125m;
  wire [                15:0] wl_status;  // [7:0]=lookup_mode, [15:8]=used_cnt
  wire [                31:0] wl_lat_match_mac_h;
  wire [                15:0] wl_lat_match_mac_l;

  // ============================================================
  // SubBus signals
  // ============================================================
  // eth0 MDIO
  wire eth0_op_req, eth0_wrl_rdh;
  wire [31:0] eth0_wrdata, eth0_address, eth0_rddata;
  wire eth0_op_ack;
  // eth1 MDIO
  wire eth1_op_req, eth1_wrl_rdh;
  wire [31:0] eth1_wrdata, eth1_address, eth1_rddata;
  wire eth1_op_ack;
  // eth2 MDIO
  wire eth2_op_req, eth2_wrl_rdh;
  wire [31:0] eth2_wrdata, eth2_address, eth2_rddata;
  wire eth2_op_ack;
  // SPI Flash
  wire sflash_op_req, sflash_wrl_rdh;
  wire [31:0] sflash_wrdata, sflash_rddata;
  wire [11:0] sflash_address;
  wire        sflash_op_ack;
  // MAC Whitelist RAMIF
  wire wl_ram_rlwh;
  wire [11:0] wl_ram_addr;
  wire [31:0] wl_ram_wrdata, wl_ram_rddata;

  // Bootloader (50MHz domain)
  wire                        bootloader_trigger;
  wire                        bootloader_trigger_ind;
  wire [2:0]                  bootloader_status;
  wire [31:0]                 bootloader_flash_addr;
  wire [31:0]                 bootloader_length;

  // Bootloader pram interface (muxed with LCPU pram)
  wire                        bl_pram_wr;
  wire [instr_addr_width-1:0] bl_pram_addr;
  wire [31:0]                 bl_pram_wdata;
  wire                        lcpu_pram_wr;
  wire [instr_addr_width-1:0] lcpu_pram_addr;
  wire [31:0]                 lcpu_pram_wdata;

  // Bootloader SPI interface (muxed with lcpu_sflash)
  wire        bl_spi_op_start, bl_spi_op_done;
  wire [15:0] bl_spi_channel_len;
  wire [63:0] bl_spi_wdata;
  wire [31:0] bl_spi_rdata;

  // SPI mux: bootloader vs lcpu_sflash
  wire        spi_sclk_bl, spi_mosi_bl, spi_cs_n_bl;
  wire        spi_sclk_sf, spi_mosi_sf, spi_cs_n_sf;

  // ============================================================
  // Eth statistics (125MHz domain, from gmii2mac)
  // ============================================================
  // eth0
  wire [31:0] eth0_rx_correct_pkt_cnt_src, eth0_rx_crc_err_pkt_cnt_src;
  wire [31:0] eth0_tx_correct_pkt_cnt_src, eth0_tx_error_pkt_cnt_src;
  wire [31:0] eth0_rx_afifo_full_cnt_src, eth0_rx_afifo_empty_cnt_src;
  wire [31:0] eth0_rx_data_err_line_src;
  // eth1
  wire [31:0] eth1_rx_correct_pkt_cnt_src, eth1_rx_crc_err_pkt_cnt_src;
  wire [31:0] eth1_tx_correct_pkt_cnt_src, eth1_tx_error_pkt_cnt_src;
  wire [31:0] eth1_rx_afifo_full_cnt_src, eth1_rx_afifo_empty_cnt_src;
  wire [31:0] eth1_rx_data_err_line_src;
  // eth2
  wire [31:0] eth2_rx_correct_pkt_cnt_src, eth2_rx_crc_err_pkt_cnt_src;
  wire [31:0] eth2_tx_correct_pkt_cnt_src, eth2_tx_error_pkt_cnt_src;
  wire [31:0] eth2_rx_afifo_full_cnt_src, eth2_rx_afifo_empty_cnt_src;
  wire [31:0] eth2_rx_data_err_line_src;

  // Statistics synced to 50MHz
  wire [31:0] eth0_rx_correct_pkt_cnt, eth0_rx_crc_err_pkt_cnt;
  wire [31:0] eth0_tx_correct_pkt_cnt, eth0_tx_error_pkt_cnt;
  wire [31:0] eth0_rx_afifo_full_cnt, eth0_rx_afifo_empty_cnt;
  wire [31:0] eth0_rx_data_err_line;
  wire [31:0] eth1_rx_correct_pkt_cnt, eth1_rx_crc_err_pkt_cnt;
  wire [31:0] eth1_tx_correct_pkt_cnt, eth1_tx_error_pkt_cnt;
  wire [31:0] eth1_rx_afifo_full_cnt, eth1_rx_afifo_empty_cnt;
  wire [31:0] eth1_rx_data_err_line;
  wire [31:0] eth2_rx_correct_pkt_cnt, eth2_rx_crc_err_pkt_cnt;
  wire [31:0] eth2_tx_correct_pkt_cnt, eth2_tx_error_pkt_cnt;
  wire [31:0] eth2_rx_afifo_full_cnt, eth2_rx_afifo_empty_cnt;
  wire [                  31:0] eth2_rx_data_err_line;

  // ============================================================
  // CPU packet channel signals (50MHz cpu_clk)
  // ============================================================
  wire                          cpu_rd_empty;
  wire                          cpu_rd_rpkt_pop_ind;
  wire [  cpu_buf_addr_width:0] cpu_rd_rpkt_len;
  wire [cpu_buf_para_width-1:0] cpu_rd_rpkt_para;
  wire                          cpu_rd_ren;
  wire [cpu_buf_addr_width-1:0] cpu_rd_raddr;
  wire [cpu_buf_data_width-1:0] cpu_rd_rdata;
  wire                          cpu_rd_reop_pre;
  wire                          cpu_wr_full;
  wire                          cpu_wr_wen_ind;
  wire [cpu_buf_addr_width-1:0] cpu_wr_waddr;
  wire [cpu_buf_data_width-1:0] cpu_wr_wdata;
  wire [  cpu_buf_addr_width:0] cpu_wr_wpkt_len;
  wire [cpu_buf_para_width-1:0] cpu_wr_wpkt_para;
  wire                          cpu_wr_wpkt_push_ind;

  // ============================================================
  // GMII → MAC interfaces
  // ============================================================
  // eth0
  wire eth0_mac_rx_sop, eth0_mac_rx_en, eth0_mac_rx_eop, eth0_mac_rx_err;
  wire [7:0] eth0_mac_rx_data;
  wire eth0_mac_tx_sop, eth0_mac_tx_en, eth0_mac_tx_eop, eth0_mac_tx_err;
  wire [7:0] eth0_mac_tx_data;
  // eth1
  wire eth1_mac_rx_sop, eth1_mac_rx_en, eth1_mac_rx_eop, eth1_mac_rx_err;
  wire [7:0] eth1_mac_rx_data;
  wire eth1_mac_tx_sop, eth1_mac_tx_en, eth1_mac_tx_eop, eth1_mac_tx_err;
  wire [7:0] eth1_mac_tx_data;
  // eth2
  wire eth2_mac_rx_sop, eth2_mac_rx_en, eth2_mac_rx_eop, eth2_mac_rx_err;
  wire [7:0] eth2_mac_rx_data;
  wire eth2_mac_tx_sop, eth2_mac_tx_en, eth2_mac_tx_eop, eth2_mac_tx_err;
  wire [7:0] eth2_mac_tx_data;

  // ============================================================
  // Whitelist lookup interface (125MHz)
  // ============================================================
  wire wl_lookup_req, wl_lookup_match, wl_lookup_done, wl_lookup_busy;
  wire [47:0] wl_lookup_mac;
  wire wl_manual_lookup_pulse;  // from debug_wc_0_ind, CDC'd to 125MHz
  wire wl_lookup_req_combined;
  assign wl_lookup_req_combined = wl_lookup_req | wl_manual_lookup_pulse;

  // Whitelist LCPU bus (50MHz) — RAMIF interface
  wire [31:0] wl_cfg_rdata;

  // Bridge drop counter (125MHz)
  wire [31:0] eth1_rx_drop_cnt_src;
  wire [31:0] eth1_rx_drop_cnt;

  // ============================================================
  // tod / interval_timer / build_time (existing)
  // ============================================================
  tod #(
      .counter_mode(1),
      .step(20)
  ) u_tod (
      .clk(clk_50mhz),
      .reset_l(reset_l),
      .snapshot(get_local_time),
      .counter_live(),
      .time_out(local_time_counter)
  );
  interval_timer #(
      .counter_width(26),
      .period_count (second_event_period),
      .output_mode  (0)
  ) u_second_timer (
      .clk(clk_50mhz),
      .reset_l(reset_l),
      .event_out(second_event)
  );
  fpga_build_time u_fpga_build_time (
      .build_date(fpga_build_date),
      .build_time(fpga_build_time)
  );

  // ============================================================
  // CPU subsystem (existing)
  // ============================================================
  lcpu_riscv_wrapper #(
      .sim_mod(sim_mod),
      .script_file(script_file),
      .lcpu_type(cpu_vendor),
      .uart_baud_rate(uart_baud_rate),
      .riscv_inst_en(riscv_inst_en),
      .instr_databits(32),
      .init_addr_width(instr_addr_width),
      .init_addr_depth(instr_addr_depth),
      .device_vendor(device_vendor),
      .instr_ram_type(instr_ram_type),
      .init_blockram_size(init_blockram_size),
      .enable_irq(0),
      .enable_irq_qregs(1),
      .progaddr_irq(16)
  ) u_cpu_subsystem (
      .clk(clk_50mhz),
      .reset_l(reset_l),
      .uart_rx(uart_rx),
      .uart_tx(uart_tx),
      .riscv_reset_l(riscv_reset_l),
      .pram_wr(pram_wr),
      .pram_addr(pram_addr),
      .pram_wdata(pram_wdata),
      .pram_rdata(pram_rdata),
      .req(cpu_req),
      .rhwl(cpu_rhwl),
      .wdata(cpu_wdata),
      .address(cpu_address),
      .ack(cpu_ack),
      .rdata(cpu_rdata)
  );

  // ============================================================
  // Register file (extended with 3-port + whitelist + flash)
  // ============================================================
  reg_webserver u_reg (
      .fpga_build_date(fpga_build_date),
      .fpga_build_time(fpga_build_time),
      .sw_build_date(),
      .sw_build_time(),
      .eth_greset(eth_greset),
      .second_event(second_event),
      .get_local_time(),
      .get_local_time_ind(get_local_time),
      .local_time_l(local_time_l),
      .local_time_h(local_time_h),
      .riscv_reset_l(riscv_reset_l),
      .debug_rw_0(debug_rw_0),
      .debug_rw_1(debug_rw_1),
      .debug_rw_2(),
      .debug_rw_3(),
      .debug_ro_0(debug_ro_0),
      .debug_ro_1(debug_ro_1),
      .debug_ro_2(32'd0),
      .debug_ro_3(32'd0),
      .debug_wc_0(debug_wc_0),
      .debug_wc_0_ind(debug_wc_0_ind),
      .debug_wc_1(debug_wc_1),
      .debug_wc_1_ind(debug_wc_1_ind),
      .debug_rc_0(32'd0),
      .debug_rc_0_ind(debug_rc_0_ind),
      .debug_rc_1(32'd0),
      .debug_rc_1_ind(debug_rc_1_ind),
      // eth0 stats
      .eth_rx_correct_pkt_cnt(eth0_rx_correct_pkt_cnt),
      .eth_rx_crc_err_pkt_cnt(eth0_rx_crc_err_pkt_cnt),
      .eth_tx_correct_pkt_cnt(eth0_tx_correct_pkt_cnt),
      .eth_tx_error_pkt_cnt(eth0_tx_error_pkt_cnt),
      .eth_rx_afifo_full_cnt(eth0_rx_afifo_full_cnt),
      .eth_rx_afifo_empty_cnt(eth0_rx_afifo_empty_cnt),
      .eth_rx_data_err_line(eth0_rx_data_err_line),
      // eth1 stats
      .eth1_rx_correct_pkt_cnt(eth1_rx_correct_pkt_cnt),
      .eth1_rx_crc_err_pkt_cnt(eth1_rx_crc_err_pkt_cnt),
      .eth1_tx_correct_pkt_cnt(eth1_tx_correct_pkt_cnt),
      .eth1_tx_error_pkt_cnt(eth1_tx_error_pkt_cnt),
      .eth1_rx_afifo_full_cnt(eth1_rx_afifo_full_cnt),
      .eth1_rx_afifo_empty_cnt(eth1_rx_afifo_empty_cnt),
      .eth1_rx_data_err_line(eth1_rx_data_err_line),
      // eth2 stats
      .eth2_rx_correct_pkt_cnt(eth2_rx_correct_pkt_cnt),
      .eth2_rx_crc_err_pkt_cnt(eth2_rx_crc_err_pkt_cnt),
      .eth2_tx_correct_pkt_cnt(eth2_tx_correct_pkt_cnt),
      .eth2_tx_error_pkt_cnt(eth2_tx_error_pkt_cnt),
      .eth2_rx_afifo_full_cnt(eth2_rx_afifo_full_cnt),
      .eth2_rx_afifo_empty_cnt(eth2_rx_afifo_empty_cnt),
      .eth2_rx_data_err_line(eth2_rx_data_err_line),
      // filter
      .filter_data(),
      .filter_offset(),
      // local config
      .local_mac_h(local_mac_h),
      .local_mac_l(local_mac_l),
      .local_ip(local_ip_50m),
      .local_netmask(local_netmask_50m),
      .local_gateway(local_gateway_50m),
      .local_config_save(local_config_save),
      .local_config_save_ind(local_config_save_ind),
      .local_config_load(local_config_load),
      .local_config_load_ind(local_config_load_ind),
      .local_config_valid(local_config_valid),
      // whitelist control
      .wl_ctrl(wl_ctrl_50m),
      .wl_status(wl_status),
      .wl_lat_match_mac_h(wl_lat_match_mac_h),
      .wl_lat_match_mac_l(wl_lat_match_mac_l),
      // bootloader
      .bootloader_trigger(bootloader_trigger),
      .bootloader_trigger_ind(bootloader_trigger_ind),
      .bootloader_status(bootloader_status),
      .bootloader_flash_addr(bootloader_flash_addr),
      .bootloader_length(bootloader_length),
      // eth0 MDIO
      .SUBBUS_eth_mdio_Req(eth0_op_req),
      .SUBBUS_eth_mdio_RhWl(eth0_wrl_rdh),
      .SUBBUS_eth_mdio_ReqAddr(eth0_address[11:0]),
      .SUBBUS_eth_mdio_DataWr(eth0_wrdata),
      .SUBBUS_eth_mdio_DataRd(eth0_rddata),
      .SUBBUS_eth_mdio_Ack(eth0_op_ack),
      // eth1 MDIO
      .SUBBUS_eth1_mdio_Req(eth1_op_req),
      .SUBBUS_eth1_mdio_RhWl(eth1_wrl_rdh),
      .SUBBUS_eth1_mdio_ReqAddr(eth1_address[11:0]),
      .SUBBUS_eth1_mdio_DataWr(eth1_wrdata),
      .SUBBUS_eth1_mdio_DataRd(eth1_rddata),
      .SUBBUS_eth1_mdio_Ack(eth1_op_ack),
      // eth2 MDIO
      .SUBBUS_eth2_mdio_Req(eth2_op_req),
      .SUBBUS_eth2_mdio_RhWl(eth2_wrl_rdh),
      .SUBBUS_eth2_mdio_ReqAddr(eth2_address[11:0]),
      .SUBBUS_eth2_mdio_DataWr(eth2_wrdata),
      .SUBBUS_eth2_mdio_DataRd(eth2_rddata),
      .SUBBUS_eth2_mdio_Ack(eth2_op_ack),
      // SPI Flash
      .SUBBUS_sflash_Req(sflash_op_req),
      .SUBBUS_sflash_RhWl(sflash_wrl_rdh),
      .SUBBUS_sflash_ReqAddr(sflash_address),
      .SUBBUS_sflash_DataWr(sflash_wrdata),
      .SUBBUS_sflash_DataRd(sflash_rddata),
      .SUBBUS_sflash_Ack(sflash_op_ack),
      // MAC Whitelist
      .RAMIF_mac_whitelist_Ram_RlWh(wl_ram_rlwh),
      .RAMIF_mac_whitelist_Ram_Addr(wl_ram_addr),
      .RAMIF_mac_whitelist_Ram_WrData(wl_ram_wrdata),
      .RAMIF_mac_whitelist_Ram_RdData(wl_ram_rddata),
      // LED
      .led(led),
      // CPU packet FIFO
      .cpu_rd_empty(cpu_rd_empty),
      .cpu_rd_rpkt_pop(),
      .cpu_rd_rpkt_pop_ind(cpu_rd_rpkt_pop_ind),
      .cpu_rd_rpkt_len(cpu_rd_rpkt_len),
      .cpu_rd_rpkt_para(cpu_rd_rpkt_para),
      .cpu_rd_ren(cpu_rd_ren),
      .cpu_rd_raddr(cpu_rd_raddr),
      .cpu_rd_rdata(cpu_rd_rdata),
      .cpu_rd_reop_pre(cpu_rd_reop_pre),
      .cpu_rd_reg_rw_0(),
      .cpu_rd_reg_rw_1(),
      .cpu_rd_reg_rw_2(),
      .cpu_rd_reg_rw_3(),
      .cpu_rd_reg_ro_0(32'd0),
      .cpu_rd_reg_ro_1(32'd0),
      .cpu_rd_reg_wc_0(),
      .cpu_rd_reg_wc_0_ind(),
      .cpu_rd_reg_rc_0(32'd0),
      .cpu_rd_reg_rc_0_ind(),
      .cpu_wr_full(cpu_wr_full),
      .cpu_wr_wen(),
      .cpu_wr_wen_ind(cpu_wr_wen_ind),
      .cpu_wr_waddr(cpu_wr_waddr),
      .cpu_wr_wdata(cpu_wr_wdata),
      .cpu_wr_wpkt_len(cpu_wr_wpkt_len),
      .cpu_wr_wpkt_para(cpu_wr_wpkt_para),
      .cpu_wr_wpkt_push(),
      .cpu_wr_wpkt_push_ind(cpu_wr_wpkt_push_ind),
      .cpu_wr_reg_rw_0(),
      .cpu_wr_reg_rw_1(),
      .cpu_wr_reg_rw_2(),
      .cpu_wr_reg_rw_3(),
      .cpu_wr_reg_ro_0(),
      .cpu_wr_reg_ro_1(),
      .cpu_wr_reg_wc_0(),
      .cpu_wr_reg_wc_0_ind(),
      .cpu_wr_reg_rc_0(),
      .cpu_wr_reg_rc_0_ind(),
      .cpu_wr_reg_rc_1(),
      .cpu_wr_reg_rc_1_ind(),
      .RAMIF_program_ram_Ram_RlWh(pram_wr_lcpu),
      .RAMIF_program_ram_Ram_Addr(pram_addr_lcpu),
      .RAMIF_program_ram_Ram_WrData(pram_wdata_lcpu),
      .RAMIF_program_ram_Ram_RdData(pram_rdata),
      .clk(clk_50mhz),
      .rst_n(reset_l),
      .req(cpu_req),
      .rhwl(cpu_rhwl),
      .wdata(cpu_wdata),
      .address(cpu_address[15:0]),
      .rdata(cpu_rdata),
      .ack(cpu_ack)
  );

  // ============================================================
  // MDIO controllers
  // ============================================================
  lcpu_mdio u_lcpu_mdio_eth0 (
      .reset_l(reset_l),
      .clk(clk_50mhz),
      .op_req(eth0_op_req),
      .wrl_rdh(eth0_wrl_rdh),
      .wrdata(eth0_wrdata),
      .address(eth0_address),
      .op_ack(eth0_op_ack),
      .rddata(eth0_rddata),
      .mdc(eth0_mdc),
      .mdio(eth0_mdio)
  );
  lcpu_mdio u_lcpu_mdio_eth1 (
      .reset_l(reset_l),
      .clk(clk_50mhz),
      .op_req(eth1_op_req),
      .wrl_rdh(eth1_wrl_rdh),
      .wrdata(eth1_wrdata),
      .address(eth1_address),
      .op_ack(eth1_op_ack),
      .rddata(eth1_rddata),
      .mdc(eth1_mdc),
      .mdio(eth1_mdio)
  );
  lcpu_mdio u_lcpu_mdio_eth2 (
      .reset_l(reset_l),
      .clk(clk_50mhz),
      .op_req(eth2_op_req),
      .wrl_rdh(eth2_wrl_rdh),
      .wrdata(eth2_wrdata),
      .address(eth2_address),
      .op_ack(eth2_op_ack),
      .rddata(eth2_rddata),
      .mdc(eth2_mdc),
      .mdio(eth2_mdio)
  );

  // ============================================================
  // SPI Flash controller (SubBus 0x1400)
  // Internal SPI signals: muxed between lcpu_sflash and bootloader
  // ============================================================
  lcpu_sflash u_lcpu_sflash (
      .reset_l(reset_l),
      .clk(clk_50mhz),
      .op_req(sflash_op_req),
      .wrl_rdh(sflash_wrl_rdh),
      .wrdata(sflash_wrdata),
      .address({20'b0, sflash_address}),
      .op_ack(sflash_op_ack),
      .rddata(sflash_rddata),
      .sclk(spi_sclk_sf),
      .mosi(spi_mosi_sf),
      .miso(flash_miso),
      .cs_n(spi_cs_n_sf),
      .wp_n(flash_wp_n),
      .rst_n(flash_rst_n)
  );

  // ============================================================
  // Bootloader SPI controller (dedicated spi_ctrl, 5MHz)
  // ============================================================
  spi_ctrl #(.cpol(0), .cpha(0)) u_bl_spi (
      .reset_l(reset_l),
      .clk(spi_clk_bl),
      .op_start(bl_spi_op_start),
      .channel_len(bl_spi_channel_len),
      .wdata(bl_spi_wdata),
      .rdata(bl_spi_rdata),
      .op_done(bl_spi_op_done),
      .sck(spi_sclk_bl),
      .mosi(spi_mosi_bl),
      .miso(flash_miso),
      .cs(spi_cs_n_bl)
  );

  // SPI clock divider: 50MHz → 5MHz (divide by 10)
  reg [3:0] spi_clk_div;
  reg       spi_clk_bl;
  always @(posedge clk_50mhz or negedge reset_l) begin
    if (!reset_l) begin
      spi_clk_div <= 0;
      spi_clk_bl  <= 0;
    end else begin
      if (spi_clk_div == 4'd4) begin
        spi_clk_div <= 0;
        spi_clk_bl  <= ~spi_clk_bl;
      end else begin
        spi_clk_div <= spi_clk_div + 1;
      end
    end
  end

  // ============================================================
  // SPI output mux: bootloader takes priority when busy
  // ============================================================
  assign flash_sclk = bootloader_status[0] ? spi_sclk_bl  : spi_sclk_sf;
  assign flash_mosi = bootloader_status[0] ? spi_mosi_bl  : spi_mosi_sf;
  assign flash_cs_n = bootloader_status[0] ? spi_cs_n_bl  : spi_cs_n_sf;

  // ============================================================
  // SPI Bootloader: Flash → InstructRAM
  // ============================================================
  spi_bootloader #(.PRAM_ADDR_WIDTH(instr_addr_width)) u_spi_bootloader (
      .clk(clk_50mhz),
      .reset_l(reset_l),
      .trigger(bootloader_trigger_ind),
      .flash_addr(bootloader_flash_addr),
      .length(bootloader_length),
      .status(bootloader_status),
      .pram_wr(bl_pram_wr),
      .pram_addr(bl_pram_addr),
      .pram_wdata(bl_pram_wdata),
      .spi_op_start(bl_spi_op_start),
      .spi_channel_len(bl_spi_channel_len),
      .spi_wdata(bl_spi_wdata),
      .spi_rdata(bl_spi_rdata),
      .spi_op_done(bl_spi_op_done)
  );

  // ============================================================
  // GMII2MAC instances (one per port)
  // ============================================================
  gmii2mac i_eth0 (
      .clk(clk_125mhz),
      .reset_l(reset_l),
      .Eth_TXD(gmii_txd),
      .Eth_TXEN(gmii_tx_en),
      .Eth_TXER(gmii_tx_err),
      .Eth_RXC(gmii_rx_clk),
      .Eth_RXDV(gmii_rx_dv),
      .Eth_RXER(gmii_rx_err),
      .Eth_RXD(gmii_rxd),
      .mac_rx_sop(eth0_mac_rx_sop),
      .mac_rx_en(eth0_mac_rx_en),
      .mac_rx_data(eth0_mac_rx_data),
      .mac_rx_eop(eth0_mac_rx_eop),
      .mac_rx_err(eth0_mac_rx_err),
      .mac_tx_sop(eth0_mac_tx_sop),
      .mac_tx_en(eth0_mac_tx_en),
      .mac_tx_data(eth0_mac_tx_data),
      .mac_tx_eop(eth0_mac_tx_eop),
      .mac_tx_err(eth0_mac_tx_err),
      .rx_afifo_full_cnt(eth0_rx_afifo_full_cnt_src),
      .rx_afifo_empty_cnt(eth0_rx_afifo_empty_cnt_src),
      .rx_data_err_line(eth0_rx_data_err_line_src),
      .rx_correct_pkt_cnt(eth0_rx_correct_pkt_cnt_src),
      .rx_crc_err_pkt_cnt(eth0_rx_crc_err_pkt_cnt_src),
      .tx_correct_pkt_cnt(eth0_tx_correct_pkt_cnt_src),
      .tx_error_pkt_cnt(eth0_tx_error_pkt_cnt_src)
  );
  gmii2mac i_eth1 (
      .clk(clk_125mhz),
      .reset_l(reset_l),
      .Eth_TXD(gmii1_txd),
      .Eth_TXEN(gmii1_tx_en),
      .Eth_TXER(gmii1_tx_err),
      .Eth_RXC(gmii1_rx_clk),
      .Eth_RXDV(gmii1_rx_dv),
      .Eth_RXER(gmii1_rx_err),
      .Eth_RXD(gmii1_rxd),
      .mac_rx_sop(eth1_mac_rx_sop),
      .mac_rx_en(eth1_mac_rx_en),
      .mac_rx_data(eth1_mac_rx_data),
      .mac_rx_eop(eth1_mac_rx_eop),
      .mac_rx_err(eth1_mac_rx_err),
      .mac_tx_sop(eth1_mac_tx_sop),
      .mac_tx_en(eth1_mac_tx_en),
      .mac_tx_data(eth1_mac_tx_data),
      .mac_tx_eop(eth1_mac_tx_eop),
      .mac_tx_err(eth1_mac_tx_err),
      .rx_afifo_full_cnt(eth1_rx_afifo_full_cnt_src),
      .rx_afifo_empty_cnt(eth1_rx_afifo_empty_cnt_src),
      .rx_data_err_line(eth1_rx_data_err_line_src),
      .rx_correct_pkt_cnt(eth1_rx_correct_pkt_cnt_src),
      .rx_crc_err_pkt_cnt(eth1_rx_crc_err_pkt_cnt_src),
      .tx_correct_pkt_cnt(eth1_tx_correct_pkt_cnt_src),
      .tx_error_pkt_cnt(eth1_tx_error_pkt_cnt_src)
  );
  gmii2mac i_eth2 (
      .clk(clk_125mhz),
      .reset_l(reset_l),
      .Eth_TXD(gmii2_txd),
      .Eth_TXEN(gmii2_tx_en),
      .Eth_TXER(gmii2_tx_err),
      .Eth_RXC(gmii2_rx_clk),
      .Eth_RXDV(gmii2_rx_dv),
      .Eth_RXER(gmii2_rx_err),
      .Eth_RXD(gmii2_rxd),
      .mac_rx_sop(eth2_mac_rx_sop),
      .mac_rx_en(eth2_mac_rx_en),
      .mac_rx_data(eth2_mac_rx_data),
      .mac_rx_eop(eth2_mac_rx_eop),
      .mac_rx_err(eth2_mac_rx_err),
      .mac_tx_sop(eth2_mac_tx_sop),
      .mac_tx_en(eth2_mac_tx_en),
      .mac_tx_data(eth2_mac_tx_data),
      .mac_tx_eop(eth2_mac_tx_eop),
      .mac_tx_err(eth2_mac_tx_err),
      .rx_afifo_full_cnt(eth2_rx_afifo_full_cnt_src),
      .rx_afifo_empty_cnt(eth2_rx_afifo_empty_cnt_src),
      .rx_data_err_line(eth2_rx_data_err_line_src),
      .rx_correct_pkt_cnt(eth2_rx_correct_pkt_cnt_src),
      .rx_crc_err_pkt_cnt(eth2_rx_crc_err_pkt_cnt_src),
      .tx_correct_pkt_cnt(eth2_tx_correct_pkt_cnt_src),
      .tx_error_pkt_cnt(eth2_tx_error_pkt_cnt_src)
  );

  // ============================================================
  // Statistics CDC sync (125MHz → 50MHz) for eth0/eth1/eth2
  // ============================================================
  generate
    if (stat_cnt_en == 1) begin : g_sync_eth0_stats
      cdc_bus_sync_vec #(
          .DATA_WIDTH(32),
          .CHANNELS(7),
          .MODE(0)
      ) u_sync_eth0_stats (
          .src_clk(clk_125mhz),
          .src_rst_l(reset_l),
          .src_data({
            eth0_rx_data_err_line_src,
            eth0_rx_afifo_empty_cnt_src,
            eth0_rx_afifo_full_cnt_src,
            eth0_tx_error_pkt_cnt_src,
            eth0_tx_correct_pkt_cnt_src,
            eth0_rx_crc_err_pkt_cnt_src,
            eth0_rx_correct_pkt_cnt_src
          }),
          .src_valid(7'b0),
          .dst_clk(clk_50mhz),
          .dst_rst_l(reset_l),
          .dst_data({
            eth0_rx_data_err_line,
            eth0_rx_afifo_empty_cnt,
            eth0_rx_afifo_full_cnt,
            eth0_tx_error_pkt_cnt,
            eth0_tx_correct_pkt_cnt,
            eth0_rx_crc_err_pkt_cnt,
            eth0_rx_correct_pkt_cnt
          }),
          .dst_valid(),
          .src_ready()
      );
      cdc_bus_sync_vec #(
          .DATA_WIDTH(32),
          .CHANNELS(7),
          .MODE(0)
      ) u_sync_eth1_stats (
          .src_clk(clk_125mhz),
          .src_rst_l(reset_l),
          .src_data({
            eth1_rx_data_err_line_src,
            eth1_rx_afifo_empty_cnt_src,
            eth1_rx_afifo_full_cnt_src,
            eth1_tx_error_pkt_cnt_src,
            eth1_tx_correct_pkt_cnt_src,
            eth1_rx_crc_err_pkt_cnt_src,
            eth1_rx_correct_pkt_cnt_src
          }),
          .src_valid(7'b0),
          .dst_clk(clk_50mhz),
          .dst_rst_l(reset_l),
          .dst_data({
            eth1_rx_data_err_line,
            eth1_rx_afifo_empty_cnt,
            eth1_rx_afifo_full_cnt,
            eth1_tx_error_pkt_cnt,
            eth1_tx_correct_pkt_cnt,
            eth1_rx_crc_err_pkt_cnt,
            eth1_rx_correct_pkt_cnt
          }),
          .dst_valid(),
          .src_ready()
      );
      cdc_bus_sync_vec #(
          .DATA_WIDTH(32),
          .CHANNELS(7),
          .MODE(0)
      ) u_sync_eth2_stats (
          .src_clk(clk_125mhz),
          .src_rst_l(reset_l),
          .src_data({
            eth2_rx_data_err_line_src,
            eth2_rx_afifo_empty_cnt_src,
            eth2_rx_afifo_full_cnt_src,
            eth2_tx_error_pkt_cnt_src,
            eth2_tx_correct_pkt_cnt_src,
            eth2_rx_crc_err_pkt_cnt_src,
            eth2_rx_correct_pkt_cnt_src
          }),
          .src_valid(7'b0),
          .dst_clk(clk_50mhz),
          .dst_rst_l(reset_l),
          .dst_data({
            eth2_rx_data_err_line,
            eth2_rx_afifo_empty_cnt,
            eth2_rx_afifo_full_cnt,
            eth2_tx_error_pkt_cnt,
            eth2_tx_correct_pkt_cnt,
            eth2_rx_crc_err_pkt_cnt,
            eth2_rx_correct_pkt_cnt
          }),
          .dst_valid(),
          .src_ready()
      );
    end else begin : g_no_sync_stats
      assign {eth0_rx_correct_pkt_cnt, eth0_rx_crc_err_pkt_cnt, eth0_tx_correct_pkt_cnt,
              eth0_tx_error_pkt_cnt, eth0_rx_afifo_full_cnt, eth0_rx_afifo_empty_cnt,
              eth0_rx_data_err_line} = 224'b0;
      assign {eth1_rx_correct_pkt_cnt, eth1_rx_crc_err_pkt_cnt, eth1_tx_correct_pkt_cnt,
              eth1_tx_error_pkt_cnt, eth1_rx_afifo_full_cnt, eth1_rx_afifo_empty_cnt,
              eth1_rx_data_err_line} = 224'b0;
      assign {eth2_rx_correct_pkt_cnt, eth2_rx_crc_err_pkt_cnt, eth2_tx_correct_pkt_cnt,
              eth2_tx_error_pkt_cnt, eth2_rx_afifo_full_cnt, eth2_rx_afifo_empty_cnt,
              eth2_rx_data_err_line} = 224'b0;
    end
  endgenerate

  // ============================================================
  // CDC: wl_ctrl (50MHz → 125MHz, ReqAck)
  // ============================================================
  cdc_bus_sync #(
      .DATA_WIDTH(2),
      .MODE(1)
  ) u_sync_wl_ctrl (
      .src_clk  (clk_50mhz),
      .src_rst_l(reset_l),
      .src_data (wl_ctrl_50m),
      .src_valid(1'b1),
      .dst_clk  (clk_125mhz),
      .dst_rst_l(reset_l),
      .dst_data (wl_ctrl_125m),
      .dst_valid(),
      .src_ready()
  );

  // ============================================================
  // CDC: eth1_rx_drop_cnt (125MHz → 50MHz, Gray)
  // ============================================================
  cdc_bus_sync #(
      .DATA_WIDTH(32),
      .MODE(0)
  ) u_sync_eth1_drop (
      .src_clk  (clk_125mhz),
      .src_rst_l(reset_l),
      .src_data (eth1_rx_drop_cnt_src),
      .src_valid(1'b0),
      .dst_clk  (clk_50mhz),
      .dst_rst_l(reset_l),
      .dst_data (eth1_rx_drop_cnt),
      .dst_valid(),
      .src_ready()
  );

  // ============================================================
  // CDC: recv_pkt_drop_cnt (125MHz → 50MHz, Gray)
  // ============================================================
  cdc_bus_sync #(
      .DATA_WIDTH(8),
      .MODE(0)
  ) u_sync_recv_pkt_drop_cnt (
      .src_clk  (clk_125mhz),
      .src_rst_l(reset_l),
      .src_data (recv_pkt_drop_cnt_src),
      .src_valid(1'b0),
      .dst_clk  (clk_50mhz),
      .dst_rst_l(reset_l),
      .dst_data (recv_pkt_drop_cnt),
      .dst_valid(),
      .src_ready()
  );

  assign debug_ro_0           = {24'b0, recv_pkt_drop_cnt};
  assign debug_ro_1           = eth1_rx_drop_cnt;

  // ============================================================
  // Whitelist config LCPU bus passthrough (SubBus 0x1500)
  // ============================================================
  // Whitelist config: RAMIF passthrough
  // ============================================================
  assign wl_ram_rddata = wl_cfg_rdata;

  // ============================================================
  // MAC Whitelist Engine
  // ============================================================
  // CDC: debug_wc_0_ind (50MHz pulse) → 125MHz manual lookup trigger
  pulse_clock_region_pass u_wl_manual_trig (
      .reset_l(reset_l),
      .clk_a  (clk_50mhz),
      .pulse_a(debug_wc_0_ind),
      .clk_b  (clk_125mhz),
      .pulse_b(wl_manual_lookup_pulse)
  );

  // ILA: Whitelist lookup monitor (depth=2048)
`ifdef ILA_ENABLE
  ila_wrapper #(
      .DATA_DEPTH   (2048),
      .NUM_WINDOWS  (1),
      .NUM_PROBES   (5),
      .PROBE0_WIDTH (1),
      .PROBE1_WIDTH (48),
      .PROBE2_WIDTH (1),
      .PROBE3_WIDTH (1),
      .PROBE4_WIDTH (1)
  ) u_ila_wl_lookup (
      .clk    (clk_125mhz),
      .probe0 (wl_lookup_req_combined),
      .probe1 (wl_lookup_mac),
      .probe2 (wl_lookup_match),
      .probe3 (wl_lookup_done),
      .probe4 (wl_lookup_busy)
  );
`endif

  mac_whitelist_top #(
      .LOOKUP_MODE(0),
      .ENTRY_NUM  (16),
      .ADDR_WIDTH (4)
  ) u_mac_wl (
      .clk(clk_125mhz),
      .reset_l(reset_l),
      .lookup_req(wl_lookup_req_combined),
      .lookup_mac(wl_lookup_mac),
      .lookup_match(wl_lookup_match),
      .lookup_done(wl_lookup_done),
      .lookup_busy(wl_lookup_busy),
      .cfg_clk(clk_50mhz),
      .cfg_reset_l(reset_l),
      .cfg_rlwh(wl_ram_rlwh),
      .cfg_addr(wl_ram_addr),
      .cfg_wdata(wl_ram_wrdata),
      .cfg_rdata(wl_cfg_rdata),
      .whitelist_en(wl_ctrl_125m[0]),
      .default_pass(wl_ctrl_125m[1])
  );

  // ============================================================
  // Three-Port L2 Bridge Channel
  // ============================================================
  cpu_channel_tri #(
      .cpu_buf_addr_width(cpu_buf_addr_width),
      .cpu_buf_block_mode(cpu_buf_block_mode),
      .cpu_buf_block_addr_width(cpu_buf_block_addr_width),
      .cpu_buf_data_width(cpu_buf_data_width),
      .cpu_buf_para_width(cpu_buf_para_width),
      .cpu_buf_data_ram_type(cpu_buf_data_ram_type),
      .cpu_buf_para_ram_type(cpu_buf_para_ram_type),
      .stat_cnt_en(stat_cnt_en)
  ) u_cpu_channel_tri (
      .clk(clk_125mhz),
      .cpu_clk(clk_50mhz),
      .reset_l(reset_l),
      // eth0
      .mac0_rx_sop(eth0_mac_rx_sop),
      .mac0_rx_en(eth0_mac_rx_en),
      .mac0_rx_data(eth0_mac_rx_data),
      .mac0_rx_eop(eth0_mac_rx_eop),
      .mac0_rx_err(eth0_mac_rx_err),
      .mac0_tx_sop(eth0_mac_tx_sop),
      .mac0_tx_en(eth0_mac_tx_en),
      .mac0_tx_data(eth0_mac_tx_data),
      .mac0_tx_eop(eth0_mac_tx_eop),
      .mac0_tx_err(eth0_mac_tx_err),
      // eth1
      .mac1_rx_sop(eth1_mac_rx_sop),
      .mac1_rx_en(eth1_mac_rx_en),
      .mac1_rx_data(eth1_mac_rx_data),
      .mac1_rx_eop(eth1_mac_rx_eop),
      .mac1_rx_err(eth1_mac_rx_err),
      .mac1_tx_sop(eth1_mac_tx_sop),
      .mac1_tx_en(eth1_mac_tx_en),
      .mac1_tx_data(eth1_mac_tx_data),
      .mac1_tx_eop(eth1_mac_tx_eop),
      .mac1_tx_err(eth1_mac_tx_err),
      // eth2
      .mac2_rx_sop(eth2_mac_rx_sop),
      .mac2_rx_en(eth2_mac_rx_en),
      .mac2_rx_data(eth2_mac_rx_data),
      .mac2_rx_eop(eth2_mac_rx_eop),
      .mac2_rx_err(eth2_mac_rx_err),
      .mac2_tx_sop(eth2_mac_tx_sop),
      .mac2_tx_en(eth2_mac_tx_en),
      .mac2_tx_data(eth2_mac_tx_data),
      .mac2_tx_eop(eth2_mac_tx_eop),
      .mac2_tx_err(eth2_mac_tx_err),
      // whitelist
      .wl_lookup_req(wl_lookup_req),
      .wl_lookup_mac(wl_lookup_mac),
      .wl_lookup_match(wl_lookup_match),
      .wl_lookup_done(wl_lookup_done),
      .wl_lookup_busy(wl_lookup_busy),
      // CPU ports
      .cpu_rd_empty(cpu_rd_empty),
      .cpu_rd_rpkt_pop(cpu_rd_rpkt_pop_ind),
      .cpu_rd_rpkt_len(cpu_rd_rpkt_len),
      .cpu_rd_rpkt_para(cpu_rd_rpkt_para),
      .cpu_rd_ren(cpu_rd_ren),
      .cpu_rd_raddr(cpu_rd_raddr),
      .cpu_rd_rdata(cpu_rd_rdata),
      .cpu_rd_reop_pre(cpu_rd_reop_pre),
      .cpu_wr_full(cpu_wr_full),
      .cpu_wr_wen(cpu_wr_wen_ind),
      .cpu_wr_waddr(cpu_wr_waddr),
      .cpu_wr_wdata(cpu_wr_wdata),
      .cpu_wr_wpkt_push(cpu_wr_wpkt_push_ind),
      .cpu_wr_wpkt_len(cpu_wr_wpkt_len),
      .cpu_wr_wpkt_para(cpu_wr_wpkt_para),
      .whitelist_en(wl_ctrl_125m[0]),
      .default_pass(wl_ctrl_125m[1]),
      .eth1_rx_drop_cnt(eth1_rx_drop_cnt_src),
      .recv_pkt_drop_cnt(recv_pkt_drop_cnt_src)
  );
endmodule
