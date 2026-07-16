// cpu_channel_tri — three-port L2 bridge data channel with MAC whitelist
//
// Architecture (simplified):
//   eth0 (Management):  RX → CPU (all packets, dedicated mgmt port)
//                        CPU → eth0 TX (management responses)
//   eth1 (LAN):         RX → whitelist(SrcMAC) → eth2 TX (bridge forward)
//                        Drop if whitelist blocks
//   eth2 (WAN):         RX → eth1 TX (unconditional bridge forward)
//
// eth1 and eth2 are pure L2 hardware bridge — no CPU involvement.
// Only eth0 connects to the CPU for WebServer management.

module cpu_channel_tri #(
    parameter int cpu_buf_addr_width       = 12,
    parameter     cpu_buf_block_mode       = "false",
    parameter int cpu_buf_block_addr_width = 2,
    parameter int cpu_buf_data_width       = 8,
    parameter int cpu_buf_para_width       = 1,
    parameter     cpu_buf_data_ram_type    = "block",
    parameter     cpu_buf_para_ram_type    = "distributed",
    parameter int stat_cnt_en              = 1
) (
    input clk,      // 125MHz MAC domain
    input cpu_clk,  // 50MHz CPU domain
    input reset_l,

    // === eth0 (Management) MAC interfaces ===
    input                           mac0_rx_sop,
    input                           mac0_rx_en,
    input  [cpu_buf_data_width-1:0] mac0_rx_data,
    input                           mac0_rx_eop,
    input                           mac0_rx_err,
    output                          mac0_tx_sop,
    output                          mac0_tx_en,
    output [cpu_buf_data_width-1:0] mac0_tx_data,
    output                          mac0_tx_eop,
    output                          mac0_tx_err,

    // === eth1 (LAN) MAC interfaces ===
    input                           mac1_rx_sop,
    input                           mac1_rx_en,
    input  [cpu_buf_data_width-1:0] mac1_rx_data,
    input                           mac1_rx_eop,
    input                           mac1_rx_err,
    output                          mac1_tx_sop,
    output                          mac1_tx_en,
    output [cpu_buf_data_width-1:0] mac1_tx_data,
    output                          mac1_tx_eop,
    output                          mac1_tx_err,

    // === eth2 (WAN) MAC interfaces ===
    input                           mac2_rx_sop,
    input                           mac2_rx_en,
    input  [cpu_buf_data_width-1:0] mac2_rx_data,
    input                           mac2_rx_eop,
    input                           mac2_rx_err,
    output                          mac2_tx_sop,
    output                          mac2_tx_en,
    output [cpu_buf_data_width-1:0] mac2_tx_data,
    output                          mac2_tx_eop,
    output                          mac2_tx_err,

    // === Whitelist lookup interface (125MHz) ===
    output reg        wl_lookup_req,
    output reg [47:0] wl_lookup_mac,
    input             wl_lookup_match,
    input             wl_lookup_done,
    input             wl_lookup_busy,

    // === CPU read port (50MHz cpu_clk, eth0 only) ===
    output                          cpu_rd_empty,
    input                           cpu_rd_rpkt_pop,
    output [  cpu_buf_addr_width:0] cpu_rd_rpkt_len,
    output [cpu_buf_para_width-1:0] cpu_rd_rpkt_para,
    input                           cpu_rd_ren,
    input  [cpu_buf_addr_width-1:0] cpu_rd_raddr,
    output [cpu_buf_data_width-1:0] cpu_rd_rdata,
    output                          cpu_rd_reop_pre,

    // === CPU write port (50MHz cpu_clk → eth0 TX) ===
    output                          cpu_wr_full,
    input                           cpu_wr_wen,
    input  [cpu_buf_addr_width-1:0] cpu_wr_waddr,
    input  [cpu_buf_data_width-1:0] cpu_wr_wdata,
    input                           cpu_wr_wpkt_push,
    input  [  cpu_buf_addr_width:0] cpu_wr_wpkt_len,
    input  [cpu_buf_para_width-1:0] cpu_wr_wpkt_para,

    // === Whitelist control (125MHz) ===
    input whitelist_en,
    input default_pass,

    // === Statistics (125MHz) ===
    output [31:0] eth1_rx_drop_cnt,
    output [ 7:0] recv_pkt_drop_cnt
);

  // ============================================================
  // eth0 RX → CPU path
  // ============================================================
  reg  [cpu_buf_addr_width-1:0] mac0_rx_addr;
  wire                          mac0_in_full;
  wire                          mac0_in_wen;
  wire [cpu_buf_addr_width-1:0] mac0_in_waddr;
  wire [cpu_buf_data_width-1:0] mac0_in_wdata;
  wire                          mac0_in_wpkt_push;
  wire [  cpu_buf_addr_width:0] mac0_in_wpkt_len;
  wire [cpu_buf_para_width-1:0] mac0_in_wpkt_para;

  // ============================================================
  // eth1 → eth2 bridge forwarding
  // ============================================================
  reg  [cpu_buf_addr_width-1:0] eth1_fwd_addr;
  wire                          eth1_fwd_full;
  wire                          eth1_fwd_wen;
  wire [cpu_buf_addr_width-1:0] eth1_fwd_waddr;
  wire [cpu_buf_data_width-1:0] eth1_fwd_wdata;
  wire                          eth1_fwd_wpkt_push_raw;
  wire                          eth1_fwd_wpkt_push;
  wire [  cpu_buf_addr_width:0] eth1_fwd_wpkt_len;
  wire [cpu_buf_para_width-1:0] eth1_fwd_wpkt_para;

  wire                          eth1_fwd_empty;
  wire [  cpu_buf_addr_width:0] eth1_fwd_rpkt_len;
  wire [cpu_buf_para_width-1:0] eth1_fwd_rpkt_para;
  wire                          eth1_fwd_ren;
  wire [cpu_buf_addr_width-1:0] eth1_fwd_raddr;
  wire [cpu_buf_data_width-1:0] eth1_fwd_rdata;
  wire                          eth1_fwd_rpkt_pop;  // from pktfifo2ram back to fifo

  wire                          eth2_tx_en_s;
  wire [cpu_buf_data_width-1:0] eth2_tx_data_s;

  // ============================================================
  // eth2 → eth1 bridge forwarding (unconditional)
  // ============================================================
  reg  [cpu_buf_addr_width-1:0] eth2_fwd_addr;
  wire                          eth2_fwd_full;
  wire                          eth2_fwd_wen;
  wire [cpu_buf_addr_width-1:0] eth2_fwd_waddr;
  wire [cpu_buf_data_width-1:0] eth2_fwd_wdata;
  wire                          eth2_fwd_wpkt_push;
  wire [  cpu_buf_addr_width:0] eth2_fwd_wpkt_len;
  wire [cpu_buf_para_width-1:0] eth2_fwd_wpkt_para;

  wire                          eth2_fwd_empty;
  wire [  cpu_buf_addr_width:0] eth2_fwd_rpkt_len;
  wire [cpu_buf_para_width-1:0] eth2_fwd_rpkt_para;
  wire                          eth2_fwd_ren;
  wire [cpu_buf_addr_width-1:0] eth2_fwd_raddr;
  wire [cpu_buf_data_width-1:0] eth2_fwd_rdata;
  wire                          eth2_fwd_rpkt_pop;  // from pktfifo2ram back to fifo

  wire                          eth1_tx_en_s;
  wire [cpu_buf_data_width-1:0] eth1_tx_data_s;

  // ============================================================
  // CPU TX → eth0 TX
  // ============================================================
  wire                          cpu_wr_empty;
  wire [  cpu_buf_addr_width:0] cpu_wr_rpkt_len;
  wire [cpu_buf_para_width-1:0] cpu_wr_rpkt_para;
  wire                          cpu_wr_ren;
  wire [cpu_buf_addr_width-1:0] cpu_wr_raddr;
  wire [cpu_buf_data_width-1:0] cpu_wr_rdata;
  wire                          cpu_tx_rpkt_pop;  // from pktfifo2ram back to fifo

  wire                          eth0_tx_en_s;
  wire [cpu_buf_data_width-1:0] eth0_tx_data_s;

  // ============================================================
  // Whitelist: SrcMAC extraction from eth1 header
  // ============================================================
  reg  [                  47:0] mac1_src_mac;
  reg  [                   3:0] mac1_byte_cnt;
  reg                           mac1_header_done;
  reg                           wl_lookup_pending;
  reg                           wl_result_valid;
  reg                           wl_result_match;

  // ============================================================
  // Drop counters
  // ============================================================
  reg  [                  31:0] eth1_rx_drop_cnt_reg;
  reg  [                   7:0] recv_pkt_drop_cnt_reg;
  assign eth1_rx_drop_cnt  = eth1_rx_drop_cnt_reg;
  assign recv_pkt_drop_cnt = recv_pkt_drop_cnt_reg;

  // ============================================================
  // RX byte counters
  // ============================================================
  always @(negedge reset_l or posedge clk) begin
    if (reset_l == 1'b0) begin
      mac0_rx_addr <= {cpu_buf_addr_width{1'b0}};
    end else begin
      mac0_rx_addr <= {cpu_buf_addr_width{1'b0}};
      if (mac0_rx_en) mac0_rx_addr <= mac0_rx_addr + 1;
    end
  end

  // ============================================================
  // eth1 MAC header extraction
  // ============================================================
  always @(negedge reset_l or posedge clk) begin
    if (reset_l == 1'b0) begin
      mac1_src_mac    <= 48'b0;
      mac1_byte_cnt   <= 4'b0;
      mac1_header_done <= 1'b0;
    end else begin
      if (mac1_rx_sop) begin
        mac1_byte_cnt <= 4'b0;
        mac1_header_done <= 1'b0;
      end
      if (mac1_rx_en && !mac1_header_done) begin
        mac1_byte_cnt <= mac1_byte_cnt + 1;
        if (mac1_byte_cnt >= 4'd6 && mac1_byte_cnt < 4'd12)
          mac1_src_mac <= {mac1_src_mac[39:0], mac1_rx_data};
        if (mac1_byte_cnt == 4'd13) mac1_header_done <= 1'b1;
      end
    end
  end

  // ============================================================
  // Whitelist lookup trigger
  // ============================================================
  always @(negedge reset_l or posedge clk) begin
    if (reset_l == 1'b0) begin
      wl_lookup_req    <= 1'b0;
      wl_lookup_mac    <= 48'b0;
      wl_lookup_pending <= 1'b0;
      wl_result_valid  <= 1'b0;
      wl_result_match  <= 1'b0;
    end else begin
      wl_lookup_req <= 1'b0;
      if (mac1_header_done && !wl_lookup_pending && !wl_lookup_busy) begin
        wl_lookup_req    <= 1'b1;
        wl_lookup_mac    <= mac1_src_mac;
        wl_lookup_pending <= 1'b1;
        wl_result_valid  <= 1'b0;
      end
      if (wl_lookup_done) begin
        wl_lookup_pending <= 1'b0;
        wl_result_valid   <= 1'b1;
        wl_result_match   <= wl_lookup_match;
      end
      if (mac1_rx_sop) wl_result_valid <= 1'b0;
    end
  end

  // ============================================================
  // eth0 RX → ram2pktfifo_int → CPU
  // ============================================================
  ram2pktfifo_int #(
      .addr_width(cpu_buf_addr_width),
      .data_width(cpu_buf_data_width),
      .para_width(cpu_buf_para_width)
  ) u_ram2pktfifo_eth0 (
      .reset_l       (reset_l),
      .clk           (clk),
      .clk_en        (1'b1),
      .ram_wen       (mac0_rx_en),
      .ram_wdata     (mac0_rx_data),
      .ram_waddr     (mac0_rx_addr),
      .ram_wpara     ({cpu_buf_para_width{1'b0}}),
      .ram_wen_permit(),
      .full          (mac0_in_full),
      .wen           (mac0_in_wen),
      .waddr         (mac0_in_waddr),
      .wdata         (mac0_in_wdata),
      .wpkt_push     (mac0_in_wpkt_push),
      .wpkt_len      (mac0_in_wpkt_len),
      .wpkt_para     (mac0_in_wpkt_para)
  );

  // ============================================================
  // eth1 RX → ram2pktfifo_int → eth2 TX bridge forward
  // ============================================================
  ram2pktfifo_int #(
      .addr_width(cpu_buf_addr_width),
      .data_width(cpu_buf_data_width),
      .para_width(cpu_buf_para_width)
  ) u_ram2pktfifo_eth1_fwd (
      .reset_l       (reset_l),
      .clk           (clk),
      .clk_en        (1'b1),
      .ram_wen       (mac1_rx_en),
      .ram_wdata     (mac1_rx_data),
      .ram_waddr     (mac1_rx_en ? eth1_fwd_addr : {cpu_buf_addr_width{1'b0}}),
      .ram_wpara     ({cpu_buf_para_width{1'b0}}),
      .ram_wen_permit(),
      .full          (eth1_fwd_full),
      .wen           (eth1_fwd_wen),
      .waddr         (eth1_fwd_waddr),
      .wdata         (eth1_fwd_wdata),
      .wpkt_push     (eth1_fwd_wpkt_push_raw),
      .wpkt_len      (eth1_fwd_wpkt_len),
      .wpkt_para     (eth1_fwd_wpkt_para)
  );

  always @(negedge reset_l or posedge clk) begin
    if (reset_l == 1'b0) eth1_fwd_addr <= {cpu_buf_addr_width{1'b0}};
    else if (mac1_rx_en) eth1_fwd_addr <= eth1_fwd_addr + 1;
    else eth1_fwd_addr <= {cpu_buf_addr_width{1'b0}};
  end

  assign eth1_fwd_wpkt_push = eth1_fwd_wpkt_push_raw &&
      (wl_result_match || (!whitelist_en && default_pass));

  package_fifo_v2 #(
      .dual_clock      (0),
      .addr_width      (cpu_buf_addr_width),
      .block_addr_width(cpu_buf_block_addr_width),
      .data_width      (cpu_buf_data_width),
      .para_width      (cpu_buf_para_width),
      .para_ram_type   (cpu_buf_para_ram_type),
      .data_ram_type   (cpu_buf_data_ram_type),
      .max_pkt_length  (1518),
      .block_mode      (cpu_buf_block_mode)
  ) u_pkg_fifo_eth1_fwd (
      .reset_l  (reset_l),
      .wclk     (clk),
      .wclk_en  (1'b1),
      .full     (eth1_fwd_full),
      .wen      (eth1_fwd_wen),
      .waddr    (eth1_fwd_waddr),
      .wdata    (eth1_fwd_wdata),
      .wpkt_push(eth1_fwd_wpkt_push),
      .wpkt_len (eth1_fwd_wpkt_len),
      .wpkt_para(eth1_fwd_wpkt_para),
      .rclk     (clk),
      .rclk_en  (1'b1),
      .empty    (eth1_fwd_empty),
      .rpkt_pop (eth1_fwd_rpkt_pop),
      .rpkt_len (eth1_fwd_rpkt_len),
      .rpkt_para(eth1_fwd_rpkt_para),
      .ren      (eth1_fwd_ren),
      .raddr    (eth1_fwd_raddr),
      .rdata    (eth1_fwd_rdata),
      .reop_pre ()
  );

  pktfifo2ram_int_v2 #(
      .addr_width(cpu_buf_addr_width),
      .data_width(cpu_buf_data_width),
      .para_width(cpu_buf_para_width),
      .ipg       (12),
      .block_mode(cpu_buf_block_mode)
  ) u_pktfifo2ram_eth1_fwd (
      .reset_l   (reset_l),
      .clk       (clk),
      .clk_en    (1'b1),
      .empty     (eth1_fwd_empty),
      .rpkt_pop  (eth1_fwd_rpkt_pop),
      .rpkt_len  (eth1_fwd_rpkt_len),
      .rpkt_para (eth1_fwd_rpkt_para),
      .ren       (eth1_fwd_ren),
      .raddr     (eth1_fwd_raddr),
      .rdata     (eth1_fwd_rdata),
      .reop_pre  (1'b0),
      .ipg_adjust(0),
      .ram_wen   (eth2_tx_en_s),
      .ram_wdata (eth2_tx_data_s),
      .ram_waddr (),
      .ram_wpara ()
  );

  sop_eop_gen #(
      .data_width(8)
  ) u_sop_eop_eth2 (
      .clk    (clk),
      .clk_en (1'b1),
      .reset_l(reset_l),
      .i_en   (eth2_tx_en_s),
      .i_err  (1'b0),
      .i_data (eth2_tx_data_s),
      .o_sop  (mac2_tx_sop),
      .o_en   (mac2_tx_en),
      .o_data (mac2_tx_data),
      .o_eop  (mac2_tx_eop),
      .o_err  (mac2_tx_err)
  );

  // ============================================================
  // eth2 RX → eth1 TX bridge forward (unconditional)
  // ============================================================
  ram2pktfifo_int #(
      .addr_width(cpu_buf_addr_width),
      .data_width(cpu_buf_data_width),
      .para_width(cpu_buf_para_width)
  ) u_ram2pktfifo_eth2_fwd (
      .reset_l       (reset_l),
      .clk           (clk),
      .clk_en        (1'b1),
      .ram_wen       (mac2_rx_en),
      .ram_wdata     (mac2_rx_data),
      .ram_waddr     (mac2_rx_en ? eth2_fwd_addr : {cpu_buf_addr_width{1'b0}}),
      .ram_wpara     ({cpu_buf_para_width{1'b0}}),
      .ram_wen_permit(),
      .full          (eth2_fwd_full),
      .wen           (eth2_fwd_wen),
      .waddr         (eth2_fwd_waddr),
      .wdata         (eth2_fwd_wdata),
      .wpkt_push     (eth2_fwd_wpkt_push),
      .wpkt_len      (eth2_fwd_wpkt_len),
      .wpkt_para     (eth2_fwd_wpkt_para)
  );

  always @(negedge reset_l or posedge clk) begin
    if (reset_l == 1'b0) eth2_fwd_addr <= {cpu_buf_addr_width{1'b0}};
    else if (mac2_rx_en) eth2_fwd_addr <= eth2_fwd_addr + 1;
    else eth2_fwd_addr <= {cpu_buf_addr_width{1'b0}};
  end

  package_fifo_v2 #(
      .dual_clock      (0),
      .addr_width      (cpu_buf_addr_width),
      .block_addr_width(cpu_buf_block_addr_width),
      .data_width      (cpu_buf_data_width),
      .para_width      (cpu_buf_para_width),
      .para_ram_type   (cpu_buf_para_ram_type),
      .data_ram_type   (cpu_buf_data_ram_type),
      .max_pkt_length  (1518),
      .block_mode      (cpu_buf_block_mode)
  ) u_pkg_fifo_eth2_fwd (
      .reset_l  (reset_l),
      .wclk     (clk),
      .wclk_en  (1'b1),
      .full     (eth2_fwd_full),
      .wen      (eth2_fwd_wen),
      .waddr    (eth2_fwd_waddr),
      .wdata    (eth2_fwd_wdata),
      .wpkt_push(eth2_fwd_wpkt_push),
      .wpkt_len (eth2_fwd_wpkt_len),
      .wpkt_para(eth2_fwd_wpkt_para),
      .rclk     (clk),
      .rclk_en  (1'b1),
      .empty    (eth2_fwd_empty),
      .rpkt_pop (eth2_fwd_rpkt_pop),
      .rpkt_len (eth2_fwd_rpkt_len),
      .rpkt_para(eth2_fwd_rpkt_para),
      .ren      (eth2_fwd_ren),
      .raddr    (eth2_fwd_raddr),
      .rdata    (eth2_fwd_rdata),
      .reop_pre ()
  );

  pktfifo2ram_int_v2 #(
      .addr_width(cpu_buf_addr_width),
      .data_width(cpu_buf_data_width),
      .para_width(cpu_buf_para_width),
      .ipg       (12),
      .block_mode(cpu_buf_block_mode)
  ) u_pktfifo2ram_eth2_fwd (
      .reset_l   (reset_l),
      .clk       (clk),
      .clk_en    (1'b1),
      .empty     (eth2_fwd_empty),
      .rpkt_pop  (eth2_fwd_rpkt_pop),
      .rpkt_len  (eth2_fwd_rpkt_len),
      .rpkt_para (eth2_fwd_rpkt_para),
      .ren       (eth2_fwd_ren),
      .raddr     (eth2_fwd_raddr),
      .rdata     (eth2_fwd_rdata),
      .reop_pre  (1'b0),
      .ipg_adjust(0),
      .ram_wen   (eth1_tx_en_s),
      .ram_wdata (eth1_tx_data_s),
      .ram_waddr (),
      .ram_wpara ()
  );

  sop_eop_gen #(
      .data_width(8)
  ) u_sop_eop_eth1 (
      .clk    (clk),
      .clk_en (1'b1),
      .reset_l(reset_l),
      .i_en   (eth1_tx_en_s),
      .i_err  (1'b0),
      .i_data (eth1_tx_data_s),
      .o_sop  (mac1_tx_sop),
      .o_en   (mac1_tx_en),
      .o_data (mac1_tx_data),
      .o_eop  (mac1_tx_eop),
      .o_err  (mac1_tx_err)
  );

  // ============================================================
  // eth0 → CPU packet FIFO (125MHz → 50MHz CDC)
  // ============================================================
  package_fifo_v2 #(
      .dual_clock      (1),
      .addr_width      (cpu_buf_addr_width),
      .block_addr_width(cpu_buf_block_addr_width),
      .data_width      (cpu_buf_data_width),
      .para_width      (cpu_buf_para_width),
      .para_ram_type   (cpu_buf_para_ram_type),
      .data_ram_type   (cpu_buf_data_ram_type),
      .max_pkt_length  (1518),
      .block_mode      (cpu_buf_block_mode)
  ) u_pkg_fifo_cpu_rx (
      .reset_l  (reset_l),
      .wclk     (clk),
      .wclk_en  (1'b1),
      .full     (mac0_in_full),
      .wen      (mac0_in_wen),
      .waddr    (mac0_in_waddr),
      .wdata    (mac0_in_wdata),
      .wpkt_push(mac0_in_wpkt_push),
      .wpkt_len (mac0_in_wpkt_len),
      .wpkt_para(mac0_in_wpkt_para),
      .rclk     (cpu_clk),
      .rclk_en  (1'b1),
      .empty    (cpu_rd_empty),
      .rpkt_pop (cpu_rd_rpkt_pop),
      .rpkt_len (cpu_rd_rpkt_len),
      .rpkt_para(cpu_rd_rpkt_para),
      .ren      (cpu_rd_ren),
      .raddr    (cpu_rd_raddr),
      .rdata    (cpu_rd_rdata),
      .reop_pre (cpu_rd_reop_pre)
  );

  // ============================================================
  // CPU TX → eth0 TX path (50MHz → 125MHz CDC)
  // ============================================================
  package_fifo_v2 #(
      .dual_clock      (1),
      .addr_width      (cpu_buf_addr_width),
      .block_addr_width(cpu_buf_block_addr_width),
      .data_width      (cpu_buf_data_width),
      .para_width      (cpu_buf_para_width),
      .para_ram_type   (cpu_buf_para_ram_type),
      .data_ram_type   (cpu_buf_data_ram_type),
      .max_pkt_length  (1518),
      .block_mode      (cpu_buf_block_mode)
  ) u_pkg_fifo_cpu_tx (
      .reset_l  (reset_l),
      .wclk     (cpu_clk),
      .wclk_en  (1'b1),
      .full     (cpu_wr_full),
      .wen      (cpu_wr_wen),
      .waddr    (cpu_wr_waddr),
      .wdata    (cpu_wr_wdata),
      .wpkt_push(cpu_wr_wpkt_push),
      .wpkt_len (cpu_wr_wpkt_len),
      .wpkt_para(cpu_wr_wpkt_para),
      .rclk     (clk),
      .rclk_en  (1'b1),
      .empty    (cpu_wr_empty),
      .rpkt_pop (cpu_tx_rpkt_pop),
      .rpkt_len (cpu_wr_rpkt_len),
      .rpkt_para(cpu_wr_rpkt_para),
      .ren      (cpu_wr_ren),
      .raddr    (cpu_wr_raddr),
      .rdata    (cpu_wr_rdata),
      .reop_pre ()
  );

  pktfifo2ram_int_v2 #(
      .addr_width(cpu_buf_addr_width),
      .data_width(cpu_buf_data_width),
      .para_width(cpu_buf_para_width),
      .ipg       (12),
      .block_mode(cpu_buf_block_mode)
  ) u_pktfifo2ram_cpu_tx (
      .reset_l   (reset_l),
      .clk       (clk),
      .clk_en    (1'b1),
      .empty     (cpu_wr_empty),
      .rpkt_pop  (cpu_tx_rpkt_pop),
      .rpkt_len  (cpu_wr_rpkt_len),
      .rpkt_para (cpu_wr_rpkt_para),
      .ren       (cpu_wr_ren),
      .raddr     (cpu_wr_raddr),
      .rdata     (cpu_wr_rdata),
      .reop_pre  (1'b0),
      .ipg_adjust(0),
      .ram_wen   (eth0_tx_en_s),
      .ram_wdata (eth0_tx_data_s),
      .ram_waddr (),
      .ram_wpara ()
  );

  sop_eop_gen #(
      .data_width(8)
  ) u_sop_eop_eth0 (
      .clk    (clk),
      .clk_en (1'b1),
      .reset_l(reset_l),
      .i_en   (eth0_tx_en_s),
      .i_err  (1'b0),
      .i_data (eth0_tx_data_s),
      .o_sop  (mac0_tx_sop),
      .o_en   (mac0_tx_en),
      .o_data (mac0_tx_data),
      .o_eop  (mac0_tx_eop),
      .o_err  (mac0_tx_err)
  );

  // ============================================================
  // Drop counters
  // ============================================================
  always @(negedge reset_l or posedge clk) begin
    if (reset_l == 1'b0) begin
      eth1_rx_drop_cnt_reg  <= 32'b0;
      recv_pkt_drop_cnt_reg <= 8'b0;
    end else begin
      if (eth1_fwd_wpkt_push_raw && !eth1_fwd_wpkt_push)
        eth1_rx_drop_cnt_reg <= eth1_rx_drop_cnt_reg + 1;
      if (mac0_in_wpkt_push && mac0_in_full) recv_pkt_drop_cnt_reg <= recv_pkt_drop_cnt_reg + 1;
    end
  end
endmodule
