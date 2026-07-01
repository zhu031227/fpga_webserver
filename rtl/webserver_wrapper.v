// webserver_wrapper — platform-independent fpga webserver core
//
// combines:
//   - risc-v cpu subsystem (lcpu + risc-v + bus merge)
//   - register file (reg_webserver)
//   - ethernet gmii mac (gmii2mac)
//   - mdio controller (lcpu_mdio)
//   - cpu-mac data channel (cpu_channel)
//   - timer / local-time counter / debug ram
//
// internal interface: gmii (8-bit sdr)
// xilinx top adds rgmii2gmii for rgmii phy
// altera top connects gmii directly

module webserver_wrapper #(
    parameter int sim_mod = 0,
    parameter script_file = "../tcl/InstructRAM.tcl",
    parameter int second_event_period = 50000000,  // 1s at 50mhz

    // configuration (from platform top)
    parameter int uart_baud_rate           = 115200,
    parameter     cpu_vendor               = "xilinx",                  // "Intel", "xilinx", "UART"
    parameter     device_vendor            = "xilinx",                  // "Intel", "xilinx"
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
    parameter     cpu_buf_data_ram_type    = "M9K",
    parameter     cpu_buf_para_ram_type    = "registers",
    parameter int stat_cnt_en              = 1
) (
    input reset_l,
    input clk_50mhz,  // 50mhz clock from platform top
    input clk_125mhz, // 125mhz clock from platform top

    input  uart_rx,
    output uart_tx,

    // mdio (shared across platforms)
    output eth0_mdc,
    inout  eth0_mdio,

    // internal gmii: rx (from phy or rgmii2gmii)
    input       gmii_rx_clk,
    input       gmii_rx_dv,
    input       gmii_rx_err,
    input [7:0] gmii_rxd,

    // internal gmii: tx (to phy or rgmii2gmii)
    output [7:0] gmii_txd,
    output       gmii_tx_en,
    output       gmii_tx_err,

    output [3:0] led
);

  // build time
  wire [                31:0] fpga_build_date;
  wire [                31:0] fpga_build_time;

  // --- 64-bit local time counter (tod) ---
  wire [                63:0] local_time_counter;
  wire [                31:0] local_time_l = local_time_counter[31:0];
  wire [                31:0] local_time_h = local_time_counter[63:32];

  // --- second event timer ---
  wire                        second_event;

  // --- cpu subsystem: lcpu + risc-v + bus merge ---
  // reuses fpga_cpu/rtl/lcpu_riscv_wrapper.v

  wire                        cpu_req;
  wire                        cpu_rhwl;
  wire [                31:0] cpu_wdata;
  wire [                31:0] cpu_address;
  wire [                31:0] cpu_rdata;
  wire                        cpu_ack;

  // instruction ram interface
  wire                        pram_wr;
  wire [instr_addr_width-1:0] pram_addr;
  wire [                31:0] pram_wdata;
  wire [                31:0] pram_rdata;

  // --- register signals ---
  wire                        get_local_time;
  wire [                31:0] debug_rw_0;  // 50MHz, debug reg
  wire [                15:0] filter_data_src;  // 50MHz, from reg_webserver
  wire [                15:0] filter_data_synced;  // 125MHz, REQACK → cpu_channel
  wire [                15:0] filter_offset_src;
  wire [                15:0] filter_offset_synced;
  wire [                31:0] debug_rw_1;
  wire [                31:0] debug_ro_0;  // 50MHz, assembled → reg_webserver
  wire [                 7:0] recv_pkt_drop_cnt_src;  // 125MHz, from cpu_channel
  wire [                 7:0] recv_pkt_drop_cnt;  // 50MHz, GRAY synced → debug_ro_0
  wire [                31:0] debug_ro_1;
  wire [                 3:0] eth_greset;

  // ethernet mdio sub-bus
  wire eth0_op_req, eth0_wrl_rdh;
  wire [31:0] eth0_wrdata, eth0_address;
  wire                          eth0_op_ack;
  wire [                  31:0] eth0_rddata;

  // eth0 statistics (125MHz domain, from gmii2mac)
  wire [                  31:0] eth0_rx_correct_pkt_cnt_src;
  wire [                  31:0] eth0_rx_crc_err_pkt_cnt_src;
  wire [                  31:0] eth0_tx_correct_pkt_cnt_src;
  wire [                  31:0] eth0_tx_error_pkt_cnt_src;
  wire [                  31:0] eth0_rx_afifo_full_cnt_src;
  wire [                  31:0] eth0_rx_afifo_empty_cnt_src;
  wire [                  31:0] eth0_rx_data_err_line_src;

  // eth0 statistics（50MHz domain, Gray同步后送 reg_webserver）
  wire [                  31:0] eth0_rx_correct_pkt_cnt;
  wire [                  31:0] eth0_rx_crc_err_pkt_cnt;
  wire [                  31:0] eth0_tx_correct_pkt_cnt;
  wire [                  31:0] eth0_tx_error_pkt_cnt;
  wire [                  31:0] eth0_rx_afifo_full_cnt;
  wire [                  31:0] eth0_rx_afifo_empty_cnt;
  wire [                  31:0] eth0_rx_data_err_line;

  // cpu packet channel
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

  // --- gmii to mac packet interface (from ip_common) ---
  wire eth0_mac_rx_sop, eth0_mac_rx_en, eth0_mac_rx_eop, eth0_mac_rx_err;
  wire [7:0] eth0_mac_rx_data;
  wire eth0_mac_tx_sop, eth0_mac_tx_en, eth0_mac_tx_eop, eth0_mac_tx_err;
  wire [ 7:0] eth0_mac_tx_data;

  // --- filter config change detectors + REQACK CDC (50MHz → 125MHz) ---
  reg  [15:0] filter_data_prev;
  wire        filter_data_valid;
  wire        filter_data_reqack_ready;
  reg  [15:0] filter_offset_prev;
  wire        filter_offset_valid;
  wire        filter_offset_reqack_ready;

  // led (active low on acx750)

  tod #(
      .counter_mode(1),  // 1=standard
      .step        (20)  // 每个时钟+20
  ) u_tod (
      .clk         (clk_50mhz),
      .reset_l     (reset_l),
      .snapshot    (get_local_time),
      .counter_live(),
      .time_out    (local_time_counter)  // snapshot
  );
  interval_timer #(
      .counter_width(26),
      .period_count (second_event_period),
      .output_mode  (0)                     // 0=toggle
  ) u_second_timer (
      .clk      (clk_50mhz),
      .reset_l  (reset_l),
      .event_out(second_event)
  );

  // --- fpga build time stamp ---
  fpga_build_time u_fpga_build_time (
      .build_date(fpga_build_date),
      .build_time(fpga_build_time)
  );

  lcpu_riscv_wrapper #(
      .sim_mod           (sim_mod),
      .script_file       (script_file),
      .lcpu_type         (cpu_vendor),
      .uart_baud_rate    (uart_baud_rate),
      .riscv_inst_en     (riscv_inst_en),
      .instr_databits    (32),
      .init_addr_width   (instr_addr_width),
      .init_addr_depth   (instr_addr_depth),
      .device_vendor     (device_vendor),
      .instr_ram_type    (instr_ram_type),
      .init_blockram_size(init_blockram_size),
      .enable_irq        (0),
      .enable_irq_qregs  (1),
      .progaddr_irq      (16)
  ) u_cpu_subsystem (
      .clk          (clk_50mhz),
      .reset_l      (reset_l),
      .uart_rx      (uart_rx),
      .uart_tx      (uart_tx),
      .riscv_reset_l(riscv_reset_l),

      .pram_wr   (pram_wr),
      .pram_addr (pram_addr),
      .pram_wdata(pram_wdata),
      .pram_rdata(pram_rdata),

      .req    (cpu_req),
      .rhwl   (cpu_rhwl),
      .wdata  (cpu_wdata),
      .address(cpu_address),
      .ack    (cpu_ack),
      .rdata  (cpu_rdata)
  );

  // --- register file ---
  reg_webserver u_reg (
      .fpga_build_date             (fpga_build_date),
      .fpga_build_time             (fpga_build_time),
      .sw_build_date               (),
      .sw_build_time               (),
      .eth_greset                  (eth_greset),
      .second_event                (second_event),
      .get_local_time              (),
      .get_local_time_ind          (get_local_time),
      .local_time_l                (local_time_l),
      .local_time_h                (local_time_h),
      .riscv_reset_l               (riscv_reset_l),
      .debug_rw_0                  (debug_rw_0),
      .debug_rw_1                  (debug_rw_1),
      .debug_rw_2                  (),
      .debug_rw_3                  (),
      .filter_data                 (filter_data_src),
      .filter_offset               (filter_offset_src),
      .debug_ro_0                  (debug_ro_0),
      .debug_ro_1                  (debug_ro_1),
      .debug_ro_2                  (32'd0),
      .debug_ro_3                  (32'd0),
      .eth_rx_correct_pkt_cnt      (eth0_rx_correct_pkt_cnt),
      .eth_rx_crc_err_pkt_cnt      (eth0_rx_crc_err_pkt_cnt),
      .eth_tx_correct_pkt_cnt      (eth0_tx_correct_pkt_cnt),
      .eth_tx_error_pkt_cnt        (eth0_tx_error_pkt_cnt),
      .eth_rx_afifo_full_cnt       (eth0_rx_afifo_full_cnt),
      .eth_rx_afifo_empty_cnt      (eth0_rx_afifo_empty_cnt),
      .eth_rx_data_err_line        (eth0_rx_data_err_line),
      .SUBBUS_eth_mdio_Req         (eth0_op_req),
      .SUBBUS_eth_mdio_RhWl        (eth0_wrl_rdh),
      .SUBBUS_eth_mdio_ReqAddr     (eth0_address[11:0]),
      .SUBBUS_eth_mdio_DataWr      (eth0_wrdata),
      .SUBBUS_eth_mdio_DataRd      (eth0_rddata),
      .SUBBUS_eth_mdio_Ack         (eth0_op_ack),
      .led                         (led),
      .cpu_rd_empty                (cpu_rd_empty),
      .cpu_rd_rpkt_pop             (),
      .cpu_rd_rpkt_pop_ind         (cpu_rd_rpkt_pop_ind),
      .cpu_rd_rpkt_len             (cpu_rd_rpkt_len),
      .cpu_rd_rpkt_para            (cpu_rd_rpkt_para),
      .cpu_rd_ren                  (cpu_rd_ren),
      .cpu_rd_raddr                (cpu_rd_raddr),
      .cpu_rd_rdata                (cpu_rd_rdata),
      .cpu_rd_reop_pre             (cpu_rd_reop_pre),
      .cpu_rd_reg_rw_0             (),
      .cpu_rd_reg_rw_1             (),
      .cpu_rd_reg_rw_2             (),
      .cpu_rd_reg_rw_3             (),
      .cpu_rd_reg_ro_0             (32'd0),
      .cpu_rd_reg_ro_1             (32'd0),
      .cpu_rd_reg_wc_0             (),
      .cpu_rd_reg_wc_0_ind         (),
      .cpu_rd_reg_rc_0             (32'd0),
      .cpu_rd_reg_rc_0_ind         (),
      .cpu_wr_full                 (cpu_wr_full),
      .cpu_wr_wen                  (),
      .cpu_wr_wen_ind              (cpu_wr_wen_ind),
      .cpu_wr_waddr                (cpu_wr_waddr),
      .cpu_wr_wdata                (cpu_wr_wdata),
      .cpu_wr_wpkt_len             (cpu_wr_wpkt_len),
      .cpu_wr_wpkt_para            (cpu_wr_wpkt_para),
      .cpu_wr_wpkt_push            (),
      .cpu_wr_wpkt_push_ind        (cpu_wr_wpkt_push_ind),
      .cpu_wr_reg_rw_0             (),
      .cpu_wr_reg_rw_1             (),
      .cpu_wr_reg_rw_2             (),
      .cpu_wr_reg_rw_3             (),
      .cpu_wr_reg_ro_0             (),
      .cpu_wr_reg_ro_1             (),
      .cpu_wr_reg_wc_0             (),
      .cpu_wr_reg_wc_0_ind         (),
      .cpu_wr_reg_rc_0             (),
      .cpu_wr_reg_rc_0_ind         (),
      .cpu_wr_reg_rc_1             (),
      .cpu_wr_reg_rc_1_ind         (),
      .RAMIF_program_ram_Ram_RlWh  (pram_wr),
      .RAMIF_program_ram_Ram_Addr  (pram_addr),
      .RAMIF_program_ram_Ram_WrData(pram_wdata),
      .RAMIF_program_ram_Ram_RdData(pram_rdata),
      .clk                         (clk_50mhz),
      .rst_n                       (reset_l),
      .req                         (cpu_req),
      .rhwl                        (cpu_rhwl),
      .wdata                       (cpu_wdata),
      .address                     (cpu_address[15:0]),
      .rdata                       (cpu_rdata),
      .ack                         (cpu_ack)
  );

  // --- mdio controller (from ip_common) ---
  lcpu_mdio u_lcpu_mdio_eth0 (
      .reset_l(reset_l),
      .clk    (clk_50mhz),

      .op_req (eth0_op_req),
      .wrl_rdh(eth0_wrl_rdh),
      .wrdata (eth0_wrdata),
      .address(eth0_address),
      .op_ack (eth0_op_ack),
      .rddata (eth0_rddata),

      .mdc (eth0_mdc),
      .mdio(eth0_mdio)
  );

  gmii2mac i_eth0 (
      .clk    (clk_125mhz),
      .reset_l(reset_l),

      .Eth_TXD (gmii_txd),
      .Eth_TXEN(gmii_tx_en),
      .Eth_TXER(gmii_tx_err),

      .Eth_RXC (gmii_rx_clk),
      .Eth_RXDV(gmii_rx_dv),
      .Eth_RXER(gmii_rx_err),
      .Eth_RXD (gmii_rxd),

      .mac_rx_sop (eth0_mac_rx_sop),
      .mac_rx_en  (eth0_mac_rx_en),
      .mac_rx_data(eth0_mac_rx_data),
      .mac_rx_eop (eth0_mac_rx_eop),
      .mac_rx_err (eth0_mac_rx_err),
      .mac_tx_sop (eth0_mac_tx_sop),
      .mac_tx_en  (eth0_mac_tx_en),
      .mac_tx_data(eth0_mac_tx_data),
      .mac_tx_eop (eth0_mac_tx_eop),
      .mac_tx_err (eth0_mac_tx_err),

      .rx_afifo_full_cnt (eth0_rx_afifo_full_cnt_src),
      .rx_afifo_empty_cnt(eth0_rx_afifo_empty_cnt_src),
      .rx_data_err_line  (eth0_rx_data_err_line_src),
      .rx_correct_pkt_cnt(eth0_rx_correct_pkt_cnt_src),
      .rx_crc_err_pkt_cnt(eth0_rx_crc_err_pkt_cnt_src),
      .tx_correct_pkt_cnt(eth0_tx_correct_pkt_cnt_src),
      .tx_error_pkt_cnt  (eth0_tx_error_pkt_cnt_src)
  );

  // --- eth0 statistics CDC sync (125MHz → 50MHz) ---
  generate
      if (stat_cnt_en == 1) begin : g_sync_eth0_stats
          cdc_bus_sync_vec #(
              .DATA_WIDTH(32),
              .CHANNELS  (7),
              .MODE      (0)
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
      end else begin : g_no_sync_eth0_stats
          assign eth0_rx_correct_pkt_cnt  = 32'b0;
          assign eth0_rx_crc_err_pkt_cnt  = 32'b0;
          assign eth0_tx_correct_pkt_cnt  = 32'b0;
          assign eth0_tx_error_pkt_cnt    = 32'b0;
          assign eth0_rx_afifo_full_cnt   = 32'b0;
          assign eth0_rx_afifo_empty_cnt  = 32'b0;
          assign eth0_rx_data_err_line    = 32'b0;
      end
  endgenerate

  // filter_data change detector (50MHz)
  always @(posedge clk_50mhz or negedge reset_l) begin
    if (!reset_l) begin
      filter_data_prev <= 16'b0;
    end else begin
      filter_data_prev <= filter_data_src;
    end
  end
  assign filter_data_valid = (filter_data_src != filter_data_prev);

  cdc_bus_sync #(
      .DATA_WIDTH(16),
      .MODE      (1)
  ) u_sync_filter_data (
      .src_clk  (clk_50mhz),
      .src_rst_l(reset_l),
      .src_data (filter_data_src),
      .src_valid(filter_data_valid),
      .dst_clk  (clk_125mhz),
      .dst_rst_l(reset_l),
      .dst_data (filter_data_synced),
      .dst_valid(),
      .src_ready(filter_data_reqack_ready)
  );

  // filter_offset change detector (50MHz)
  always @(posedge clk_50mhz or negedge reset_l) begin
    if (!reset_l) begin
      filter_offset_prev <= 16'b0;
    end else begin
      filter_offset_prev <= filter_offset_src;
    end
  end
  assign filter_offset_valid = (filter_offset_src != filter_offset_prev);

  cdc_bus_sync #(
      .DATA_WIDTH(16),
      .MODE      (1)
  ) u_sync_filter_offset (
      .src_clk  (clk_50mhz),
      .src_rst_l(reset_l),
      .src_data (filter_offset_src),
      .src_valid(filter_offset_valid),
      .dst_clk  (clk_125mhz),
      .dst_rst_l(reset_l),
      .dst_data (filter_offset_synced),
      .dst_valid(),
      .src_ready(filter_offset_reqack_ready)
  );

  // --- recv_pkt_drop_cnt GRAY CDC (125MHz → 50MHz) ---
  generate
    if (stat_cnt_en == 1) begin : g_stat_cnt
      cdc_bus_sync #(
          .DATA_WIDTH(8),
          .MODE      (0)
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

      assign debug_ro_0 = {24'b0, recv_pkt_drop_cnt};
    end else begin : g_no_stat_cnt
      assign debug_ro_0 = 32'b0;
    end
  endgenerate

  // --- cpu-mac data channel ---
  cpu_channel #(
      .cpu_buf_addr_width      (cpu_buf_addr_width),
      .cpu_buf_block_mode      (cpu_buf_block_mode),
      .cpu_buf_block_addr_width(cpu_buf_block_addr_width),
      .cpu_buf_data_width      (cpu_buf_data_width),
      .cpu_buf_para_width      (cpu_buf_para_width),
      .cpu_buf_data_ram_type   (cpu_buf_data_ram_type),
      .cpu_buf_para_ram_type   (cpu_buf_para_ram_type)
  ) u_cpu_channel (
      .clk    (clk_125mhz),
      .cpu_clk(clk_50mhz),
      .reset_l(reset_l),

      .mac_rx_sop (eth0_mac_rx_sop),
      .mac_rx_en  (eth0_mac_rx_en),
      .mac_rx_data(eth0_mac_rx_data),
      .mac_rx_eop (eth0_mac_rx_eop),
      .mac_rx_err (eth0_mac_rx_err),

      .mac_tx_sop (eth0_mac_tx_sop),
      .mac_tx_en  (eth0_mac_tx_en),
      .mac_tx_data(eth0_mac_tx_data),
      .mac_tx_eop (eth0_mac_tx_eop),
      .mac_tx_err (eth0_mac_tx_err),

      .filter_data      (filter_data_synced),
      .filter_offset    (filter_offset_synced),
      .recv_pkt_drop_cnt(recv_pkt_drop_cnt_src),

      .cpu_rd_empty    (cpu_rd_empty),
      .cpu_rd_rpkt_pop (cpu_rd_rpkt_pop_ind),
      .cpu_rd_rpkt_len (cpu_rd_rpkt_len),
      .cpu_rd_rpkt_para(cpu_rd_rpkt_para),
      .cpu_rd_ren      (cpu_rd_ren),
      .cpu_rd_raddr    (cpu_rd_raddr),
      .cpu_rd_rdata    (cpu_rd_rdata),
      .cpu_rd_reop_pre (cpu_rd_reop_pre),

      .cpu_wr_full     (cpu_wr_full),
      .cpu_wr_wen      (cpu_wr_wen_ind),
      .cpu_wr_waddr    (cpu_wr_waddr),
      .cpu_wr_wdata    (cpu_wr_wdata),
      .cpu_wr_wpkt_push(cpu_wr_wpkt_push_ind),
      .cpu_wr_wpkt_len (cpu_wr_wpkt_len),
      .cpu_wr_wpkt_para(cpu_wr_wpkt_para)
  );
endmodule
