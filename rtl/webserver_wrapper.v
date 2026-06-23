// webserver_wrapper — Platform-independent FPGA WebServer core
//
// Combines:
//   - RISC-V CPU subsystem (LCPU + RISC-V + bus merge)
//   - Register file (reg_webserver)
//   - Ethernet GMII MAC (gmii2mac)
//   - MDIO controller (lcpu_mdio)
//   - CPU-MAC data channel (cpu_channel)
//   - Timer / local-time counter / debug RAM
//
// Internal interface: GMII (8-bit SDR)
// Xilinx top adds rgmii2gmii for RGMII PHY
// Altera top connects GMII directly

module webserver_wrapper #(
    parameter debug_en = 0,
    parameter lcpu_inst_en = 1,
    parameter second_event_period = 50000000,  // 1s at 50MHz
    parameter pll_bypass = 0,
    parameter Xilinx_IDELAY_VALUE = 16
) (
    input clk,
    input reset_l,
    input clk_50Mhz_in,    // PLL bypass: 50MHz clock in
    input clk_125Mhz_in,   // PLL bypass: 125MHz clock in
    input clk_200Mhz_in,   // PLL bypass: 200MHz clock in

    input  uart_rx,
    output uart_tx,

    // MDIO (shared across platforms)
    output Eth0_MDC,
    inout  Eth0_MDIO,

    // Internal GMII: RX (from PHY or rgmii2gmii)
    input        gmii_rx_clk,
    input        gmii_rx_dv,
    input        gmii_rx_err,
    input  [7:0] gmii_rxd,

    // Internal GMII: TX (to PHY or rgmii2gmii)
    input        gmii_tx_clk,
    output [7:0] gmii_txd,
    output       gmii_tx_en,
    output       gmii_tx_err,

    output [3:0] Led
);

  localparam VersionID = 32'h80000008;
  localparam FPGA_Time = 32'h06152038;

  localparam uart_baud_rate = 115200;
  localparam cpu_vendor = "AMD";     // "Intel", "AMD", "UART"
  localparam device_vendor = "AMD";  // "Intel", "AMD"

  localparam riscv_inst_en = 1;

  // Instruction RAM
  localparam instr_ram_type = "block";
  localparam instr_addr_depth = 1024*12;  // 12288 x 32-bit words
  localparam instr_addr_width = $clog2(instr_addr_depth);
  localparam init_BlockRAM_Size = 32;
  localparam lcpu_init_instru = 1;
  localparam amd_coe_init_instru = 0;
  localparam intel_hex_init_instru = 0;

  // CPU packet buffer
  localparam cpu_buf_addr_width = 12;
  localparam cpu_buf_block_mode = "false";
  localparam cpu_buf_block_addr_width = 2;
  localparam cpu_buf_data_width = 8;
  localparam cpu_buf_para_width = 1;
  localparam cpu_buf_data_ram_type = "M9K";
  localparam cpu_buf_para_ram_type = "registers";

  // Clocks
  wire clk_50Mhz;
  wire clk_125Mhz;
  wire clk_200Mhz;

  // LED (active low on ACX750)
  wire [3:0] Led_L;
  assign Led = ~Led_L;

  // --- PLL or bypass ---
  generate
    if (pll_bypass == 1) begin : pll_bypass_gen
      assign clk_50Mhz  = clk_50Mhz_in;
      assign clk_125Mhz = clk_125Mhz_in;
      assign clk_200Mhz = clk_200Mhz_in;
    end else begin : pll_inst_gen
      PLL_50M U_PLL (
          .inclk0 (clk),
          .c0     (clk_50Mhz),
          .c1     (clk_125Mhz),
          .c2     (clk_200Mhz),
          .locked ()
      );
    end
  endgenerate

  // --- 64-bit free-running local time counter ---
  reg  [63:0] local_time_counter;
  wire [31:0] local_time_l;
  wire [31:0] local_time_h;
  assign local_time_l = local_time_counter[31:0];
  assign local_time_h = local_time_counter[63:32];

  always @(negedge reset_l or posedge clk_50Mhz)
    if (reset_l == 1'b0) begin
      local_time_counter <= 64'b0;
    end else begin
      local_time_counter <= local_time_counter + 1;
    end

  // --- Second event timer ---
  reg  [25:0] second_event_cnt;
  reg         second_event;

  always @(negedge reset_l or posedge clk_50Mhz)
    if (reset_l == 1'b0) begin
      second_event <= 1'b0;
      second_event_cnt <= 26'b0;
    end else begin
      if (second_event_cnt > second_event_period - 1) begin
        second_event_cnt <= 26'b0;
        second_event <= !second_event;
      end else begin
        second_event_cnt <= second_event_cnt + 1;
      end
    end

  // --- CPU subsystem: LCPU + RISC-V + bus merge ---
  // Follows fpga_cpu's lcpu_riscv_wrapper pattern

  wire        jtag_req;
  wire        jtag_rhwl;
  wire [31:0] jtag_wdata;
  wire [31:0] jtag_address;
  wire [31:0] jtag_rdata;
  wire        jtag_ack;

  wire        riscv_req;
  wire        riscv_rhwl;
  wire [31:0] riscv_wdata;
  wire [31:0] riscv_address;
  wire [31:0] riscv_rdata;
  wire        riscv_ack;

  wire        cpu_req;
  wire        cpu_rhwl;
  wire [31:0] cpu_wdata;
  wire [31:0] cpu_address;
  wire [31:0] cpu_rdata;
  wire        cpu_ack;

  // Instruction RAM interface
  wire                        pram_wr;
  wire [instr_addr_width-1:0] pram_addr;
  wire [               31:0] pram_wdata;
  wire [               31:0] pram_rdata;

  // LCPU JTAG/UART master (from ip_lcpu)
  lcpu_top #(
      .lcpu_vendor(cpu_vendor),
      .device_vendor(device_vendor),
      .uart_baud_rate(uart_baud_rate)
  ) u_lcpu (
      .clk    (clk_50Mhz),
      .reset_l(reset_l),
      .uart_rx(uart_rx),
      .uart_tx(uart_tx),

      .jtag_rhwl    (jtag_rhwl),
      .jtag_req     (jtag_req),
      .jtag_ack     (jtag_ack),
      .jtag_address (jtag_address),
      .jtag_wdata   (jtag_wdata),
      .jtag_rdata   (jtag_rdata)
  );

  // RISC-V CPU core (from ip_riscv)
  riscv32_top #(
      .instr_databits    (32),
      .instr_ram_type    (instr_ram_type),
      .init_addr_width   (instr_addr_width),
      .init_addr_depth   (instr_addr_depth),
      .init_blockram_size(init_BlockRAM_Size),
      .vendor            (device_vendor),
      .enable_irq        (0),
      .enable_irq_qregs  (1),
      .progaddr_irq      (16)
  ) u_riscv_cpu (
      .clk          (clk_50Mhz),
      .reset_l      (reset_l),
      .req          (riscv_req),
      .rhwl         (riscv_rhwl),
      .wr_byte_en   (),
      .wdata        (riscv_wdata),
      .address      (riscv_address),
      .rdata        (riscv_rdata),
      .ack          (riscv_ack),
      .program_wr   (pram_wr),
      .program_waddr(pram_addr[instr_addr_width-1:0]),
      .program_wdata(pram_wdata),
      .program_rdata(pram_rdata),
      .irq          (32'b0)
  );

  // Dual-master bus arbiter (from ip_common)
  lcpu_merge #(
      .addr_width(32),
      .data_width(32)
  ) u_lcpu_merge (
      .reset_l(reset_l),
      .clk    (clk_50Mhz),

      .op_req_1  (jtag_req),
      .wrl_rdh_1 (jtag_rhwl),
      .wrdata_1  (jtag_wdata),
      .address_1 (jtag_address),
      .op_ack_1  (jtag_ack),
      .rddata_1  (jtag_rdata),

      .op_req_2  (riscv_req),
      .wrl_rdh_2 (riscv_rhwl),
      .wrdata_2  (riscv_wdata),
      .address_2 (riscv_address),
      .op_ack_2  (riscv_ack),
      .rddata_2  (riscv_rdata),

      .op_req  (cpu_req),
      .wrl_rdh (cpu_rhwl),
      .wrdata  (cpu_wdata),
      .address (cpu_address),
      .op_ack  (cpu_ack),
      .rddata  (cpu_rdata)
  );

  // --- Register signals ---
  wire        get_local_time;
  wire        get_local_time_ind;
  wire [31:0] debug_RW_0;
  wire [31:0] debug_RW_1;
  wire [31:0] debug_RO_0;
  wire [31:0] debug_RO_1;
  wire [ 3:0] Eth_GRESET;

  // Ethernet MDIO sub-bus
  wire        eth0_op_req, eth0_wrl_rdh;
  wire [31:0] eth0_wrdata, eth0_address;
  wire        eth0_op_ack;
  wire [31:0] eth0_rddata;

  // Eth0 statistics
  wire [31:0] eth0_rx_correct_pkt_cnt;
  wire [31:0] eth0_rx_crc_err_pkt_cnt;
  wire [31:0] eth0_tx_correct_pkt_cnt;
  wire [31:0] eth0_tx_error_pkt_cnt;
  wire [31:0] eth0_rx_afifo_full_cnt;
  wire [31:0] eth0_rx_afifo_empty_cnt;
  wire [31:0] eth0_rx_data_err_line;

  // Eth1 statistics (reserved, tied to 0)
  wire [31:0] eth1_zero = 32'b0;

  // CPU packet channel
  wire cpu_rd_empty;
  wire cpu_rd_rpkt_pop_ind;
  wire [cpu_buf_addr_width:0] cpu_rd_rpkt_len;
  wire [cpu_buf_para_width-1:0] cpu_rd_rpkt_para;
  wire cpu_rd_ren;
  wire [cpu_buf_addr_width-1:0] cpu_rd_raddr;
  wire [cpu_buf_data_width-1:0] cpu_rd_rdata;
  wire cpu_rd_reop_pre;
  wire [31:0] cpu_rd_reg_rw_0, cpu_rd_reg_rw_1, cpu_rd_reg_rw_2, cpu_rd_reg_rw_3;
  wire [31:0] cpu_rd_reg_ro_0, cpu_rd_reg_ro_1;
  wire [31:0] cpu_rd_reg_wc_0;
  wire cpu_rd_reg_wc_0_ind;
  wire [31:0] cpu_rd_reg_rc_0;
  wire cpu_rd_reg_rc_0_ind;

  wire cpu_wr_full;
  wire cpu_wr_wen_ind;
  wire [cpu_buf_addr_width-1:0] cpu_wr_waddr;
  wire [cpu_buf_data_width-1:0] cpu_wr_wdata;
  wire [cpu_buf_addr_width:0] cpu_wr_wpkt_len;
  wire [cpu_buf_para_width-1:0] cpu_wr_wpkt_para;
  wire cpu_wr_wpkt_push_ind;
  wire [0:0] cpu_wr_reg_rw_0;
  wire [31:0] cpu_wr_reg_rw_1, cpu_wr_reg_rw_2, cpu_wr_reg_rw_3;
  wire [31:0] cpu_wr_reg_ro_0, cpu_wr_reg_ro_1;
  wire [31:0] cpu_wr_reg_wc_0;
  wire cpu_wr_reg_wc_0_ind;
  wire [31:0] cpu_wr_reg_rc_0, cpu_wr_reg_rc_1;
  wire cpu_wr_reg_rc_0_ind, cpu_wr_reg_rc_1_ind;

  // Debug RAM
  wire        RAMIF_dbg_ram_0_Ram_RlWh;
  wire [11:0] RAMIF_dbg_ram_0_Ram_Addr;
  wire [31:0] RAMIF_dbg_ram_0_Ram_WrData;
  wire [31:0] RAMIF_dbg_ram_0_Ram_RdData;

  // --- Register file ---
  reg_webserver u_reg (
      .version_time           (FPGA_Time),
      .Eth_GRESET             (Eth_GRESET),
      .second_event           (second_event),
      .get_local_time         (get_local_time),
      .get_local_time_ind     (get_local_time_ind),
      .local_time_l           (local_time_l),
      .local_time_h           (local_time_h),
      .debug_RW_0             (debug_RW_0),
      .debug_RW_1             (debug_RW_1),
      .debug_RO_0             (debug_RO_0),
      .debug_RO_1             (debug_RO_1),

      .eth0_rx_correct_pkt_cnt(eth0_rx_correct_pkt_cnt),
      .eth0_rx_crc_err_pkt_cnt(eth0_rx_crc_err_pkt_cnt),
      .eth0_tx_correct_pkt_cnt(eth0_tx_correct_pkt_cnt),
      .eth0_tx_error_pkt_cnt  (eth0_tx_error_pkt_cnt),
      .eth0_rx_afifo_full_cnt (eth0_rx_afifo_full_cnt),
      .eth0_rx_afifo_empty_cnt(eth0_rx_afifo_empty_cnt),
      .eth0_rx_data_err_line  (eth0_rx_data_err_line),

      .eth1_rx_correct_pkt_cnt(eth1_zero),
      .eth1_rx_crc_err_pkt_cnt(eth1_zero),
      .eth1_tx_correct_pkt_cnt(eth1_zero),
      .eth1_tx_error_pkt_cnt  (eth1_zero),
      .eth1_rx_afifo_full_cnt (eth1_zero),
      .eth1_rx_afifo_empty_cnt(eth1_zero),
      .eth1_rx_data_err_line  (eth1_zero),

      .SUBBUS_Eth0_Req    (eth0_op_req),
      .SUBBUS_Eth0_RhWl   (eth0_wrl_rdh),
      .SUBBUS_Eth0_ReqAddr(eth0_address[11:0]),
      .SUBBUS_Eth0_DataWr (eth0_wrdata),
      .SUBBUS_Eth0_DataRd (eth0_rddata),
      .SUBBUS_Eth0_Ack    (eth0_op_ack),

      .SUBBUS_Eth1_Req    (),
      .SUBBUS_Eth1_RhWl   (),
      .SUBBUS_Eth1_ReqAddr(),
      .SUBBUS_Eth1_DataWr (),
      .SUBBUS_Eth1_DataRd (32'b0),
      .SUBBUS_Eth1_Ack    (1'b0),

      .RAMIF_dbg_ram_0_Ram_RlWh  (RAMIF_dbg_ram_0_Ram_RlWh),
      .RAMIF_dbg_ram_0_Ram_Addr  (RAMIF_dbg_ram_0_Ram_Addr),
      .RAMIF_dbg_ram_0_Ram_WrData(RAMIF_dbg_ram_0_Ram_WrData),
      .RAMIF_dbg_ram_0_Ram_RdData(RAMIF_dbg_ram_0_Ram_RdData),

      .cpu_rd_empty        (cpu_rd_empty),
      .cpu_rd_rpkt_pop     (),
      .cpu_rd_rpkt_pop_ind (cpu_rd_rpkt_pop_ind),
      .cpu_rd_rpkt_len     (cpu_rd_rpkt_len),
      .cpu_rd_rpkt_para    (cpu_rd_rpkt_para),
      .cpu_rd_ren          (cpu_rd_ren),
      .cpu_rd_raddr        (cpu_rd_raddr),
      .cpu_rd_rdata        (cpu_rd_rdata),
      .cpu_rd_reop_pre     (cpu_rd_reop_pre),
      .cpu_rd_reg_rw_0     (cpu_rd_reg_rw_0),
      .cpu_rd_reg_rw_1     (cpu_rd_reg_rw_1),
      .cpu_rd_reg_rw_2     (cpu_rd_reg_rw_2),
      .cpu_rd_reg_rw_3     (cpu_rd_reg_rw_3),
      .cpu_rd_reg_ro_0     (cpu_rd_reg_ro_0),
      .cpu_rd_reg_ro_1     (cpu_rd_reg_ro_1),
      .cpu_rd_reg_wc_0     (cpu_rd_reg_wc_0),
      .cpu_rd_reg_wc_0_ind (cpu_rd_reg_wc_0_ind),
      .cpu_rd_reg_rc_0     (cpu_rd_reg_rc_0),
      .cpu_rd_reg_rc_0_ind (cpu_rd_reg_rc_0_ind),

      .cpu_wr_full         (cpu_wr_full),
      .cpu_wr_wen          (),
      .cpu_wr_wen_ind      (cpu_wr_wen_ind),
      .cpu_wr_waddr        (cpu_wr_waddr),
      .cpu_wr_wdata        (cpu_wr_wdata),
      .cpu_wr_wpkt_len     (cpu_wr_wpkt_len),
      .cpu_wr_wpkt_para    (cpu_wr_wpkt_para),
      .cpu_wr_wpkt_push    (),
      .cpu_wr_wpkt_push_ind(cpu_wr_wpkt_push_ind),
      .cpu_wr_reg_rw_0     (cpu_wr_reg_rw_0),
      .cpu_wr_reg_rw_1     (cpu_wr_reg_rw_1),
      .cpu_wr_reg_rw_2     (cpu_wr_reg_rw_2),
      .cpu_wr_reg_rw_3     (cpu_wr_reg_rw_3),
      .cpu_wr_reg_ro_0     (cpu_wr_reg_ro_0),
      .cpu_wr_reg_ro_1     (cpu_wr_reg_ro_1),
      .cpu_wr_reg_wc_0     (cpu_wr_reg_wc_0),
      .cpu_wr_reg_wc_0_ind (cpu_wr_reg_wc_0_ind),
      .cpu_wr_reg_rc_0     (cpu_wr_reg_rc_0),
      .cpu_wr_reg_rc_0_ind (cpu_wr_reg_rc_0_ind),
      .cpu_wr_reg_rc_1     (cpu_wr_reg_rc_1),
      .cpu_wr_reg_rc_1_ind (cpu_wr_reg_rc_1_ind),

      .Led(Led_L),

      .clk    (clk_50Mhz),
      .rst_n  (reset_l),
      .req    (cpu_req),
      .rhwl   (cpu_rhwl),
      .wdata  (cpu_wdata),
      .address(cpu_address[15:0]),
      .rdata  (cpu_rdata),
      .ack    (cpu_ack)
  );

  // --- MDIO controller (from ip_common) ---
  lcpu_mdio u_lcpu_mdio_eth0 (
      .reset_l(reset_l),
      .clk    (clk_50Mhz),

      .op_req  (eth0_op_req),
      .wrl_rdh (eth0_wrl_rdh),
      .wrdata  (eth0_wrdata),
      .address (eth0_address),
      .op_ack  (eth0_op_ack),
      .rddata  (eth0_rddata),

      .mdc  (Eth0_MDC),
      .mdio (Eth0_MDIO)
  );

  // --- GMII to MAC packet interface (from ip_common) ---
  wire eth0_mac_rx_sop, eth0_mac_rx_en, eth0_mac_rx_eop, eth0_mac_rx_err;
  wire [7:0] eth0_mac_rx_data;
  wire eth0_mac_tx_sop, eth0_mac_tx_en, eth0_mac_tx_eop, eth0_mac_tx_err;
  wire [7:0] eth0_mac_tx_data;

  gmii2mac i_eth0 (
      .clk    (clk_125Mhz),
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

      .rx_afifo_full_cnt (eth0_rx_afifo_full_cnt),
      .rx_afifo_empty_cnt(eth0_rx_afifo_empty_cnt),
      .rx_data_err_line  (eth0_rx_data_err_line),
      .rx_correct_pkt_cnt(eth0_rx_correct_pkt_cnt),
      .rx_crc_err_pkt_cnt(eth0_rx_crc_err_pkt_cnt),
      .tx_correct_pkt_cnt(eth0_tx_correct_pkt_cnt),
      .tx_error_pkt_cnt  (eth0_tx_error_pkt_cnt)
  );

  // --- CPU-MAC data channel ---
  cpu_channel #(
      .cpu_buf_addr_width      (cpu_buf_addr_width),
      .cpu_buf_block_mode      (cpu_buf_block_mode),
      .cpu_buf_block_addr_width(cpu_buf_block_addr_width),
      .cpu_buf_data_width      (cpu_buf_data_width),
      .cpu_buf_para_width      (cpu_buf_para_width),
      .cpu_buf_data_ram_type   (cpu_buf_data_ram_type),
      .cpu_buf_para_ram_type   (cpu_buf_para_ram_type)
  ) u_cpu_channel (
      .clk    (clk_125Mhz),
      .cpu_clk(clk_50Mhz),
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

      .filter_data      (debug_RW_0[31:16]),
      .filter_offset    (debug_RW_0[15:0]),
      .recv_pkt_drop_cnt(debug_RO_0[7:0]),

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

  // --- CPU operation latency counter ---
  reg cpu_oping;
  reg [31:0] cpu_op_dly_cnt_s;
  reg [31:0] cpu_op_dly_cnt;
  assign debug_RO_1 = cpu_op_dly_cnt;

  always @(negedge reset_l or posedge clk_125Mhz)
    if (reset_l == 1'b0) begin
      cpu_oping <= 1'b0;
      cpu_op_dly_cnt_s <= 32'b0;
      cpu_op_dly_cnt <= 32'b0;
    end else begin
      if (eth0_mac_rx_sop == 1'b1) begin
        cpu_oping <= 1'b1;
      end
      if (cpu_oping == 1'b1) begin
        cpu_op_dly_cnt_s <= cpu_op_dly_cnt_s + 1;
      end else begin
        cpu_op_dly_cnt_s <= 32'b0;
      end
      if (eth0_mac_tx_sop == 1'b1) begin
        cpu_oping <= 1'b0;
        cpu_op_dly_cnt <= cpu_op_dly_cnt_s;
      end
    end

  // --- Debug RAM (simple_dual_port_ram — user will map to available IP) ---
  generate
    if (debug_en > 0) begin : dbg_ram_gen
      simple_dual_port_ram #(
          .addr_width(10),
          .data_width(32),
          .ram_type  ("M9K")
      ) u_dbg_ram (
          .aclk    (clk_50Mhz),
          .aclk_en (1'b1),
          .awr_en  (RAMIF_dbg_ram_0_Ram_RlWh),
          .awr_addr(RAMIF_dbg_ram_0_Ram_Addr[9:0]),
          .awr_data(RAMIF_dbg_ram_0_Ram_WrData),

          .bclk    (clk_50Mhz),
          .bclk_en (1'b1),
          .brd_addr(RAMIF_dbg_ram_0_Ram_Addr[9:0]),
          .brd_data(RAMIF_dbg_ram_0_Ram_RdData)
      );
    end
  endgenerate

endmodule
