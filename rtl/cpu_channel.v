// cpu_channel — cpu-mac data channel with packet fifos
// bridges the 125mhz ethernet mac domain to the 50mhz cpu domain.
// rx path: mac → ram2pktfifo_int → package_fifo (async) → cpu read port
// tx path: cpu write port → package_fifo (async) → pktfifo2ram_int → sop_eop_gen → mac

module cpu_channel #(
    parameter int cpu_buf_addr_width       = 11,
    parameter     cpu_buf_block_mode       = "false",
    parameter int cpu_buf_block_addr_width = 3,
    parameter int cpu_buf_data_width       = 8,
    parameter int cpu_buf_para_width       = 3,
    parameter     cpu_buf_data_ram_type    = "M9K",
    parameter     cpu_buf_para_ram_type    = "registers"
) (
    input clk,
    input reset_l,
    input cpu_clk,

    input                          mac_rx_sop,
    input                          mac_rx_en,
    input [cpu_buf_data_width-1:0] mac_rx_data,
    input                          mac_rx_eop,
    input                          mac_rx_err,

    output                          mac_tx_sop,
    output                          mac_tx_en,
    output [cpu_buf_data_width-1:0] mac_tx_data,
    output                          mac_tx_eop,
    output                          mac_tx_err,

    input      [15:0] filter_data,
    input      [15:0] filter_offset,
    output reg [ 7:0] recv_pkt_drop_cnt,

    // cpu read/get data port
    output   cpu_rd_empty,
    input    cpu_rd_rpkt_pop,
    output[cpu_buf_addr_width:0]cpu_rd_rpkt_len,
    output[cpu_buf_para_width-1:0]cpu_rd_rpkt_para,
    input    cpu_rd_ren,
    input [cpu_buf_addr_width-1:0]cpu_rd_raddr,
    output[cpu_buf_data_width-1:0]cpu_rd_rdata,
    output   cpu_rd_reop_pre,

    // cpu write/send data port
    output   cpu_wr_full,
    input    cpu_wr_wen,
    input [cpu_buf_addr_width-1:0]cpu_wr_waddr,
    input [cpu_buf_data_width-1:0]cpu_wr_wdata,
    input    cpu_wr_wpkt_push,
    input [cpu_buf_addr_width:0]cpu_wr_wpkt_len,
    input [cpu_buf_para_width-1:0]cpu_wr_wpkt_para
);

  reg  [cpu_buf_addr_width-1:0] mac_rx_addr;
  wire                          mac_in_full;
  wire                          mac_in_wen;
  wire [cpu_buf_addr_width-1:0] mac_in_waddr;
  wire [cpu_buf_data_width-1:0] mac_in_wdata;
  wire                          mac_in_wpkt_push;
  wire [  cpu_buf_addr_width:0] mac_in_wpkt_len;
  wire [cpu_buf_para_width-1:0] mac_in_wpkt_para;

  wire                          mac_in_empty;
  wire                          mac_in_rpkt_pop;
  wire [  cpu_buf_addr_width:0] mac_in_rpkt_len;
  wire [cpu_buf_para_width-1:0] mac_in_rpkt_para;
  wire                          mac_in_ren;
  wire [cpu_buf_addr_width-1:0] mac_in_raddr;
  wire [cpu_buf_data_width-1:0] mac_in_rdata;
  wire                          mac_in_reop_pre;

  wire                          mac_tx_en_s;
  wire [cpu_buf_data_width-1:0] mac_tx_data_s;

  reg                           pass_enable;

  // rx byte counter (resets on sop, increments on data enable)
  always @(negedge reset_l or posedge clk)
    if (reset_l == 1'b0) begin
      mac_rx_addr <= {cpu_buf_addr_width{1'b0}};
    end else begin
      mac_rx_addr <= {cpu_buf_addr_width{1'b0}};
      if (mac_rx_en == 1'b1) begin
        mac_rx_addr <= mac_rx_addr + 1;
      end
    end

  // convert continuous rx byte stream into ram2pktfifo_int interface
  ram2pktfifo_int #(
      .addr_width(cpu_buf_addr_width),
      .data_width(cpu_buf_data_width),
      .para_width(cpu_buf_para_width)
  ) u_ram2pktfifo_int (
      .reset_l(reset_l),
      .clk    (clk),
      .clk_en (1'b1),

      .ram_wen       (mac_rx_en),
      .ram_wdata     (mac_rx_data),
      .ram_waddr     (mac_rx_addr),
      .ram_wpara     ({cpu_buf_para_width{1'b0}}),
      .ram_wen_permit(),

      .full     (mac_in_full),
      .wen      (mac_in_wen),
      .waddr    (mac_in_waddr),
      .wdata    (mac_in_wdata),
      .wpkt_push(mac_in_wpkt_push),
      .wpkt_len (mac_in_wpkt_len),
      .wpkt_para(mac_in_wpkt_para)
  );

  // packet filter: enable/disable forwarding based on data match at offset
  always @(negedge reset_l or posedge clk)
    if (reset_l == 1'b0) begin
      pass_enable <= 1'b0;
      recv_pkt_drop_cnt <= 8'b0;
    end else begin
      if (mac_in_waddr == filter_offset) begin
        if (filter_data[15] == 1'b1) begin
          if (mac_in_wdata == filter_data[7:0]) begin
            pass_enable <= 1'b1;
          end else begin
            pass_enable <= 1'b0;
          end
        end else begin
          pass_enable <= 1'b1;
        end
      end

      if (mac_in_wpkt_push & pass_enable & mac_in_full) begin
        recv_pkt_drop_cnt <= recv_pkt_drop_cnt + 1;
      end
    end

  // rx async fifo: 125mhz (mac) → 50mhz (cpu read port)
  package_fifo_v2 #(
      .dual_clock(1),
      .addr_width(cpu_buf_addr_width),
      .block_addr_width(cpu_buf_block_addr_width),
      .data_width(cpu_buf_data_width),
      .para_width(cpu_buf_para_width),
      .para_ram_type(cpu_buf_para_ram_type),
      .data_ram_type(cpu_buf_data_ram_type),
      .max_pkt_length(1518),
      .block_mode(cpu_buf_block_mode)
  ) u_package_fifo_cpu_rd (
      .reset_l(reset_l),

      .wclk   (clk),
      .wclk_en (1'b1),
      .full   (mac_in_full),
      .wen   (mac_in_wen),
      .waddr  (mac_in_waddr),
      .wdata  (mac_in_wdata),
      .wpkt_push(mac_in_wpkt_push & pass_enable),
      .wpkt_len (mac_in_wpkt_len),
      .wpkt_para(mac_in_wpkt_para),

      .rclk   (cpu_clk),
      .rclk_en (1'b1),
      .empty  (cpu_rd_empty),
      .rpkt_pop (cpu_rd_rpkt_pop),
      .rpkt_len (cpu_rd_rpkt_len),
      .rpkt_para(cpu_rd_rpkt_para),
      .ren   (cpu_rd_ren),
      .raddr  (cpu_rd_raddr),
      .rdata  (cpu_rd_rdata),
      .reop_pre (cpu_rd_reop_pre)
  );

  // tx async fifo: 50mhz (cpu write port) → 125mhz (mac)
  package_fifo_v2 #(
      .dual_clock(1),
      .addr_width(cpu_buf_addr_width),
      .block_addr_width(cpu_buf_block_addr_width),
      .data_width(cpu_buf_data_width),
      .para_width(cpu_buf_para_width),
      .para_ram_type(cpu_buf_para_ram_type),
      .data_ram_type(cpu_buf_data_ram_type),
      .max_pkt_length(1518),
      .block_mode(cpu_buf_block_mode)
  ) u_package_fifo_cpu_wr (
      .reset_l(reset_l),

      .wclk   (cpu_clk),
      .wclk_en (1'b1),
      .full   (cpu_wr_full),
      .wen   (cpu_wr_wen),
      .waddr  (cpu_wr_waddr),
      .wdata  (cpu_wr_wdata),
      .wpkt_push(cpu_wr_wpkt_push),
      .wpkt_len (cpu_wr_wpkt_len),
      .wpkt_para(cpu_wr_wpkt_para),

      .rclk   (clk),
      .rclk_en (1'b1),
      .empty  (mac_in_empty),
      .rpkt_pop (mac_in_rpkt_pop),
      .rpkt_len (mac_in_rpkt_len),
      .rpkt_para(mac_in_rpkt_para),
      .ren   (mac_in_ren),
      .raddr  (mac_in_raddr),
      .rdata  (mac_in_rdata),
      .reop_pre (mac_in_reop_pre)
  );

  // tx packet fifo → continuous byte stream (with ipg insertion)
  pktfifo2ram_int_v2 #(
      .addr_width(cpu_buf_addr_width),
      .data_width(cpu_buf_data_width),
      .para_width(cpu_buf_para_width),
      .ipg       (8),
      .block_mode(cpu_buf_block_mode)
  ) u_pktfifo2ram_int (
      .reset_l(reset_l),
      .clk    (clk),
      .clk_en (1'b1),

      .empty    (mac_in_empty),
      .rpkt_pop (mac_in_rpkt_pop),
      .rpkt_len (mac_in_rpkt_len),
      .rpkt_para(mac_in_rpkt_para),
      .ren      (mac_in_ren),
      .raddr    (mac_in_raddr),
      .rdata    (mac_in_rdata),
      .reop_pre (mac_in_reop_pre),

      .ipg_adjust(0),

      .ram_wen  (mac_tx_en_s),
      .ram_wdata(mac_tx_data_s),
      .ram_waddr(),
      .ram_wpara()
  );

  // generate sop/eop sideband signals from continuous byte stream
  sop_eop_gen #(
      .data_width(8)
  ) u_sop_eop_gen (
      .clk   (clk),
      .clk_en (1'b1),
      .reset_l (reset_l),

      .i_en  (mac_tx_en_s),
      .i_err (1'b0),
      .i_data(mac_tx_data_s),

      .o_sop (mac_tx_sop),
      .o_en  (mac_tx_en),
      .o_data(mac_tx_data),
      .o_eop (mac_tx_eop),
      .o_err (mac_tx_err)
  );
endmodule
