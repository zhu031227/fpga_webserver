//-------------------------------------------------------------------
// tb_xilinx_top.sv — Testbench for xilinx_xc7a35tfgg484_webserver_top
//
// iverilog simulation with:
//   - sim_mod = 1  (PLL bypass, lcpu_bfm, behavioral sim)
//   - defparam device_vendor = "xilinx" (enables Xilinx RGMII path)
//   - RGMII RX stimulus via DDR nibble driving
//   - Internal GMII TX capture for response observation
//-------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_xilinx_top;

  //-------------------------------------------------------------------
  // Parameters
  //-------------------------------------------------------------------
  localparam int PKT_ARP = 1;
  localparam int PKT_ICMP = 2;
  localparam int PKT_TCP = 3;
  localparam int PKT_UDP = 4;
  localparam int ETH_MIN_FRAME_WITH_FCS = 64;
  localparam int ETH_MIN_FRAME_WO_FCS = ETH_MIN_FRAME_WITH_FCS - 4;
  localparam time SIM_TIMEOUT_NS = 200_000;

  parameter int PKT_TYPE = PKT_ARP;
  parameter int START_DELAY_NS = 2000000;

  // ARP packet fields
  parameter logic [47:0] SRC_MAC = 48'h0011_2233_4455;
  parameter logic [47:0] DST_MAC = 48'h0000_0102_0405;
  parameter logic [31:0] SRC_IP = 32'hA9FE_0101;
  parameter logic [31:0] DST_IP = 32'hA9FE_0F58;

  //-------------------------------------------------------------------
  // Clocks & Reset
  //-------------------------------------------------------------------
  reg        clk_50m_in;
  reg        reset_l;

  //-------------------------------------------------------------------
  // RGMII RX stimulus (driven by testbench)
  //-------------------------------------------------------------------
  reg        rgmii_rxc;
  reg        rgmii_rx_ctl;
  reg  [3:0] rgmii_rxd;

  //-------------------------------------------------------------------
  // DUT UART / MDIO / RGMII TX / LED
  //-------------------------------------------------------------------
  wire       uart_tx;
  wire       eth0_mdc;
  wire       eth0_mdio;
  wire       rgmii_txc;
  wire       rgmii_tx_ctl;
  wire [3:0] rgmii_txd;
  wire [3:0] led_o;

  //-------------------------------------------------------------------
  // DUT Instantiation
  //-------------------------------------------------------------------
  sim_top #(
      .sim_mod    (1),
      .script_file("../tcl/InstructRAM.tcl")
  ) u_dut (
      .clk_50m_in  (clk_50m_in),
      .reset_l     (reset_l),
      .uart_rx     (1'b1),          // UART RX idle high
      .uart_tx     (uart_tx),
      .rgmii_rxc   (rgmii_rxc),
      .rgmii_rx_ctl(rgmii_rx_ctl),
      .rgmii_rxd   (rgmii_rxd),
      .rgmii_txc   (rgmii_txc),
      .rgmii_tx_ctl(rgmii_tx_ctl),
      .rgmii_txd   (rgmii_txd),
      .eth0_mdc    (eth0_mdc),
      .eth0_mdio   (eth0_mdio),
      .led         (led_o)
  );

  //-------------------------------------------------------------------
  // Helper tasks — byte/word queue manipulation
  //-------------------------------------------------------------------
  task automatic append_u16_be(inout byte unsigned q[$], input logic [15:0] v);
    q.push_back(v[15:8]);
    q.push_back(v[7:0]);
  endtask

  task automatic append_u32_be(inout byte unsigned q[$], input logic [31:0] v);
    q.push_back(v[31:24]);
    q.push_back(v[23:16]);
    q.push_back(v[15:8]);
    q.push_back(v[7:0]);
  endtask

  task automatic append_mac(inout byte unsigned q[$], input logic [47:0] mac);
    q.push_back(mac[47:40]);
    q.push_back(mac[39:32]);
    q.push_back(mac[31:24]);
    q.push_back(mac[23:16]);
    q.push_back(mac[15:8]);
    q.push_back(mac[7:0]);
  endtask

  task automatic eth_crc32_byte(input [7:0] b, inout logic [31:0] crc);
    for (int bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
      bit mix = crc[0] ^ b[bit_idx];
      crc = {1'b0, crc[31:1]};
      if (mix) crc = crc ^ 32'hEDB8_8320;
    end
  endtask

  //-------------------------------------------------------------------
  // RGMII DDR byte send
  //-------------------------------------------------------------------
  task automatic rgmii_send_byte(input byte unsigned data, input bit dv, input bit er);
    @(negedge rgmii_rxc);
    rgmii_rxd    <= data[3:0];
    rgmii_rx_ctl <= dv;

    @(posedge rgmii_rxc);
    rgmii_rxd    <= data[7:4];
    rgmii_rx_ctl <= (dv ^ er);
  endtask

  task automatic rgmii_send_idle(input int cycles);
    for (int i = 0; i < cycles; i++) begin
      rgmii_send_byte(8'h00, 1'b0, 1'b0);
    end
  endtask

  //-------------------------------------------------------------------
  // Send Ethernet frame via RGMII DDR
  //-------------------------------------------------------------------
  task automatic rgmii_send_frame(inout byte unsigned mac_frame_wo_fcs[$]);
    byte unsigned tx_frame[$];
    int pad_bytes;
    logic [31:0] fcs;

    tx_frame  = mac_frame_wo_fcs;
    pad_bytes = ETH_MIN_FRAME_WO_FCS - tx_frame.size();
    if (pad_bytes > 0) begin
      repeat (pad_bytes) tx_frame.push_back(8'h00);
    end

    // Compute CRC32 byte-by-byte
    fcs = 32'hFFFF_FFFF;
    for (int ci = 0; ci < tx_frame.size(); ci = ci + 1) eth_crc32_byte(tx_frame[ci], fcs);
    fcs = ~fcs;

    // Inter-frame gap
    rgmii_send_idle(12);

    // Preamble + SFD
    repeat (7) rgmii_send_byte(8'h55, 1'b1, 1'b0);
    rgmii_send_byte(8'hD5, 1'b1, 1'b0);

    // Frame bytes
    for (int i = 0; i < tx_frame.size(); i++) rgmii_send_byte(tx_frame[i], 1'b1, 1'b0);

    // FCS (LSByte first on wire)
    rgmii_send_byte(fcs[7:0], 1'b1, 1'b0);
    rgmii_send_byte(fcs[15:8], 1'b1, 1'b0);
    rgmii_send_byte(fcs[23:16], 1'b1, 1'b0);
    rgmii_send_byte(fcs[31:24], 1'b1, 1'b0);

    // Return to idle
    rgmii_send_idle(2);
  endtask

  //-------------------------------------------------------------------
  // Build ARP request packet
  //-------------------------------------------------------------------
  task automatic build_arp_request(inout byte unsigned frame[$]);
    frame.delete();
    append_mac(frame, 48'hFFFF_FFFF_FFFF);  // broadcast
    append_mac(frame, SRC_MAC);
    append_u16_be(frame, 16'h0806);  // EtherType = ARP

    append_u16_be(frame, 16'h0001);  // HTYPE = Ethernet
    append_u16_be(frame, 16'h0800);  // PTYPE = IPv4
    frame.push_back(8'h06);  // HLEN = 6
    frame.push_back(8'h04);  // PLEN = 4
    append_u16_be(frame, 16'h0001);  // OPER = request
    append_mac(frame, SRC_MAC);  // sender MAC
    append_u32_be(frame, SRC_IP);  // sender IP
    append_mac(frame, 48'h0000_0000_0000);  // target MAC (unknown)
    append_u32_be(frame, DST_IP);  // target IP
  endtask

  // (vendor="" → behavioral rgmii_rx/tx from vendor_stubs.sv)

  //-------------------------------------------------------------------
  // Internal signal probes (access DUT hierarchy)
  //-------------------------------------------------------------------
  // GMII TX (SDR — observed from webserver_wrapper)
  wire         gmii_tx_en = u_dut.u_webserver.gmii_tx_en;
  wire  [ 7:0] gmii_txd = u_dut.u_webserver.gmii_txd;
  wire         gmii_tx_err = u_dut.u_webserver.gmii_tx_err;

  // GMII RX internal
  wire         gmii_rx_dv = u_dut.u_webserver.gmii_rx_dv;
  wire  [ 7:0] gmii_rxd_int = u_dut.u_webserver.gmii_rxd;

  // MAC-level packet interface (125MHz domain)
  wire         eth0_mac_rx_sop = u_dut.u_webserver.i_eth0.mac_rx_sop;
  wire         eth0_mac_rx_en = u_dut.u_webserver.i_eth0.mac_rx_en;
  wire  [ 7:0] eth0_mac_rx_data = u_dut.u_webserver.i_eth0.mac_rx_data;
  wire         eth0_mac_rx_eop = u_dut.u_webserver.i_eth0.mac_rx_eop;
  wire         eth0_mac_tx_sop = u_dut.u_webserver.i_eth0.mac_tx_sop;
  wire         eth0_mac_tx_en = u_dut.u_webserver.i_eth0.mac_tx_en;
  wire  [ 7:0] eth0_mac_tx_data = u_dut.u_webserver.i_eth0.mac_tx_data;
  wire         eth0_mac_tx_eop = u_dut.u_webserver.i_eth0.mac_tx_eop;

  // CPU-side signals
  wire         cpu_req = u_dut.u_webserver.cpu_req;
  wire         cpu_ack = u_dut.u_webserver.cpu_ack;
  wire  [31:0] cpu_address = u_dut.u_webserver.cpu_address;

  // RISC-V program RAM interface
  wire         pram_wr = u_dut.u_webserver.pram_wr;
  wire  [12:0] pram_addr = u_dut.u_webserver.pram_addr;
  wire  [31:0] pram_wdata = u_dut.u_webserver.pram_wdata;

  //-------------------------------------------------------------------
  // Ethernet CRC32 (uses simple byte array, no queue indexing)
  //-------------------------------------------------------------------
  logic [31:0] eth_crc32_result;

  //-------------------------------------------------------------------
  // 50 MHz clock (period = 20 ns)
  //-------------------------------------------------------------------
  initial clk_50m_in = 1'b0;
  always #10 clk_50m_in = ~clk_50m_in;

  //-------------------------------------------------------------------
  // RGMII RX clock (125 MHz, period = 8 ns)
  //-------------------------------------------------------------------
  initial rgmii_rxc = 1'b0;
  always #4 rgmii_rxc = ~rgmii_rxc;

  //-------------------------------------------------------------------
  // Packet capture in GMII TX domain
  //-------------------------------------------------------------------
  byte unsigned dut_tx_capture        [$];
  byte unsigned dut_tx_last_frame     [$];
  int unsigned  dut_tx_frame_count;
  bit           dut_tx_capture_active;

  //-------------------------------------------------------------------
  // Main simulation sequence
  //-------------------------------------------------------------------
  initial begin
    $dumpfile("xilinx_xc7a35tfgg484_webserver_top_iverilog.vcd");
    $dumpvars(0, tb_xilinx_top);

    $display("============================================================");
    $display(" tb_xilinx_top — iverilog simulation");
    $display(" DUT: xilinx_xc7a35tfgg484_webserver_top");
    $display(" sim_mod = 1 (PLL bypass + lcpu_bfm)");
    $display(" device_vendor forced to \"xilinx\" (via defparam)");
    $display("============================================================");
    $display("");

    // Initialize
    reset_l               = 1'b0;
    rgmii_rx_ctl          = 1'b0;
    rgmii_rxd             = 4'h0;
    dut_tx_frame_count    = 0;
    dut_tx_capture_active = 1'b0;

    // Hold reset for ~200 ns (10 cycles @ 50MHz)
    repeat (10) @(posedge clk_50m_in);
    reset_l = 1'b1;
    $display("[%0t ns] Reset released", $time);

    // Wait for initialization (~1us for firmware to start booting)
    #1000;
    $display("[%0t ns] Init delay complete", $time);

    // Wait for firmware boot + init
    #START_DELAY_NS;
    $display("[%0t ns] Sending ARP request packet...", $time);

    // Build and send ARP request
    begin
      byte unsigned frame[$];
      build_arp_request(frame);
      rgmii_send_frame(frame);
      $display("[%0t ns] ARP request sent (%0d bytes)", $time, frame.size());
    end

    // Wait for response(s) or timeout
    #(SIM_TIMEOUT_NS - START_DELAY_NS);
    $display("[%0t ns] Simulation complete — %0d TX frames captured", $time, dut_tx_frame_count);
    $finish;
  end

  //-------------------------------------------------------------------
  // Capture DUT GMII TX frames (125 MHz = 50 MHz in bypass mode)
  //-------------------------------------------------------------------
  always @(posedge clk_50m_in) begin
    if (eth0_mac_tx_sop) begin
      dut_tx_capture.delete();
      dut_tx_capture_active = 1'b1;
    end

    if (dut_tx_capture_active && eth0_mac_tx_en) begin
      dut_tx_capture.push_back(eth0_mac_tx_data);
    end

    if (dut_tx_capture_active && eth0_mac_tx_eop) begin
      dut_tx_last_frame = dut_tx_capture;
      dut_tx_frame_count = dut_tx_frame_count + 1;
      dut_tx_capture_active = 1'b0;
      $display("[%0t ns] DUT TX frame #%0d: %0d bytes", $time, dut_tx_frame_count,
               dut_tx_last_frame.size());
    end
  end

  //-------------------------------------------------------------------
  // Event monitors
  //-------------------------------------------------------------------
  always @(posedge eth0_mac_tx_sop) begin
    $display("[%0t ns] eth0_mac_tx_sop", $time);
  end

  always @(posedge eth0_mac_tx_eop) begin
    $display("[%0t ns] eth0_mac_tx_eop", $time);
  end

  always @(posedge cpu_req) begin
    $display("[%0t ns] cpu_req addr=0x%08h rhwl=%b", $time, cpu_address,
             u_dut.u_webserver.cpu_rhwl);
  end
endmodule
