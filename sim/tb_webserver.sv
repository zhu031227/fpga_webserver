// tb_webserver — FPGA WebServer RGMII testbench
// Uses Xilinx top module with sim_mod=1 (PLL bypass, no vendor primitives)
//
// Packet stimulus types: ARP, ICMP, TCP
// Configurable via parameters

`timescale 1ns / 1ps
`include "define.sv"

module tb_webserver #(
    parameter PKT_ARP = 1,
    parameter PKT_ICMP = 2,
    parameter PKT_TCP = 3,
    parameter PKT_UDP = 4,

    parameter ETH_MIN_FRAME_WO_FCS = 60,

    parameter TCP_SYNACK_TIMEOUT_NS = 5_000_000,
    parameter TCP_HTTP_TIMEOUT_NS   = 10_000_000,
    parameter TCP_MAX_RESPONSE_FRAMES = 4,

    parameter ENABLE_PKT_STIM = 1,
    parameter PKT_TYPE = PKT_TCP,
    parameter START_DELAY_NS = 2_000_000,

    // Ethernet five-tuple
    parameter [47:0] SRC_MAC = 48'hAABB_CCDD_EEFF,
    parameter [47:0] DST_MAC = 48'h0000_0102_0405,

    // IP addresses (169.254.x.x link-local)
    parameter [31:0] SRC_IP = 32'hA9FE_0101,  // 169.254.1.1
    parameter [31:0] DST_IP = 32'hC0A8_0158,  // 192.168.1.88

    parameter [15:0] SRC_PORT = 1234,
    parameter [15:0] DST_PORT = 80,

    parameter [31:0] TCP_SEQ   = 32'h0000_0001,
    parameter [31:0] TCP_ACK   = 32'h0000_0000,
    parameter [7:0]  TCP_FLAGS = 8'h02  // SYN
)();

  // Clocks
  reg clk_50m = 0;
  reg clk_125m = 0;
  reg clk_200m = 0;
  always #10 clk_50m = ~clk_50m;     // 50 MHz
  always #4  clk_125m = ~clk_125m;   // 125 MHz
  always #2.5 clk_200m = ~clk_200m;  // 200 MHz

  // Reset
  reg reset_l = 0;

  // UART
  reg  uart_rx = 1;
  wire uart_tx;

  // RGMII signals
  wire       rgmii_reset_l;
  reg        rgmii_rxc = 0;
  reg        rgmii_rx_ctl = 0;
  reg  [3:0] rgmii_rxd = 0;
  wire       rgmii_txc;
  wire       rgmii_tx_ctl;
  wire [3:0] rgmii_txd;

  // MDIO
  wire Eth0_MDC;
  wire Eth0_MDIO;

  // LED
  wire [3:0] led_o;

  // 125 MHz RGMII RX clock (phase-shifted relative to clk_125m for DDR)
  always #4 rgmii_rxc = ~rgmii_rxc;

  // DUT
  xilinx_xc7a35tfgg484_webserver_top #(
      .sim_mod(1)
  ) u_dut (
      .clk_50m_in  (clk_50m),
      .reset_l     (reset_l),
      .uart_rx     (uart_rx),
      .uart_tx     (uart_tx),
      .rgmii_reset_l(rgmii_reset_l),
      .rgmii_rxc   (rgmii_rxc),
      .rgmii_rx_ctl(rgmii_rx_ctl),
      .rgmii_rxd   (rgmii_rxd),
      .rgmii_txc   (rgmii_txc),
      .rgmii_tx_ctl(rgmii_tx_ctl),
      .rgmii_txd   (rgmii_txd),
      .Eth0_MDC    (Eth0_MDC),
      .Eth0_MDIO   (Eth0_MDIO),
      .led_o       (led_o)
  );

  // --- Packet construction helpers ---
  typedef byte byte_q_t;

  function automatic void append_u16_be(ref byte_q_t q[$], input [15:0] v);
    q.push_back((v >> 8) & 8'hFF);
    q.push_back(v & 8'hFF);
  endfunction

  function automatic void append_u32_be(ref byte_q_t q[$], input [31:0] v);
    q.push_back((v >> 24) & 8'hFF);
    q.push_back((v >> 16) & 8'hFF);
    q.push_back((v >> 8) & 8'hFF);
    q.push_back(v & 8'hFF);
  endfunction

  function automatic void append_mac(ref byte_q_t q[$], input [47:0] mac);
    q.push_back((mac >> 40) & 8'hFF);
    q.push_back((mac >> 32) & 8'hFF);
    q.push_back((mac >> 24) & 8'hFF);
    q.push_back((mac >> 16) & 8'hFF);
    q.push_back((mac >> 8) & 8'hFF);
    q.push_back(mac & 8'hFF);
  endfunction

  // --- RGMII DDR receive driver ---
  task automatic rgmii_send_pkt(ref byte_q_t pkt[$]);
    int i;
    reg [7:0] byte_val;
    for (i = 0; i < pkt.size(); i++) begin
      byte_val = pkt[i];
      // DDR: send lower nibble on rising edge, upper nibble on falling edge
      @(posedge rgmii_rxc);
      rgmii_rx_ctl <= 1'b1;
      rgmii_rxd <= byte_val[3:0];
      @(negedge rgmii_rxc);
      rgmii_rxd <= byte_val[7:4];
    end
    @(posedge rgmii_rxc);
    rgmii_rx_ctl <= 1'b0;
    rgmii_rxd <= 4'b0;
  endtask

  // --- Main test sequence ---
  initial begin
    $display("========================================");
    $display(" FPGA WebServer Testbench");
    $display(" Packet Type : %0d", PKT_TYPE);
    $display("========================================");

    // Assert reset
    reset_l = 1'b0;
    repeat (100) @(posedge clk_50m);
    reset_l = 1'b1;
    $display("[%0t] Reset released", $time);

    // Wait for initialization delay
    #START_DELAY_NS;
    $display("[%0t] Starting packet stimulus", $time);

    if (ENABLE_PKT_STIM) begin
      case (PKT_TYPE)
        PKT_ARP:  test_arp();
        PKT_ICMP: test_icmp();
        PKT_TCP:  test_tcp_http();
        default:  $display("Unknown PKT_TYPE: %0d", PKT_TYPE);
      endcase
    end

    // Wait and finish
    repeat (10000) @(posedge clk_50m);
    $display("[%0t] Simulation finished", $time);
    $finish;
  end

  // --- ARP test ---
  task automatic test_arp();
    byte_q_t pkt[$];
    int i;
    $display("[%0t] Sending ARP request...", $time);

    // Build ARP request packet
    append_mac(pkt, DST_MAC);      // dst MAC
    append_mac(pkt, SRC_MAC);      // src MAC
    append_u16_be(pkt, 16'h0806);  // EtherType: ARP
    append_u16_be(pkt, 16'h0001);  // HTYPE: Ethernet
    append_u16_be(pkt, 16'h0800);  // PTYPE: IPv4
    pkt.push_back(8'h06);          // HLEN: 6
    pkt.push_back(8'h04);          // PLEN: 4
    append_u16_be(pkt, 16'h0001);  // Opcode: Request
    append_mac(pkt, SRC_MAC);      // Sender MAC
    append_u32_be(pkt, SRC_IP);    // Sender IP
    append_mac(pkt, 48'h0);        // Target MAC (zero)
    append_u32_be(pkt, DST_IP);    // Target IP

    // Pad to minimum frame size
    while (pkt.size() < ETH_MIN_FRAME_WO_FCS) pkt.push_back(8'h00);

    rgmii_send_pkt(pkt);
  endtask

  // --- ICMP ping test ---
  task automatic test_icmp();
    byte_q_t pkt[$];
    $display("[%0t] Sending ICMP Echo Request...", $time);

    append_mac(pkt, DST_MAC);
    append_mac(pkt, SRC_MAC);
    append_u16_be(pkt, 16'h0800);   // EtherType: IP

    // IP header (20 bytes)
    pkt.push_back(8'h45);            // Version=4, IHL=5
    pkt.push_back(8'h00);            // DSCP/ECN
    append_u16_be(pkt, 16'h0054);    // Total length: 84
    append_u16_be(pkt, 16'h0001);    // ID
    append_u16_be(pkt, 16'h0000);    // Flags/Fragment
    pkt.push_back(8'h40);            // TTL=64
    pkt.push_back(8'h01);            // Protocol: ICMP
    append_u16_be(pkt, 16'h0000);    // Checksum (zero for now)
    append_u32_be(pkt, SRC_IP);      // Src IP
    append_u32_be(pkt, DST_IP);      // Dst IP

    // ICMP Echo Request
    pkt.push_back(8'h08);            // Type: Echo Request
    pkt.push_back(8'h00);            // Code: 0
    append_u16_be(pkt, 16'h0000);    // Checksum (zero)
    append_u16_be(pkt, 16'h0001);    // ID
    append_u16_be(pkt, 16'h0001);    // Seq
    // Payload (56 bytes of 'A')
    for (int i = 0; i < 56; i++) pkt.push_back(8'h41);

    while (pkt.size() < ETH_MIN_FRAME_WO_FCS) pkt.push_back(8'h00);
    rgmii_send_pkt(pkt);
  endtask

  // --- TCP HTTP test ---
  task automatic test_tcp_http();
    byte_q_t pkt[$];
    $display("[%0t] Sending TCP SYN...", $time);

    // Build TCP SYN packet (simplified — full testbench would include checksums)
    append_mac(pkt, DST_MAC);
    append_mac(pkt, SRC_MAC);
    append_u16_be(pkt, 16'h0800);

    // IP header
    pkt.push_back(8'h45);
    pkt.push_back(8'h00);
    append_u16_be(pkt, 16'h0028);    // Total length: 40
    append_u16_be(pkt, 16'h0001);
    append_u16_be(pkt, 16'h0000);
    pkt.push_back(8'h40);
    pkt.push_back(8'h06);            // Protocol: TCP
    append_u16_be(pkt, 16'h0000);
    append_u32_be(pkt, SRC_IP);
    append_u32_be(pkt, DST_IP);

    // TCP header (SYN)
    append_u16_be(pkt, SRC_PORT);
    append_u16_be(pkt, DST_PORT);
    append_u32_be(pkt, TCP_SEQ);
    append_u32_be(pkt, TCP_ACK);
    pkt.push_back(8'h50);            // Data offset: 5
    pkt.push_back(TCP_FLAGS);        // SYN
    append_u16_be(pkt, 16'hFFFF);    // Window
    append_u16_be(pkt, 16'h0000);    // Checksum
    append_u16_be(pkt, 16'h0000);    // Urgent

    while (pkt.size() < ETH_MIN_FRAME_WO_FCS) pkt.push_back(8'h00);
    rgmii_send_pkt(pkt);

    // Wait for SYN-ACK
    $display("[%0t] Waiting for SYN-ACK...", $time);
    #TCP_SYNACK_TIMEOUT_NS;
    $display("[%0t] SYN-ACK timeout window ended", $time);
  endtask

endmodule
