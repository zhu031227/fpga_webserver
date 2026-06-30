//-------------------------------------------------------------------
// tb_webserver.sv — Verilator SV testbench
//
// Top module for Verilator. Instantiates DUT, generates clocks,
// drives RGMII RX pins for ARP injection.
// BFM runs inside DUT (sim_mod=1) and loads firmware from TCL.
//-------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_webserver;

  reg        clk_50m_in;
  reg        rgmii_rxc;
  reg        reset_l;

  reg        rgmii_rx_ctl;
  reg  [3:0] rgmii_rxd;

  reg  [7:0] pkt_mem [0:2047];
  integer    pkt_len;
  integer    i;

  // DUT
  xilinx_xc7a35tfgg484_webserver_top #(
      .sim_mod    (1),
      .script_file("../tcl/InstructRAM.tcl")
  ) u_dut (
      .clk_50m_in   (clk_50m_in),
      .reset_l      (reset_l),
      .uart_rx      (1'b1),
      .uart_tx      (),
      .rgmii_reset_l(),
      .rgmii_rxc    (rgmii_rxc),
      .rgmii_rx_ctl (rgmii_rx_ctl),
      .rgmii_rxd    (rgmii_rxd),
      .rgmii_txc    (),
      .rgmii_tx_ctl (),
      .rgmii_txd    (),
      .eth0_mdc     (),
      .eth0_mdio    (),
      .led_o        ()
  );

  // ---- 50 MHz clocks ----
  initial clk_50m_in = 1'b0;
  always #10 clk_50m_in = ~clk_50m_in;

  initial rgmii_rxc = 1'b0;
  always #10 rgmii_rxc = ~rgmii_rxc;

  // ---- RGMII DDR byte send ----
  // Drives low nibble on posedge, high nibble on negedge.
  // Returns immediately after negedge; the NEXT byte's posedge
  // naturally follows without inserting a glitch cycle.
  task rgmii_send_byte;
    input [7:0] data;
    input       dv;
    begin
      @(posedge rgmii_rxc);
      rgmii_rxd    <= data[3:0];
      rgmii_rx_ctl <= dv;
      @(negedge rgmii_rxc);
      rgmii_rxd    <= data[7:4];
      rgmii_rx_ctl <= dv;
    end
  endtask

  task rgmii_send_idle;
    input integer cycles;
    integer k;
    begin
      for (k = 0; k < cycles; k = k + 1) rgmii_send_byte(8'h00, 1'b0);
      // align to posedge after last idle byte
      @(posedge rgmii_rxc);
    end
  endtask

  // ---- Build ARP request ----
  task build_arp;
    begin
      // DST MAC broadcast
      pkt_mem[0]=8'hFF; pkt_mem[1]=8'hFF; pkt_mem[2]=8'hFF;
      pkt_mem[3]=8'hFF; pkt_mem[4]=8'hFF; pkt_mem[5]=8'hFF;
      // SRC MAC
      pkt_mem[6]=8'h00; pkt_mem[7]=8'h11; pkt_mem[8]=8'h22;
      pkt_mem[9]=8'h33; pkt_mem[10]=8'h44; pkt_mem[11]=8'h55;
      // EtherType ARP
      pkt_mem[12]=8'h08; pkt_mem[13]=8'h06;
      // HTYPE=1, PTYPE=0x0800
      pkt_mem[14]=8'h00; pkt_mem[15]=8'h01;
      pkt_mem[16]=8'h08; pkt_mem[17]=8'h00;
      // HLEN=6, PLEN=4
      pkt_mem[18]=8'h06; pkt_mem[19]=8'h04;
      // OPER=request
      pkt_mem[20]=8'h00; pkt_mem[21]=8'h01;
      // SHA
      pkt_mem[22]=8'h00; pkt_mem[23]=8'h11; pkt_mem[24]=8'h22;
      pkt_mem[25]=8'h33; pkt_mem[26]=8'h44; pkt_mem[27]=8'h55;
      // SPA=192.168.1.1
      pkt_mem[28]=8'hC0; pkt_mem[29]=8'hA8;
      pkt_mem[30]=8'h01; pkt_mem[31]=8'h01;
      // THA
      pkt_mem[32]=8'h00; pkt_mem[33]=8'h00; pkt_mem[34]=8'h00;
      pkt_mem[35]=8'h00; pkt_mem[36]=8'h00; pkt_mem[37]=8'h00;
      // TPA=192.168.1.88 (= Local_IP_ADDR)
      pkt_mem[38]=8'hC0; pkt_mem[39]=8'hA8;
      pkt_mem[40]=8'h01; pkt_mem[41]=8'h58;
      pkt_len = 42;
    end
  endtask

  // ---- Send frame with CRC ----
  task send_frame;
    integer  total, pad, j, bi;
    reg [31:0] crc;
    reg [7:0]  b;
    reg        mix;
    begin
      pad = (pkt_len < 60) ? (60 - pkt_len) : 0;
      total = pkt_len + pad;

      // CRC32
      crc = 32'hFFFF_FFFF;
      for (i = 0; i < pkt_len; i = i + 1) begin
        b = pkt_mem[i];
        for (bi = 0; bi < 8; bi = bi + 1) begin
          mix = crc[0] ^ b[bi];
          crc = {1'b0, crc[31:1]};
          if (mix) crc = crc ^ 32'hEDB8_8320;
        end
      end
      crc = ~crc;

      // IFG
      rgmii_send_idle(12);
      // Preamble + SFD
      repeat (7) rgmii_send_byte(8'h55, 1'b1);
      rgmii_send_byte(8'hD5, 1'b1);
      // Data
      for (i = 0; i < pkt_len; i = i + 1)
        rgmii_send_byte(pkt_mem[i], 1'b1);
      // Padding
      for (j = 0; j < pad; j = j + 1)
        rgmii_send_byte(8'h00, 1'b1);
      // FCS
      rgmii_send_byte(crc[7:0], 1'b1);
      rgmii_send_byte(crc[15:8], 1'b1);
      rgmii_send_byte(crc[23:16], 1'b1);
      rgmii_send_byte(crc[31:24], 1'b1);
      // Idle
      rgmii_send_idle(2);
    end
  endtask

  // ---- Debug: monitor gmii2mac internal data flow ----
  wire        dbg_rx_dv   = u_dut.u_webserver.i_eth0.Eth_RXDV;
  wire [7:0]  dbg_rx_data = u_dut.u_webserver.i_eth0.Eth_RXD;
  wire        dbg_fifo_empty  = u_dut.u_webserver.i_eth0.rx_afifo_empty;
  wire        dbg_fifo_full   = u_dut.u_webserver.i_eth0.rx_afifo_full;
  wire [9:0]  dbg_fifo_rdata  = u_dut.u_webserver.i_eth0.rx_afifo_data;
  wire        dbg_pre_en   = u_dut.u_webserver.i_eth0.rx_data_en_mac_in;
  wire [7:0]  dbg_pre_data = u_dut.u_webserver.i_eth0.rx_data_mac_in;
  wire        dbg_mac_sop  = u_dut.u_webserver.i_eth0.mac_rx_sop;
  wire        dbg_mac_en   = u_dut.u_webserver.i_eth0.mac_rx_en;
  wire [7:0]  dbg_mac_data = u_dut.u_webserver.i_eth0.mac_rx_data;
  wire        dbg_mac_eop  = u_dut.u_webserver.i_eth0.mac_rx_eop;

  // Watch GMII input activity
  reg dbg_gmii_seen;
  initial dbg_gmii_seen = 0;
  always @(posedge u_dut.u_webserver.i_eth0.Eth_RXC) begin
    if (dbg_rx_dv && !dbg_gmii_seen) begin
      $display("[%0t] GMII RX first valid byte: 0x%02h", $time, dbg_rx_data);
      dbg_gmii_seen <= 1;
    end
  end

  // Watch FIFO output
  reg dbg_fifo_seen;
  initial dbg_fifo_seen = 0;
  always @(posedge u_dut.u_webserver.clk_125mhz) begin
    if (!dbg_fifo_empty && !dbg_fifo_seen) begin
      $display("[%0t] FIFO first data out: 0x%03h (empty=%b full=%b)",
               $time, dbg_fifo_rdata, dbg_fifo_empty, dbg_fifo_full);
      dbg_fifo_seen <= 1;
    end
  end

  // Watch eth_presemble internal signals
  wire        dbg_pre_en_in  = u_dut.u_webserver.i_eth0.u_eth_presemble.rx_data_en_in;
  wire [7:0]  dbg_pre_din    = u_dut.u_webserver.i_eth0.u_eth_presemble.rx_data_in;
  wire        dbg_pre_valid  = u_dut.u_webserver.i_eth0.u_eth_presemble.rx_valid_header;
  wire [13:0] dbg_pre_cnt    = u_dut.u_webserver.i_eth0.u_eth_presemble.rx_eth_byte_cnt;
  wire [6:0]  dbg_pre_premble = u_dut.u_webserver.i_eth0.u_eth_presemble.rx_premble;

  // Watch eth_presemble output
  reg dbg_pre_seen;
  initial dbg_pre_seen = 0;
  always @(posedge u_dut.u_webserver.clk_125mhz) begin
    if (dbg_pre_en && !dbg_pre_seen) begin
      $display("[%0t] eth_presemble first frame byte: 0x%02h", $time, dbg_pre_data);
      dbg_pre_seen <= 1;
    end
  end

  // Detailed eth_presemble debug: print preamble detection progress
  reg [13:0] dbg_last_cnt;
  initial dbg_last_cnt = 0;
  always @(posedge u_dut.u_webserver.clk_125mhz) begin
    if (dbg_pre_en_in && dbg_pre_cnt != dbg_last_cnt) begin
      $display("[%0t] PRE: cnt=%0d data=0x%02h premble=%b valid=%b en_out=%b",
               $time, dbg_pre_cnt, dbg_pre_din, dbg_pre_premble, dbg_pre_valid, dbg_pre_en);
      dbg_last_cnt <= dbg_pre_cnt;
    end
  end

  // Watch MAC_RX output
  reg dbg_mac_seen;
  initial dbg_mac_seen = 0;
  always @(posedge u_dut.u_webserver.clk_125mhz) begin
    if (dbg_mac_sop && !dbg_mac_seen) begin
      $display("[%0t] MAC_RX SOP: data=0x%02h", $time, dbg_mac_data);
      dbg_mac_seen <= 1;
    end
  end

  // Watch CPU bus for register writes (sw_build_date at addr 2)
  reg dbg_sw_date_seen;
  initial dbg_sw_date_seen = 0;
  always @(posedge u_dut.u_webserver.clk_50mhz) begin
    if (!dbg_sw_date_seen && u_dut.u_webserver.cpu_req && u_dut.u_webserver.cpu_rhwl == 1'b0 &&
        u_dut.u_webserver.cpu_address[15:0] == 16'h2) begin
      $display("[%0t] CPU wrote sw_build_date = 0x%08h", $time, u_dut.u_webserver.cpu_wdata);
      dbg_sw_date_seen <= 1;
    end
  end

  // Watch TX FIFO push
  reg dbg_tx_push_seen;
  initial dbg_tx_push_seen = 0;
  always @(posedge u_dut.u_webserver.clk_50mhz) begin
    if (!dbg_tx_push_seen && u_dut.u_webserver.cpu_wr_wpkt_push_ind) begin
      $display("[%0t] TX FIFO packet pushed! len=%0d", $time, u_dut.u_webserver.cpu_wr_wpkt_len);
      dbg_tx_push_seen <= 1;
    end
  end

  // Watch cpu_channel TX output → gmii2mac
  wire        dbg_chan_tx_sop = u_dut.u_webserver.eth0_mac_tx_sop;
  wire        dbg_chan_tx_en  = u_dut.u_webserver.eth0_mac_tx_en;
  wire [7:0]  dbg_chan_tx_dat = u_dut.u_webserver.eth0_mac_tx_data;
  wire        dbg_chan_tx_eop = u_dut.u_webserver.eth0_mac_tx_eop;

  reg dbg_chan_sop_seen;
  initial dbg_chan_sop_seen = 0;
  always @(posedge u_dut.u_webserver.clk_125mhz) begin
    if (!dbg_chan_sop_seen && (dbg_chan_tx_sop || dbg_chan_tx_en || dbg_chan_tx_eop)) begin
      $display("[%0t] cpu_channel TX: sop=%b en=%b eop=%b data=0x%02h",
               $time, dbg_chan_tx_sop, dbg_chan_tx_en, dbg_chan_tx_eop, dbg_chan_tx_dat);
      if (dbg_chan_tx_sop) dbg_chan_sop_seen <= 1;
    end
  end

  // Watch GMII TX for ARP reply
  reg dbg_tx_seen;
  initial dbg_tx_seen = 0;
  always @(posedge u_dut.u_webserver.clk_125mhz) begin
    if (!dbg_tx_seen && u_dut.u_webserver.i_eth0.Eth_TXEN) begin
      $display("[%0t] GMII TX started: 0x%02h", $time, u_dut.u_webserver.i_eth0.Eth_TXD);
      dbg_tx_seen <= 1;
    end
  end

  // ---- Main ----
  initial begin
    $display("========================================");
    $display(" tb_webserver — Verilator (sim_mod=1)");
    $display(" BFM loads firmware from TCL script");
    $display("========================================");

    reset_l      = 1'b0;
    rgmii_rx_ctl = 1'b0;
    rgmii_rxd    = 4'h0;

    // Reset 200ns
    repeat (10) @(posedge clk_50m_in);
    reset_l = 1'b1;
    $display("[%0t] Reset released", $time);

    // Wait for BFM to load firmware (~300us for 2355 commands)
    #500000;
    $display("[%0t] BFM firmware load wait done", $time);

    // Send ARP request
    $display("[%0t] Sending ARP request...", $time);
    build_arp();
    send_frame();
    $display("[%0t] ARP frame sent", $time);

    // Run for additional time
    #1000000;
    $display("[%0t] Simulation complete", $time);
    $finish;
  end

endmodule
