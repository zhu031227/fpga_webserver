//Code Generate at: 2026-07-07 16:48:55
module reg_webserver(
  input [31:0] fpga_build_date,
  input [31:0] fpga_build_time,
  output reg [31:0] sw_build_date,
  output reg [31:0] sw_build_time,
  output reg [3:0] eth_greset,
  input [0:0] second_event,
  output reg [0:0] get_local_time,
  output reg get_local_time_ind,
  input [31:0] local_time_l,
  input [31:0] local_time_h,
  output reg [0:0] riscv_reset_l,
  output reg [31:0] debug_rw_0,
  output reg [31:0] debug_rw_1,
  output reg [31:0] debug_rw_2,
  output reg [31:0] debug_rw_3,
  input [31:0] debug_ro_0,
  input [31:0] debug_ro_1,
  input [31:0] debug_ro_2,
  input [31:0] debug_ro_3,
  input [31:0] eth_rx_correct_pkt_cnt,
  input [31:0] eth_rx_crc_err_pkt_cnt,
  input [31:0] eth_tx_correct_pkt_cnt,
  input [31:0] eth_tx_error_pkt_cnt,
  input [31:0] eth_rx_afifo_full_cnt,
  input [31:0] eth_rx_afifo_empty_cnt,
  input [31:0] eth_rx_data_err_line,
  output reg [15:0] filter_data,
  output reg [15:0] filter_offset,
  output reg SUBBUS_eth_mdio_Req,
  output reg SUBBUS_eth_mdio_RhWl,
  output reg [11:0] SUBBUS_eth_mdio_ReqAddr,
  output reg [31:0] SUBBUS_eth_mdio_DataWr,
  input [31:0] SUBBUS_eth_mdio_DataRd,
  input SUBBUS_eth_mdio_Ack,
  output reg [3:0] led,
  input [0:0] cpu_rd_empty,
  output reg [0:0] cpu_rd_rpkt_pop,
  output reg cpu_rd_rpkt_pop_ind,
  input [31:0] cpu_rd_rpkt_len,
  input [31:0] cpu_rd_rpkt_para,
  output reg [0:0] cpu_rd_ren,
  output reg [31:0] cpu_rd_raddr,
  input [31:0] cpu_rd_rdata,
  input [0:0] cpu_rd_reop_pre,
  output reg [31:0] cpu_rd_reg_rw_0,
  output reg [31:0] cpu_rd_reg_rw_1,
  output reg [31:0] cpu_rd_reg_rw_2,
  output reg [31:0] cpu_rd_reg_rw_3,
  input [31:0] cpu_rd_reg_ro_0,
  input [31:0] cpu_rd_reg_ro_1,
  output reg [31:0] cpu_rd_reg_wc_0,
  output reg cpu_rd_reg_wc_0_ind,
  input [31:0] cpu_rd_reg_rc_0,
  output reg cpu_rd_reg_rc_0_ind,
  input [0:0] cpu_wr_full,
  output reg [0:0] cpu_wr_wen,
  output reg cpu_wr_wen_ind,
  output reg [31:0] cpu_wr_waddr,
  output reg [31:0] cpu_wr_wdata,
  output reg [31:0] cpu_wr_wpkt_len,
  output reg [31:0] cpu_wr_wpkt_para,
  output reg [0:0] cpu_wr_wpkt_push,
  output reg cpu_wr_wpkt_push_ind,
  output reg [0:0] cpu_wr_reg_rw_0,
  output reg [31:0] cpu_wr_reg_rw_1,
  output reg [31:0] cpu_wr_reg_rw_2,
  output reg [31:0] cpu_wr_reg_rw_3,
  input [31:0] cpu_wr_reg_ro_0,
  input [31:0] cpu_wr_reg_ro_1,
  output reg [31:0] cpu_wr_reg_wc_0,
  output reg cpu_wr_reg_wc_0_ind,
  input [31:0] cpu_wr_reg_rc_0,
  output reg cpu_wr_reg_rc_0_ind,
  input [31:0] cpu_wr_reg_rc_1,
  output reg cpu_wr_reg_rc_1_ind,
  output RAMIF_program_ram_Ram_RlWh,
  output [14:0] RAMIF_program_ram_Ram_Addr,
  output [31:0] RAMIF_program_ram_Ram_WrData,
  input [31:0] RAMIF_program_ram_Ram_RdData,
  input [31:0] eth1_rx_correct_pkt_cnt,
  input [31:0] eth1_rx_crc_err_pkt_cnt,
  input [31:0] eth1_tx_correct_pkt_cnt,
  input [31:0] eth1_tx_error_pkt_cnt,
  input [31:0] eth1_rx_afifo_full_cnt,
  input [31:0] eth1_rx_afifo_empty_cnt,
  input [31:0] eth1_rx_data_err_line,
  input [31:0] eth2_rx_correct_pkt_cnt,
  input [31:0] eth2_rx_crc_err_pkt_cnt,
  input [31:0] eth2_tx_correct_pkt_cnt,
  input [31:0] eth2_tx_error_pkt_cnt,
  input [31:0] eth2_rx_afifo_full_cnt,
  input [31:0] eth2_rx_afifo_empty_cnt,
  input [31:0] eth2_rx_data_err_line,
  output reg [31:0] local_mac_h,
  output reg [15:0] local_mac_l,
  output reg [31:0] local_ip,
  output reg [31:0] local_netmask,
  output reg [31:0] local_gateway,
  output reg [0:0] local_config_save,
  output reg local_config_save_ind,
  output reg [0:0] local_config_load,
  output reg local_config_load_ind,
  input [0:0] local_config_valid,
  output reg [1:0] wl_ctrl,
  input [15:0] wl_status,
  input [31:0] wl_lat_match_mac_h,
  input [15:0] wl_lat_match_mac_l,
  output reg SUBBUS_eth1_mdio_Req,
  output reg SUBBUS_eth1_mdio_RhWl,
  output reg [11:0] SUBBUS_eth1_mdio_ReqAddr,
  output reg [31:0] SUBBUS_eth1_mdio_DataWr,
  input [31:0] SUBBUS_eth1_mdio_DataRd,
  input SUBBUS_eth1_mdio_Ack,
  output reg SUBBUS_eth2_mdio_Req,
  output reg SUBBUS_eth2_mdio_RhWl,
  output reg [11:0] SUBBUS_eth2_mdio_ReqAddr,
  output reg [31:0] SUBBUS_eth2_mdio_DataWr,
  input [31:0] SUBBUS_eth2_mdio_DataRd,
  input SUBBUS_eth2_mdio_Ack,
  output reg SUBBUS_sflash_Req,
  output reg SUBBUS_sflash_RhWl,
  output reg [11:0] SUBBUS_sflash_ReqAddr,
  output reg [31:0] SUBBUS_sflash_DataWr,
  input [31:0] SUBBUS_sflash_DataRd,
  input SUBBUS_sflash_Ack,
  output RAMIF_mac_whitelist_Ram_RlWh,
  output [11:0] RAMIF_mac_whitelist_Ram_Addr,
  output [31:0] RAMIF_mac_whitelist_Ram_WrData,
  input  [31:0] RAMIF_mac_whitelist_Ram_RdData,
  output reg [0:0] bootloader_trigger,
  output reg bootloader_trigger_ind,
  input [2:0] bootloader_status,
  output reg [31:0] bootloader_flash_addr,
  output reg [31:0] bootloader_length,
  
  input clk,
  input rst_n,
  input req,
  input rhwl,
  input [31:0] wdata,
  input [15:0] address,
  output reg[31:0] rdata,
  output reg ack
  );
  
  reg timeout_ack;
  reg is_req;
  reg [15:0] is_req_cnt;
  reg [31:0] reg_rdata;
  reg reg_ack;
  reg [31:0]eth_mdio_sb_rdata;
  reg eth_mdio_sb_ack;
  reg [31:0]eth1_mdio_sb_rdata;
  reg eth1_mdio_sb_ack;
  reg [31:0]eth2_mdio_sb_rdata;
  reg eth2_mdio_sb_ack;
  reg [31:0]sflash_sb_rdata;
  reg sflash_sb_ack;

  reg SUBBUS_program_ram_Req;
  reg SUBBUS_program_ram_RhWl;
  reg [14:0] SUBBUS_program_ram_ReqAddr;
  reg [31:0] SUBBUS_program_ram_DataWr;
  wire [31:0]program_ram_sb_rdata;
  wire program_ram_sb_ack;

  // mac_whitelist RamIF (same pattern as program_ram)
  reg  SUBBUS_mac_whitelist_Req;
  reg  SUBBUS_mac_whitelist_RhWl;
  reg  [11:0] SUBBUS_mac_whitelist_ReqAddr;
  reg  [31:0] SUBBUS_mac_whitelist_DataWr;
  wire [31:0] mac_whitelist_sb_rdata;
  wire mac_whitelist_sb_ack;

  
  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      is_req <= 1'b0;
      is_req_cnt <= 16'b0;
      timeout_ack <= 1'b0;
    end
    else begin 
      timeout_ack <= 1'b0;
      if(req == 1'b1)begin 
        is_req <= req;
      end
      if(is_req == 1'b1)begin 
        is_req_cnt <= is_req_cnt + 1;
      end
      else begin 
        is_req_cnt <= 16'b0;
      end
      if(is_req_cnt >= 16'hf000 || ack == 1'b1)begin 
        is_req <= 1'b0;
      end
      if(is_req_cnt == 16'hf000)begin 
        timeout_ack <= 1'b1;
      end
    end
  end

  
  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      sw_build_date <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h2)begin
        sw_build_date <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      sw_build_time <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h3)begin
        sw_build_time <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      eth_greset <= 4'hF;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h4)begin
        eth_greset <= wdata[3:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      get_local_time <= 1'h0;
    get_local_time_ind <= 1'b0;
    end
    else begin 
      get_local_time_ind <= 1'b0;
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6)begin
        get_local_time_ind <= 1'b1;
        get_local_time <= wdata[0:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      riscv_reset_l <= 1'h1;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'hf)begin
        riscv_reset_l <= wdata[0:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      debug_rw_0 <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h10)begin
        debug_rw_0 <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      debug_rw_1 <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h11)begin
        debug_rw_1 <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      debug_rw_2 <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h12)begin
        debug_rw_2 <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      debug_rw_3 <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h13)begin
        debug_rw_3 <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      filter_data <= 16'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h200)begin
        filter_data <= wdata[15:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      filter_offset <= 16'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h201)begin
        filter_offset <= wdata[15:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      led <= 4'hF;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h30)begin
        led <= wdata[3:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_rd_rpkt_pop <= 1'h0;
    cpu_rd_rpkt_pop_ind <= 1'b0;
    end
    else begin 
      cpu_rd_rpkt_pop_ind <= 1'b0;
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6001)begin
        cpu_rd_rpkt_pop_ind <= 1'b1;
        cpu_rd_rpkt_pop <= wdata[0:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_rd_ren <= 1'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6004)begin
        cpu_rd_ren <= wdata[0:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_rd_raddr <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6005)begin
        cpu_rd_raddr <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_rd_reg_rw_0 <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6008)begin
        cpu_rd_reg_rw_0 <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_rd_reg_rw_1 <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6009)begin
        cpu_rd_reg_rw_1 <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_rd_reg_rw_2 <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h600A)begin
        cpu_rd_reg_rw_2 <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_rd_reg_rw_3 <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h600B)begin
        cpu_rd_reg_rw_3 <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_rd_reg_wc_0 <= 32'h0;
    cpu_rd_reg_wc_0_ind <= 1'b0;
    end
    else begin 
      cpu_rd_reg_wc_0_ind <= 1'b0;
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h600E)begin
        cpu_rd_reg_wc_0_ind <= 1'b1;
        cpu_rd_reg_wc_0 <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_rd_reg_rc_0_ind <= 1'b0;
    end
    else begin 
      cpu_rd_reg_rc_0_ind <= 1'b0;
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h600F)
        cpu_rd_reg_rc_0_ind <= 1'b1;
      end
    end
  
  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_wr_wen <= 1'h0;
    cpu_wr_wen_ind <= 1'b0;
    end
    else begin 
      cpu_wr_wen_ind <= 1'b0;
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6101)begin
        cpu_wr_wen_ind <= 1'b1;
        cpu_wr_wen <= wdata[0:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_wr_waddr <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6102)begin
        cpu_wr_waddr <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_wr_wdata <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6103)begin
        cpu_wr_wdata <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_wr_wpkt_len <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6104)begin
        cpu_wr_wpkt_len <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_wr_wpkt_para <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6105)begin
        cpu_wr_wpkt_para <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_wr_wpkt_push <= 1'h0;
    cpu_wr_wpkt_push_ind <= 1'b0;
    end
    else begin 
      cpu_wr_wpkt_push_ind <= 1'b0;
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6106)begin
        cpu_wr_wpkt_push_ind <= 1'b1;
        cpu_wr_wpkt_push <= wdata[0:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_wr_reg_rw_0 <= 1'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6107)begin
        cpu_wr_reg_rw_0 <= wdata[0:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_wr_reg_rw_1 <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6108)begin
        cpu_wr_reg_rw_1 <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_wr_reg_rw_2 <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h6109)begin
        cpu_wr_reg_rw_2 <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_wr_reg_rw_3 <= 32'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h610A)begin
        cpu_wr_reg_rw_3 <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_wr_reg_wc_0 <= 32'h0;
    cpu_wr_reg_wc_0_ind <= 1'b0;
    end
    else begin 
      cpu_wr_reg_wc_0_ind <= 1'b0;
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h610D)begin
        cpu_wr_reg_wc_0_ind <= 1'b1;
        cpu_wr_reg_wc_0 <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_wr_reg_rc_0_ind <= 1'b0;
    end
    else begin 
      cpu_wr_reg_rc_0_ind <= 1'b0;
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h610E)
        cpu_wr_reg_rc_0_ind <= 1'b1;
      end
    end
  
  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      cpu_wr_reg_rc_1_ind <= 1'b0;
    end
    else begin 
      cpu_wr_reg_rc_1_ind <= 1'b0;
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h610F)
        cpu_wr_reg_rc_1_ind <= 1'b1;
      end
    end
  
  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      local_mac_h <= 32'h00000102;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h202)begin
        local_mac_h <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      local_mac_l <= 16'h0406;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h203)begin
        local_mac_l <= wdata[15:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      local_ip <= 32'hC0A80158;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h204)begin
        local_ip <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      local_netmask <= 32'hFFFFFF00;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h205)begin
        local_netmask <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      local_gateway <= 32'hC0A80101;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h206)begin
        local_gateway <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      local_config_save <= 1'h0;
    local_config_save_ind <= 1'b0;
    end
    else begin 
      local_config_save_ind <= 1'b0;
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h207)begin
        local_config_save_ind <= 1'b1;
        local_config_save <= wdata[0:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      local_config_load <= 1'h0;
    local_config_load_ind <= 1'b0;
    end
    else begin 
      local_config_load_ind <= 1'b0;
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h208)begin
        local_config_load_ind <= 1'b1;
        local_config_load <= wdata[0:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      wl_ctrl <= 2'h0;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h300)begin
        wl_ctrl <= wdata[1:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      bootloader_trigger <= 1'h0;
    bootloader_trigger_ind <= 1'b0;
    end
    else begin 
      bootloader_trigger_ind <= 1'b0;
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h310)begin
        bootloader_trigger_ind <= 1'b1;
        bootloader_trigger <= wdata[0:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      bootloader_flash_addr <= 32'h00400000;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h312)begin
        bootloader_flash_addr <= wdata[31:0];
      end
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      bootloader_length <= 32'h00004000;
    end
    else begin 
      if(req == 1'b1 && rhwl == 1'b0 && address == 16'h313)begin
        bootloader_length <= wdata[31:0];
      end
    end
  end

  
  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      reg_rdata <= 32'b0;
      reg_ack <= 1'b0;
    end
    else begin 
      reg_ack <= 1'b0;
      if(req == 1'b1 && rhwl == 1'b1)reg_rdata <= 32'b0;
      if(req == 1'b1 && address == 16'h0)begin 
        reg_rdata[31:0]<=fpga_build_date;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h1)begin 
        reg_rdata[31:0]<=fpga_build_time;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h2)begin 
        reg_rdata[31:0]<=sw_build_date;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h3)begin 
        reg_rdata[31:0]<=sw_build_time;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h4)begin 
        reg_rdata[3:0]<=eth_greset;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h5)begin 
        reg_rdata[0:0]<=second_event;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6)begin 
        reg_rdata[0:0]<=get_local_time;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h7)begin 
        reg_rdata[31:0]<=local_time_l;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h8)begin 
        reg_rdata[31:0]<=local_time_h;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'hf)begin 
        reg_rdata[0:0]<=riscv_reset_l;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h10)begin 
        reg_rdata[31:0]<=debug_rw_0;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h11)begin 
        reg_rdata[31:0]<=debug_rw_1;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h12)begin 
        reg_rdata[31:0]<=debug_rw_2;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h13)begin 
        reg_rdata[31:0]<=debug_rw_3;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h20)begin 
        reg_rdata[31:0]<=debug_ro_0;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h21)begin 
        reg_rdata[31:0]<=debug_ro_1;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h22)begin 
        reg_rdata[31:0]<=debug_ro_2;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h23)begin 
        reg_rdata[31:0]<=debug_ro_3;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h100)begin 
        reg_rdata[31:0]<=eth_rx_correct_pkt_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h101)begin 
        reg_rdata[31:0]<=eth_rx_crc_err_pkt_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h102)begin 
        reg_rdata[31:0]<=eth_tx_correct_pkt_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h103)begin 
        reg_rdata[31:0]<=eth_tx_error_pkt_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h104)begin 
        reg_rdata[31:0]<=eth_rx_afifo_full_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h105)begin 
        reg_rdata[31:0]<=eth_rx_afifo_empty_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h106)begin 
        reg_rdata[31:0]<=eth_rx_data_err_line;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h200)begin 
        reg_rdata[15:0]<=filter_data;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h201)begin 
        reg_rdata[15:0]<=filter_offset;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h30)begin 
        reg_rdata[3:0]<=led;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6000)begin 
        reg_rdata[0:0]<=cpu_rd_empty;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6001)begin 
        reg_rdata[0:0]<=cpu_rd_rpkt_pop;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6002)begin 
        reg_rdata[31:0]<=cpu_rd_rpkt_len;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6003)begin 
        reg_rdata[31:0]<=cpu_rd_rpkt_para;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6004)begin 
        reg_rdata[0:0]<=cpu_rd_ren;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6005)begin 
        reg_rdata[31:0]<=cpu_rd_raddr;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6006)begin 
        reg_rdata[31:0]<=cpu_rd_rdata;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6007)begin 
        reg_rdata[0:0]<=cpu_rd_reop_pre;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6008)begin 
        reg_rdata[31:0]<=cpu_rd_reg_rw_0;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6009)begin 
        reg_rdata[31:0]<=cpu_rd_reg_rw_1;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h600A)begin 
        reg_rdata[31:0]<=cpu_rd_reg_rw_2;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h600B)begin 
        reg_rdata[31:0]<=cpu_rd_reg_rw_3;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h600C)begin 
        reg_rdata[31:0]<=cpu_rd_reg_ro_0;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h600D)begin 
        reg_rdata[31:0]<=cpu_rd_reg_ro_1;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h600E)begin 
        reg_rdata[31:0]<=cpu_rd_reg_wc_0;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h600F)begin 
        reg_rdata[31:0]<=cpu_rd_reg_rc_0;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6100)begin 
        reg_rdata[0:0]<=cpu_wr_full;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6101)begin 
        reg_rdata[0:0]<=cpu_wr_wen;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6102)begin 
        reg_rdata[31:0]<=cpu_wr_waddr;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6103)begin 
        reg_rdata[31:0]<=cpu_wr_wdata;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6104)begin 
        reg_rdata[31:0]<=cpu_wr_wpkt_len;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6105)begin 
        reg_rdata[31:0]<=cpu_wr_wpkt_para;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6106)begin 
        reg_rdata[0:0]<=cpu_wr_wpkt_push;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6107)begin 
        reg_rdata[0:0]<=cpu_wr_reg_rw_0;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6108)begin 
        reg_rdata[31:0]<=cpu_wr_reg_rw_1;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h6109)begin 
        reg_rdata[31:0]<=cpu_wr_reg_rw_2;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h610A)begin 
        reg_rdata[31:0]<=cpu_wr_reg_rw_3;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h610B)begin 
        reg_rdata[31:0]<=cpu_wr_reg_ro_0;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h610C)begin 
        reg_rdata[31:0]<=cpu_wr_reg_ro_1;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h610D)begin 
        reg_rdata[31:0]<=cpu_wr_reg_wc_0;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h610E)begin 
        reg_rdata[31:0]<=cpu_wr_reg_rc_0;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h610F)begin 
        reg_rdata[31:0]<=cpu_wr_reg_rc_1;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h110)begin 
        reg_rdata[31:0]<=eth1_rx_correct_pkt_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h111)begin 
        reg_rdata[31:0]<=eth1_rx_crc_err_pkt_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h112)begin 
        reg_rdata[31:0]<=eth1_tx_correct_pkt_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h113)begin 
        reg_rdata[31:0]<=eth1_tx_error_pkt_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h114)begin 
        reg_rdata[31:0]<=eth1_rx_afifo_full_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h115)begin 
        reg_rdata[31:0]<=eth1_rx_afifo_empty_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h116)begin 
        reg_rdata[31:0]<=eth1_rx_data_err_line;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h118)begin 
        reg_rdata[31:0]<=eth2_rx_correct_pkt_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h119)begin 
        reg_rdata[31:0]<=eth2_rx_crc_err_pkt_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h11A)begin 
        reg_rdata[31:0]<=eth2_tx_correct_pkt_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h11B)begin 
        reg_rdata[31:0]<=eth2_tx_error_pkt_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h11C)begin 
        reg_rdata[31:0]<=eth2_rx_afifo_full_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h11D)begin 
        reg_rdata[31:0]<=eth2_rx_afifo_empty_cnt;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h11E)begin 
        reg_rdata[31:0]<=eth2_rx_data_err_line;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h202)begin 
        reg_rdata[31:0]<=local_mac_h;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h203)begin 
        reg_rdata[15:0]<=local_mac_l;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h204)begin 
        reg_rdata[31:0]<=local_ip;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h205)begin 
        reg_rdata[31:0]<=local_netmask;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h206)begin 
        reg_rdata[31:0]<=local_gateway;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h207)begin 
        reg_rdata[0:0]<=local_config_save;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h208)begin 
        reg_rdata[0:0]<=local_config_load;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h209)begin 
        reg_rdata[0:0]<=local_config_valid;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h300)begin 
        reg_rdata[1:0]<=wl_ctrl;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h301)begin 
        reg_rdata[15:0]<=wl_status;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h302)begin 
        reg_rdata[31:0]<=wl_lat_match_mac_h;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h303)begin 
        reg_rdata[15:0]<=wl_lat_match_mac_l;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h310)begin 
        reg_rdata[0:0]<=bootloader_trigger;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h311)begin 
        reg_rdata[2:0]<=bootloader_status;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h312)begin 
        reg_rdata[31:0]<=bootloader_flash_addr;
        reg_ack <= 1'b1;
      end
      if(req == 1'b1 && address == 16'h313)begin 
        reg_rdata[31:0]<=bootloader_length;
        reg_ack <= 1'b1;
      end
      
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      SUBBUS_eth_mdio_Req <= 1'b0;
      SUBBUS_eth_mdio_RhWl <= 1'b1;
      SUBBUS_eth_mdio_ReqAddr <= 12'b0;
      SUBBUS_eth_mdio_DataWr <= 32'b0;
    end
    else begin 
      if(address >= 16'h1000 && address <= 16'h1fff)begin 
        SUBBUS_eth_mdio_Req <= req;
      end
      SUBBUS_eth_mdio_RhWl <= rhwl;
      SUBBUS_eth_mdio_ReqAddr <= address[11:0];
      SUBBUS_eth_mdio_DataWr <= wdata;
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      SUBBUS_program_ram_Req <= 1'b0;
      SUBBUS_program_ram_RhWl <= 1'b1;
      SUBBUS_program_ram_ReqAddr <= 15'b0;
      SUBBUS_program_ram_DataWr <= 32'b0;
    end
    else begin 
      if(address >= 16'h8000 && address <= 16'hffff)begin 
        SUBBUS_program_ram_Req <= req;
      end
      SUBBUS_program_ram_RhWl <= rhwl;
      SUBBUS_program_ram_ReqAddr <= address[14:0];
      SUBBUS_program_ram_DataWr <= wdata;
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      SUBBUS_eth1_mdio_Req <= 1'b0;
      SUBBUS_eth1_mdio_RhWl <= 1'b1;
      SUBBUS_eth1_mdio_ReqAddr <= 12'b0;
      SUBBUS_eth1_mdio_DataWr <= 32'b0;
    end
    else begin 
      if(address >= 16'h2000 && address <= 16'h2fff)begin 
        SUBBUS_eth1_mdio_Req <= req;
      end
      SUBBUS_eth1_mdio_RhWl <= rhwl;
      SUBBUS_eth1_mdio_ReqAddr <= address[11:0];
      SUBBUS_eth1_mdio_DataWr <= wdata;
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      SUBBUS_eth2_mdio_Req <= 1'b0;
      SUBBUS_eth2_mdio_RhWl <= 1'b1;
      SUBBUS_eth2_mdio_ReqAddr <= 12'b0;
      SUBBUS_eth2_mdio_DataWr <= 32'b0;
    end
    else begin 
      if(address >= 16'h3000 && address <= 16'h3fff)begin 
        SUBBUS_eth2_mdio_Req <= req;
      end
      SUBBUS_eth2_mdio_RhWl <= rhwl;
      SUBBUS_eth2_mdio_ReqAddr <= address[11:0];
      SUBBUS_eth2_mdio_DataWr <= wdata;
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      SUBBUS_sflash_Req <= 1'b0;
      SUBBUS_sflash_RhWl <= 1'b1;
      SUBBUS_sflash_ReqAddr <= 12'b0;
      SUBBUS_sflash_DataWr <= 32'b0;
    end
    else begin 
      if(address >= 16'h4000 && address <= 16'h4fff)begin 
        SUBBUS_sflash_Req <= req;
      end
      SUBBUS_sflash_RhWl <= rhwl;
      SUBBUS_sflash_ReqAddr <= address[11:0];
      SUBBUS_sflash_DataWr <= wdata;
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      SUBBUS_mac_whitelist_Req <= 1'b0;
      SUBBUS_mac_whitelist_RhWl <= 1'b1;
      SUBBUS_mac_whitelist_ReqAddr <= 12'b0;
      SUBBUS_mac_whitelist_DataWr <= 32'b0;
    end
    else begin 
      if(address >= 16'h5000 && address <= 16'h5fff)begin 
        SUBBUS_mac_whitelist_Req <= req;
      end
      SUBBUS_mac_whitelist_RhWl <= rhwl;
      SUBBUS_mac_whitelist_ReqAddr <= address[11:0];
      SUBBUS_mac_whitelist_DataWr <= wdata;
    end
  end

  
  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      eth_mdio_sb_ack <= 1'b0;
      eth_mdio_sb_rdata <= 32'b0;
    end
    else begin 
      eth_mdio_sb_ack <= SUBBUS_eth_mdio_Ack;
      eth_mdio_sb_rdata <= SUBBUS_eth_mdio_DataRd;
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      eth1_mdio_sb_ack <= 1'b0;
      eth1_mdio_sb_rdata <= 32'b0;
    end
    else begin 
      eth1_mdio_sb_ack <= SUBBUS_eth1_mdio_Ack;
      eth1_mdio_sb_rdata <= SUBBUS_eth1_mdio_DataRd;
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      eth2_mdio_sb_ack <= 1'b0;
      eth2_mdio_sb_rdata <= 32'b0;
    end
    else begin 
      eth2_mdio_sb_ack <= SUBBUS_eth2_mdio_Ack;
      eth2_mdio_sb_rdata <= SUBBUS_eth2_mdio_DataRd;
    end
  end

  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      sflash_sb_ack <= 1'b0;
      sflash_sb_rdata <= 32'b0;
    end
    else begin 
      sflash_sb_ack <= SUBBUS_sflash_Ack;
      sflash_sb_rdata <= SUBBUS_sflash_DataRd;
    end
  end

  // mac_whitelist RamIF (replaces old SubBus ack block)
  ramintf
    #(
    .DataBits(32),
    .AddrBits(12)
    ) RAMIF_mac_whitelist(
    .Ram_RdData(RAMIF_mac_whitelist_Ram_RdData),
    .Ram_RlWh(RAMIF_mac_whitelist_Ram_RlWh),
    .Ram_Addr(RAMIF_mac_whitelist_Ram_Addr),
    .Ram_WrData(RAMIF_mac_whitelist_Ram_WrData),
    .clk(clk),
    .rst_n(rst_n),
    .req(SUBBUS_mac_whitelist_Req),
    .rhwl(SUBBUS_mac_whitelist_RhWl),
    .wdata(SUBBUS_mac_whitelist_DataWr),
    .address(SUBBUS_mac_whitelist_ReqAddr),
    .rdata(mac_whitelist_sb_rdata),
    .ack(mac_whitelist_sb_ack)
    );


  always @ (posedge clk or negedge rst_n) begin 
    if(!rst_n) begin 
      ack <= 1'b0;
      rdata <= 32'b0;
    end
    else begin 
      if(eth_mdio_sb_ack)rdata <= eth_mdio_sb_rdata;
      if(program_ram_sb_ack)rdata <= program_ram_sb_rdata;
      if(eth1_mdio_sb_ack)rdata <= eth1_mdio_sb_rdata;
      if(eth2_mdio_sb_ack)rdata <= eth2_mdio_sb_rdata;
      if(sflash_sb_ack)rdata <= sflash_sb_rdata;
      if(mac_whitelist_sb_ack)rdata <= mac_whitelist_sb_rdata;
      ack <=timeout_ack | reg_ack |eth_mdio_sb_ack |program_ram_sb_ack |eth1_mdio_sb_ack |eth2_mdio_sb_ack |sflash_sb_ack |mac_whitelist_sb_ack;
      if(timeout_ack)rdata <= 32'hdeaddead;
      if(reg_ack)rdata <= reg_rdata;
    end
  end

  
  ramintf 
    #( 
    .DataBits(32),
    .AddrBits(15)
    ) RAMIF_program_ram(
    .Ram_RdData(RAMIF_program_ram_Ram_RdData), 
    .Ram_RlWh(RAMIF_program_ram_Ram_RlWh), 
    .Ram_Addr(RAMIF_program_ram_Ram_Addr), 
    .Ram_WrData(RAMIF_program_ram_Ram_WrData), 
    .clk(clk), 
    .rst_n(rst_n), 
    .req(SUBBUS_program_ram_Req), 
    .rhwl(SUBBUS_program_ram_RhWl), 
    .wdata(SUBBUS_program_ram_DataWr), 
    .address(SUBBUS_program_ram_ReqAddr), 
    .rdata(program_ram_sb_rdata), 
    .ack(program_ram_sb_ack) 
    ); 
      
  
endmodule 


