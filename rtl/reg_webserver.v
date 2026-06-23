// reg_webserver — Register file and address decoder for FPGA WebServer
//
// Memory map:
//   0x0000      : Version Time (RO)
//   0x0001      : Ethernet Reset (RW, [3:0])
//   0x0002      : Second Event (RO)
//   0x0003      : Get Local Time (RW)
//   0x0004      : Local Time Low (RO)
//   0x0005      : Local Time High (RO)
//   0x0010      : Debug RW 0 (RW)
//   0x0011      : Debug RW 1 (RW)
//   0x0020      : Debug RO 0 (RO)
//   0x0021      : Debug RO 1 (RO)
//   0x0030      : LED (RW, [3:0])
//   0x0100-0x0106 : Eth0 statistics (RO)
//   0x0200-0x0206 : Eth1 statistics (RO)
//   0x1000-0x1FFF : Eth0 MDIO sub-bus
//   0x2000-0x2FFF : Eth1 MDIO sub-bus
//   0x6000-0x600F : CPU read packet FIFO control/status
//   0x6100-0x610F : CPU write packet FIFO control/status
//   0x7000-0x7FFF : Debug RAM

module reg_webserver (
    input      [31:0] version_time,
    output reg [ 3:0] Eth_GRESET,
    input      [ 0:0] second_event,
    output reg [ 0:0] get_local_time,
    output reg        get_local_time_ind,
    input      [31:0] local_time_l,
    input      [31:0] local_time_h,
    output reg [31:0] debug_RW_0,
    output reg [31:0] debug_RW_1,
    input      [31:0] debug_RO_0,
    input      [31:0] debug_RO_1,
    // Eth0 statistics
    input      [31:0] eth0_rx_correct_pkt_cnt,
    input      [31:0] eth0_rx_crc_err_pkt_cnt,
    input      [31:0] eth0_tx_correct_pkt_cnt,
    input      [31:0] eth0_tx_error_pkt_cnt,
    input      [31:0] eth0_rx_afifo_full_cnt,
    input      [31:0] eth0_rx_afifo_empty_cnt,
    input      [31:0] eth0_rx_data_err_line,
    // Eth1 statistics
    input      [31:0] eth1_rx_correct_pkt_cnt,
    input      [31:0] eth1_rx_crc_err_pkt_cnt,
    input      [31:0] eth1_tx_correct_pkt_cnt,
    input      [31:0] eth1_tx_error_pkt_cnt,
    input      [31:0] eth1_rx_afifo_full_cnt,
    input      [31:0] eth1_rx_afifo_empty_cnt,
    input      [31:0] eth1_rx_data_err_line,

    // Sub-bus: Eth0 MDIO
    output reg        SUBBUS_Eth0_Req,
    output reg        SUBBUS_Eth0_RhWl,
    output reg [11:0] SUBBUS_Eth0_ReqAddr,
    output reg [31:0] SUBBUS_Eth0_DataWr,
    input      [31:0] SUBBUS_Eth0_DataRd,
    input             SUBBUS_Eth0_Ack,
    // Sub-bus: Eth1 MDIO
    output reg        SUBBUS_Eth1_Req,
    output reg        SUBBUS_Eth1_RhWl,
    output reg [11:0] SUBBUS_Eth1_ReqAddr,
    output reg [31:0] SUBBUS_Eth1_DataWr,
    input      [31:0] SUBBUS_Eth1_DataRd,
    input             SUBBUS_Eth1_Ack,

    output reg [ 3:0] Led,

    // CPU read packet FIFO interface
    input      [ 0:0] cpu_rd_empty,
    output reg [ 0:0] cpu_rd_rpkt_pop,
    output reg        cpu_rd_rpkt_pop_ind,
    input      [31:0] cpu_rd_rpkt_len,
    input      [31:0] cpu_rd_rpkt_para,
    output reg [ 0:0] cpu_rd_ren,
    output reg [31:0] cpu_rd_raddr,
    input      [31:0] cpu_rd_rdata,
    input      [ 0:0] cpu_rd_reop_pre,
    output reg [31:0] cpu_rd_reg_rw_0,
    output reg [31:0] cpu_rd_reg_rw_1,
    output reg [31:0] cpu_rd_reg_rw_2,
    output reg [31:0] cpu_rd_reg_rw_3,
    input      [31:0] cpu_rd_reg_ro_0,
    input      [31:0] cpu_rd_reg_ro_1,
    output reg [31:0] cpu_rd_reg_wc_0,
    output reg        cpu_rd_reg_wc_0_ind,
    input      [31:0] cpu_rd_reg_rc_0,
    output reg        cpu_rd_reg_rc_0_ind,

    // CPU write packet FIFO interface
    input      [ 0:0] cpu_wr_full,
    output reg [ 0:0] cpu_wr_wen,
    output reg        cpu_wr_wen_ind,
    output reg [31:0] cpu_wr_waddr,
    output reg [31:0] cpu_wr_wdata,
    output reg [31:0] cpu_wr_wpkt_len,
    output reg [31:0] cpu_wr_wpkt_para,
    output reg [ 0:0] cpu_wr_wpkt_push,
    output reg        cpu_wr_wpkt_push_ind,
    output reg [ 0:0] cpu_wr_reg_rw_0,
    output reg [31:0] cpu_wr_reg_rw_1,
    output reg [31:0] cpu_wr_reg_rw_2,
    output reg [31:0] cpu_wr_reg_rw_3,
    input      [31:0] cpu_wr_reg_ro_0,
    input      [31:0] cpu_wr_reg_ro_1,
    output reg [31:0] cpu_wr_reg_wc_0,
    output reg        cpu_wr_reg_wc_0_ind,
    input      [31:0] cpu_wr_reg_rc_0,
    output reg        cpu_wr_reg_rc_0_ind,
    input      [31:0] cpu_wr_reg_rc_1,
    output reg        cpu_wr_reg_rc_1_ind,

    // Debug RAM interface
    output            RAMIF_dbg_ram_0_Ram_RlWh,
    output     [11:0] RAMIF_dbg_ram_0_Ram_Addr,
    output     [31:0] RAMIF_dbg_ram_0_Ram_WrData,
    input      [31:0] RAMIF_dbg_ram_0_Ram_RdData,

    // LCPU bus interface
    input clk,
    input rst_n,
    input req,
    input rhwl,
    input [31:0] wdata,
    input [15:0] address,
    output reg [31:0] rdata,
    output reg ack
);

  reg timeout_ack;
  reg is_req;
  reg [15:0] is_req_cnt;
  reg [31:0] reg_rdata;
  reg reg_ack;
  reg [31:0] Eth0_sb_rdata;
  reg Eth0_sb_ack;
  reg [31:0] Eth1_sb_rdata;
  reg Eth1_sb_ack;

  reg SUBBUS_dbg_ram_0_Req;
  reg SUBBUS_dbg_ram_0_RhWl;
  reg [11:0] SUBBUS_dbg_ram_0_ReqAddr;
  reg [31:0] SUBBUS_dbg_ram_0_DataWr;
  wire [31:0] dbg_ram_0_sb_rdata;
  wire dbg_ram_0_sb_ack;

  // --- Timeout watchdog: auto-ACK after ~60k cycles if no response ---
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      is_req <= 1'b0;
      is_req_cnt <= 16'b0;
      timeout_ack <= 1'b0;
    end else begin
      timeout_ack <= 1'b0;
      if (req == 1'b1) begin
        is_req <= req;
      end
      if (is_req == 1'b1) begin
        is_req_cnt <= is_req_cnt + 1;
      end else begin
        is_req_cnt <= 16'b0;
      end
      if (is_req_cnt >= 16'hf000 || ack == 1'b1) begin
        is_req <= 1'b0;
      end
      if (is_req_cnt == 16'hf000) begin
        timeout_ack <= 1'b1;
      end
    end
  end

  // --- Write registers ---

  // Eth_GRESET (0x01)
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      Eth_GRESET <= 4'hF;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h1) begin
        Eth_GRESET <= wdata[3:0];
      end
    end
  end

  // get_local_time (0x03)
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      get_local_time <= 1'h0;
      get_local_time_ind <= 1'b0;
    end else begin
      get_local_time_ind <= 1'b0;
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h3) begin
        get_local_time_ind <= 1'b1;
        get_local_time <= wdata[0:0];
      end
    end
  end

  // debug_RW_0 (0x10)
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      debug_RW_0 <= 32'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h10) begin
        debug_RW_0 <= wdata[31:0];
      end
    end
  end

  // debug_RW_1 (0x11)
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      debug_RW_1 <= 32'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h11) begin
        debug_RW_1 <= wdata[31:0];
      end
    end
  end

  // LED (0x30)
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      Led <= 4'hF;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h30) begin
        Led <= wdata[3:0];
      end
    end
  end

  // --- CPU read packet FIFO control registers (0x6000-0x600F) ---

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_rd_rpkt_pop <= 1'h0;
      cpu_rd_rpkt_pop_ind <= 1'b0;
    end else begin
      cpu_rd_rpkt_pop_ind <= 1'b0;
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h6001) begin
        cpu_rd_rpkt_pop_ind <= 1'b1;
        cpu_rd_rpkt_pop <= wdata[0:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_rd_ren <= 1'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h6004) begin
        cpu_rd_ren <= wdata[0:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_rd_raddr <= 32'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h6005) begin
        cpu_rd_raddr <= wdata[31:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_rd_reg_rw_0 <= 32'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h6008) begin
        cpu_rd_reg_rw_0 <= wdata[31:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_rd_reg_rw_1 <= 32'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h6009) begin
        cpu_rd_reg_rw_1 <= wdata[31:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_rd_reg_rw_2 <= 32'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h600A) begin
        cpu_rd_reg_rw_2 <= wdata[31:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_rd_reg_rw_3 <= 32'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h600B) begin
        cpu_rd_reg_rw_3 <= wdata[31:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_rd_reg_wc_0 <= 32'h0;
      cpu_rd_reg_wc_0_ind <= 1'b0;
    end else begin
      cpu_rd_reg_wc_0_ind <= 1'b0;
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h600E) begin
        cpu_rd_reg_wc_0_ind <= 1'b1;
        cpu_rd_reg_wc_0 <= wdata[31:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_rd_reg_rc_0_ind <= 1'b0;
    end else begin
      cpu_rd_reg_rc_0_ind <= 1'b0;
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h600F) cpu_rd_reg_rc_0_ind <= 1'b1;
    end
  end

  // --- CPU write packet FIFO control registers (0x6100-0x610F) ---

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_wr_wen <= 1'h0;
      cpu_wr_wen_ind <= 1'b0;
    end else begin
      cpu_wr_wen_ind <= 1'b0;
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h6101) begin
        cpu_wr_wen_ind <= 1'b1;
        cpu_wr_wen <= wdata[0:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_wr_waddr <= 32'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h6102) begin
        cpu_wr_waddr <= wdata[31:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_wr_wdata <= 32'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h6103) begin
        cpu_wr_wdata <= wdata[31:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_wr_wpkt_len <= 32'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h6104) begin
        cpu_wr_wpkt_len <= wdata[31:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_wr_wpkt_para <= 32'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h6105) begin
        cpu_wr_wpkt_para <= wdata[31:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_wr_wpkt_push <= 1'h0;
      cpu_wr_wpkt_push_ind <= 1'b0;
    end else begin
      cpu_wr_wpkt_push_ind <= 1'b0;
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h6106) begin
        cpu_wr_wpkt_push_ind <= 1'b1;
        cpu_wr_wpkt_push <= wdata[0:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_wr_reg_rw_0 <= 1'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h6107) begin
        cpu_wr_reg_rw_0 <= wdata[0:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_wr_reg_rw_1 <= 32'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h6108) begin
        cpu_wr_reg_rw_1 <= wdata[31:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_wr_reg_rw_2 <= 32'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h6109) begin
        cpu_wr_reg_rw_2 <= wdata[31:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_wr_reg_rw_3 <= 32'h0;
    end else begin
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h610A) begin
        cpu_wr_reg_rw_3 <= wdata[31:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_wr_reg_wc_0 <= 32'h0;
      cpu_wr_reg_wc_0_ind <= 1'b0;
    end else begin
      cpu_wr_reg_wc_0_ind <= 1'b0;
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h610D) begin
        cpu_wr_reg_wc_0_ind <= 1'b1;
        cpu_wr_reg_wc_0 <= wdata[31:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_wr_reg_rc_0_ind <= 1'b0;
    end else begin
      cpu_wr_reg_rc_0_ind <= 1'b0;
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h610E) cpu_wr_reg_rc_0_ind <= 1'b1;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cpu_wr_reg_rc_1_ind <= 1'b0;
    end else begin
      cpu_wr_reg_rc_1_ind <= 1'b0;
      if (req == 1'b1 && rhwl == 1'b0 && address == 16'h610F) cpu_wr_reg_rc_1_ind <= 1'b1;
    end
  end

  // --- Read registers (with full bit-width writes to prevent stale data) ---

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reg_rdata <= 32'b0;
      reg_ack   <= 1'b0;
    end else begin
      reg_ack <= 1'b0;
      if (req == 1'b1 && rhwl == 1'b1) reg_rdata <= 32'b0;

      // 0x00 : Version Time
      if (req == 1'b1 && address == 16'h0) begin
        reg_rdata <= version_time;
        reg_ack <= 1'b1;
      end
      // 0x01 : Eth_GRESET (4-bit, pad upper bits)
      if (req == 1'b1 && address == 16'h1) begin
        reg_rdata <= {28'b0, Eth_GRESET};
        reg_ack <= 1'b1;
      end
      // 0x02 : Second Event
      if (req == 1'b1 && address == 16'h2) begin
        reg_rdata <= {31'b0, second_event};
        reg_ack <= 1'b1;
      end
      // 0x03 : Get Local Time
      if (req == 1'b1 && address == 16'h3) begin
        reg_rdata <= {31'b0, get_local_time};
        reg_ack <= 1'b1;
      end
      // 0x04 : Local Time Low
      if (req == 1'b1 && address == 16'h4) begin
        reg_rdata <= local_time_l;
        reg_ack <= 1'b1;
      end
      // 0x05 : Local Time High
      if (req == 1'b1 && address == 16'h5) begin
        reg_rdata <= local_time_h;
        reg_ack <= 1'b1;
      end
      // 0x10 : Debug RW 0
      if (req == 1'b1 && address == 16'h10) begin
        reg_rdata <= debug_RW_0;
        reg_ack <= 1'b1;
      end
      // 0x11 : Debug RW 1
      if (req == 1'b1 && address == 16'h11) begin
        reg_rdata <= debug_RW_1;
        reg_ack <= 1'b1;
      end
      // 0x20 : Debug RO 0
      if (req == 1'b1 && address == 16'h20) begin
        reg_rdata <= debug_RO_0;
        reg_ack <= 1'b1;
      end
      // 0x21 : Debug RO 1
      if (req == 1'b1 && address == 16'h21) begin
        reg_rdata <= debug_RO_1;
        reg_ack <= 1'b1;
      end
      // 0x0100-0x0106 : Eth0 statistics
      if (req == 1'b1 && address == 16'h100) begin
        reg_rdata <= eth0_rx_correct_pkt_cnt; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h101) begin
        reg_rdata <= eth0_rx_crc_err_pkt_cnt; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h102) begin
        reg_rdata <= eth0_tx_correct_pkt_cnt; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h103) begin
        reg_rdata <= eth0_tx_error_pkt_cnt; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h104) begin
        reg_rdata <= eth0_rx_afifo_full_cnt; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h105) begin
        reg_rdata <= eth0_rx_afifo_empty_cnt; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h106) begin
        reg_rdata <= eth0_rx_data_err_line; reg_ack <= 1'b1;
      end
      // 0x0200-0x0206 : Eth1 statistics
      if (req == 1'b1 && address == 16'h200) begin
        reg_rdata <= eth1_rx_correct_pkt_cnt; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h201) begin
        reg_rdata <= eth1_rx_crc_err_pkt_cnt; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h202) begin
        reg_rdata <= eth1_tx_correct_pkt_cnt; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h203) begin
        reg_rdata <= eth1_tx_error_pkt_cnt; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h204) begin
        reg_rdata <= eth1_rx_afifo_full_cnt; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h205) begin
        reg_rdata <= eth1_rx_afifo_empty_cnt; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h206) begin
        reg_rdata <= eth1_rx_data_err_line; reg_ack <= 1'b1;
      end
      // 0x30 : LED (4-bit, pad upper bits)
      if (req == 1'b1 && address == 16'h30) begin
        reg_rdata <= {28'b0, Led};
        reg_ack <= 1'b1;
      end
      // 0x6000-0x600F : CPU read packet FIFO
      if (req == 1'b1 && address == 16'h6000) begin
        reg_rdata <= {31'b0, cpu_rd_empty}; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6001) begin
        reg_rdata <= {31'b0, cpu_rd_rpkt_pop}; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6002) begin
        reg_rdata <= cpu_rd_rpkt_len; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6003) begin
        reg_rdata <= cpu_rd_rpkt_para; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6004) begin
        reg_rdata <= {31'b0, cpu_rd_ren}; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6005) begin
        reg_rdata <= cpu_rd_raddr; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6006) begin
        reg_rdata <= cpu_rd_rdata; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6007) begin
        reg_rdata <= {31'b0, cpu_rd_reop_pre}; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6008) begin
        reg_rdata <= cpu_rd_reg_rw_0; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6009) begin
        reg_rdata <= cpu_rd_reg_rw_1; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h600A) begin
        reg_rdata <= cpu_rd_reg_rw_2; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h600B) begin
        reg_rdata <= cpu_rd_reg_rw_3; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h600C) begin
        reg_rdata <= cpu_rd_reg_ro_0; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h600D) begin
        reg_rdata <= cpu_rd_reg_ro_1; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h600E) begin
        reg_rdata <= cpu_rd_reg_wc_0; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h600F) begin
        reg_rdata <= cpu_rd_reg_rc_0; reg_ack <= 1'b1;
      end
      // 0x6100-0x610F : CPU write packet FIFO
      if (req == 1'b1 && address == 16'h6100) begin
        reg_rdata <= {31'b0, cpu_wr_full}; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6101) begin
        reg_rdata <= {31'b0, cpu_wr_wen}; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6102) begin
        reg_rdata <= cpu_wr_waddr; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6103) begin
        reg_rdata <= cpu_wr_wdata; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6104) begin
        reg_rdata <= cpu_wr_wpkt_len; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6105) begin
        reg_rdata <= cpu_wr_wpkt_para; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6106) begin
        reg_rdata <= {31'b0, cpu_wr_wpkt_push}; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6107) begin
        reg_rdata <= {31'b0, cpu_wr_reg_rw_0}; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6108) begin
        reg_rdata <= cpu_wr_reg_rw_1; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h6109) begin
        reg_rdata <= cpu_wr_reg_rw_2; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h610A) begin
        reg_rdata <= cpu_wr_reg_rw_3; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h610B) begin
        reg_rdata <= cpu_wr_reg_ro_0; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h610C) begin
        reg_rdata <= cpu_wr_reg_ro_1; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h610D) begin
        reg_rdata <= cpu_wr_reg_wc_0; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h610E) begin
        reg_rdata <= cpu_wr_reg_rc_0; reg_ack <= 1'b1;
      end
      if (req == 1'b1 && address == 16'h610F) begin
        reg_rdata <= cpu_wr_reg_rc_1; reg_ack <= 1'b1;
      end
    end
  end

  // --- Sub-bus: Eth0 MDIO (address range 0x1000-0x1FFF) ---
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      SUBBUS_Eth0_Req <= 1'b0;
      SUBBUS_Eth0_RhWl <= 1'b1;
      SUBBUS_Eth0_ReqAddr <= 12'b0;
      SUBBUS_Eth0_DataWr <= 32'b0;
    end else begin
      if (address >= 16'h1000 && address <= 16'h1fff) begin
        SUBBUS_Eth0_Req <= req;
      end
      SUBBUS_Eth0_RhWl <= rhwl;
      SUBBUS_Eth0_ReqAddr <= address[11:0];
      SUBBUS_Eth0_DataWr <= wdata;
    end
  end

  // --- Sub-bus: Eth1 MDIO (address range 0x2000-0x2FFF) ---
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      SUBBUS_Eth1_Req <= 1'b0;
      SUBBUS_Eth1_RhWl <= 1'b1;
      SUBBUS_Eth1_ReqAddr <= 12'b0;
      SUBBUS_Eth1_DataWr <= 32'b0;
    end else begin
      if (address >= 16'h2000 && address <= 16'h2fff) begin
        SUBBUS_Eth1_Req <= req;
      end
      SUBBUS_Eth1_RhWl <= rhwl;
      SUBBUS_Eth1_ReqAddr <= address[11:0];
      SUBBUS_Eth1_DataWr <= wdata;
    end
  end

  // --- Sub-bus: Debug RAM (address range 0x7000-0x7FFF) ---
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      SUBBUS_dbg_ram_0_Req <= 1'b0;
      SUBBUS_dbg_ram_0_RhWl <= 1'b1;
      SUBBUS_dbg_ram_0_ReqAddr <= 12'b0;
      SUBBUS_dbg_ram_0_DataWr <= 32'b0;
    end else begin
      if (address >= 16'h7000 && address <= 16'h7fff) begin
        SUBBUS_dbg_ram_0_Req <= req;
      end
      SUBBUS_dbg_ram_0_RhWl <= rhwl;
      SUBBUS_dbg_ram_0_ReqAddr <= address[11:0];
      SUBBUS_dbg_ram_0_DataWr <= wdata;
    end
  end

  // --- Sync sub-bus responses ---
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      Eth0_sb_ack   <= 1'b0;
      Eth0_sb_rdata <= 32'b0;
    end else begin
      Eth0_sb_ack   <= SUBBUS_Eth0_Ack;
      Eth0_sb_rdata <= SUBBUS_Eth0_DataRd;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      Eth1_sb_ack   <= 1'b0;
      Eth1_sb_rdata <= 32'b0;
    end else begin
      Eth1_sb_ack   <= SUBBUS_Eth1_Ack;
      Eth1_sb_rdata <= SUBBUS_Eth1_DataRd;
    end
  end

  // --- Final ACK / rdata mux ---
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ack   <= 1'b0;
      rdata <= 32'b0;
    end else begin
      if (Eth0_sb_ack) rdata <= Eth0_sb_rdata;
      if (Eth1_sb_ack) rdata <= Eth1_sb_rdata;
      if (dbg_ram_0_sb_ack) rdata <= dbg_ram_0_sb_rdata;
      ack <= timeout_ack | reg_ack | Eth0_sb_ack | Eth1_sb_ack | dbg_ram_0_sb_ack;
      if (timeout_ack) rdata <= 32'hdeaddead;
      if (reg_ack) rdata <= reg_rdata;
    end
  end

  // Debug RAM interface (RamIntf — from linkreal_common/ip, user will rename)
  RamIntf #(
      .DataBits(32),
      .AddrBits(12)
  ) RAMIF_dbg_ram_0 (
      .Ram_RdData(RAMIF_dbg_ram_0_Ram_RdData),
      .Ram_RlWh(RAMIF_dbg_ram_0_Ram_RlWh),
      .Ram_ByteEn(),
      .Ram_Addr(RAMIF_dbg_ram_0_Ram_Addr),
      .Ram_WrData(RAMIF_dbg_ram_0_Ram_WrData),
      .clk(clk),
      .rst_n(rst_n),
      .req(SUBBUS_dbg_ram_0_Req),
      .rhwl(SUBBUS_dbg_ram_0_RhWl),
      .byte_en(4'hF),
      .wdata(SUBBUS_dbg_ram_0_DataWr),
      .address(SUBBUS_dbg_ram_0_ReqAddr),
      .rdata(dbg_ram_0_sb_rdata),
      .ack(dbg_ram_0_sb_ack)
  );

endmodule
