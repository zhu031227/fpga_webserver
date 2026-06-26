//-------------------------------------------------------------------
// tb_webserver.sv — iverilog simulation of xilinx top
//
// Uses force/release to inject GMII data directly into the DUT,
// bypassing the behavioral RGMII→GMII conversion which has inherent
// DDR→SDR nibble-alignment issues in zero-delay simulation.
//-------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_webserver;

  //-------------------------------------------------------------------
  // Clocks
  //-------------------------------------------------------------------
  reg       clk_50m_in;      // 50 MHz main
  reg       rgmii_rxc;       // RGMII RX clock (unused for stimulus, kept for DUT)
  reg       reset_l;

  //-------------------------------------------------------------------
  // RGMII RX stimulus signals (tied off — we use GMII force injection)
  //-------------------------------------------------------------------
  reg       rgmii_rx_ctl;
  reg [3:0] rgmii_rxd;

  //-------------------------------------------------------------------
  // DUT outputs
  //-------------------------------------------------------------------
  wire       uart_tx;
  wire       eth0_mdc;
  wire       eth0_mdio;
  wire       rgmii_reset_l;
  wire       rgmii_txc;
  wire       rgmii_tx_ctl;
  wire [3:0] rgmii_txd;
  wire [3:0] led;

  //-------------------------------------------------------------------
  // DUT — xilinx top (sim-local copy, no string params)
  //-------------------------------------------------------------------
  xilinx_xc7a35tfgg484_webserver_top #(
      .sim_mod    (1),
      .script_file("../tcl/InstructRAM.tcl")
  ) u_dut (
      .clk_50m_in (clk_50m_in),
      .reset_l    (reset_l),
      .uart_rx    (1'b1),
      .uart_tx    (uart_tx),
      .rgmii_reset_l (rgmii_reset_l),
      .rgmii_rxc     (rgmii_rxc),
      .rgmii_rx_ctl  (rgmii_rx_ctl),
      .rgmii_rxd     (rgmii_rxd),
      .rgmii_txc     (rgmii_txc),
      .rgmii_tx_ctl  (rgmii_tx_ctl),
      .rgmii_txd     (rgmii_txd),
      .eth0_mdc      (eth0_mdc),
      .eth0_mdio     (eth0_mdio),
      .led_o         (led)
  );

  //-------------------------------------------------------------------
  // Internal signal probes
  //-------------------------------------------------------------------
  wire        gmii_rx_dv  = u_dut.gmii_rx_dv;
  wire [7:0]  gmii_rxd_int = u_dut.gmii_rxd;
  wire        gmii_tx_en  = u_dut.gmii_tx_en;
  wire [7:0]  gmii_txd_int = u_dut.gmii_txd;

  // MAC-level
  wire        mac_rx_sop  = u_dut.u_webserver.eth0_mac_rx_sop;
  wire        mac_rx_en   = u_dut.u_webserver.eth0_mac_rx_en;
  wire [7:0]  mac_rx_data = u_dut.u_webserver.eth0_mac_rx_data;
  wire        mac_rx_eop  = u_dut.u_webserver.eth0_mac_rx_eop;
  wire        mac_tx_sop  = u_dut.u_webserver.eth0_mac_tx_sop;
  wire        mac_tx_en   = u_dut.u_webserver.eth0_mac_tx_en;
  wire [7:0]  mac_tx_data = u_dut.u_webserver.eth0_mac_tx_data;
  wire        mac_tx_eop  = u_dut.u_webserver.eth0_mac_tx_eop;

  // CPU
  wire        cpu_req  = u_dut.u_webserver.cpu_req;
  wire [31:0] cpu_addr = u_dut.u_webserver.cpu_address;
  wire        cpu_ack  = u_dut.u_webserver.cpu_ack;

  //-------------------------------------------------------------------
  // 50 MHz clock
  //-------------------------------------------------------------------
  initial clk_50m_in = 1'b0;
  always #10 clk_50m_in = ~clk_50m_in;

  // RGMII RX clock (tied to 50MHz, used by gmii2mac FIFO via behavioral stub)
  initial rgmii_rxc = 1'b0;
  always #10 rgmii_rxc = ~rgmii_rxc;

  //-------------------------------------------------------------------
  // GMII direct injection via force/release
  //
  // We force u_dut.gmii_rxd and u_dut.gmii_rx_dv to bypass the broken
  // behavioral RGMII→GMII conversion.  The gmii_rx_clk is already
  // driven to rgmii_rxc by the vendor stub (50MHz), which matches
  // clk_50m_in in sim_mod=1 PLL-bypass mode.
  //-------------------------------------------------------------------

  //-------------------------------------------------------------------
  // Send one byte on the forced GMII bus
  //-------------------------------------------------------------------
  task gmii_send_byte;
    input [7:0] data;
    input       dv;
    begin
      @(posedge clk_50m_in);
      force u_dut.gmii_rxd = data;
      force u_dut.gmii_rx_dv = dv;
    end
  endtask

  //-------------------------------------------------------------------
  // Send idle for N cycles
  //-------------------------------------------------------------------
  task gmii_send_idle;
    input integer cycles;
    integer i;
    begin
      for (i = 0; i < cycles; i = i + 1)
        gmii_send_byte(8'h00, 1'b0);
    end
  endtask

  //-------------------------------------------------------------------
  // Global packet buffer
  //-------------------------------------------------------------------
  reg [7:0] pkt[0:2047];
  integer   pkt_len;

  //-------------------------------------------------------------------
  // Send a complete Ethernet frame via forced GMII
  //-------------------------------------------------------------------
  task gmii_send_frame;
    integer i;
    integer n_bytes;
    reg [31:0] crc;
    reg [7:0]  b;
    reg        mix;
    integer    bi;
    begin
      n_bytes = pkt_len;

      // Inter-frame gap
      gmii_send_idle(12);

      // Preamble (7 bytes of 0x55)
      repeat (7) gmii_send_byte(8'h55, 1'b1);

      // SFD (0xD5)
      gmii_send_byte(8'hD5, 1'b1);

      // Frame data bytes
      for (i = 0; i < n_bytes; i = i + 1)
        gmii_send_byte(pkt[i], 1'b1);

      // Compute CRC32 over the frame
      crc = 32'hFFFF_FFFF;
      for (i = 0; i < n_bytes; i = i + 1) begin
        b = pkt[i];
        for (bi = 0; bi < 8; bi = bi + 1) begin
          mix = crc[0] ^ b[bi];
          crc = {1'b0, crc[31:1]};
          if (mix) crc = crc ^ 32'hEDB8_8320;
        end
      end
      crc = ~crc;

      // Send FCS bytes (LSB first on wire)
      gmii_send_byte(crc[7:0],   1'b1);
      gmii_send_byte(crc[15:8],  1'b1);
      gmii_send_byte(crc[23:16], 1'b1);
      gmii_send_byte(crc[31:24], 1'b1);

      // Return to idle and release GMII force
      gmii_send_byte(8'h00, 1'b0);
      release u_dut.gmii_rxd;
      release u_dut.gmii_rx_dv;
    end
  endtask

  //-------------------------------------------------------------------
  // Build ARP request into global pkt[]
  //-------------------------------------------------------------------
  task build_arp;
    begin
      // DST MAC (broadcast)
      pkt[0]  = 8'hFF; pkt[1]  = 8'hFF; pkt[2]  = 8'hFF;
      pkt[3]  = 8'hFF; pkt[4]  = 8'hFF; pkt[5]  = 8'hFF;
      // SRC MAC
      pkt[6]  = 8'h00; pkt[7]  = 8'h11; pkt[8]  = 8'h22;
      pkt[9]  = 8'h33; pkt[10] = 8'h44; pkt[11] = 8'h55;
      // EtherType = 0x0806 (ARP)
      pkt[12] = 8'h08; pkt[13] = 8'h06;
      // HTYPE = 1
      pkt[14] = 8'h00; pkt[15] = 8'h01;
      // PTYPE = 0x0800
      pkt[16] = 8'h08; pkt[17] = 8'h00;
      // HLEN = 6
      pkt[18] = 8'h06;
      // PLEN = 4
      pkt[19] = 8'h04;
      // OPER = 1 (request)
      pkt[20] = 8'h00; pkt[21] = 8'h01;
      // SHA (sender MAC)
      pkt[22] = 8'h00; pkt[23] = 8'h11; pkt[24] = 8'h22;
      pkt[25] = 8'h33; pkt[26] = 8'h44; pkt[27] = 8'h55;
      // SPA = 169.254.1.1 = A9FE0101
      pkt[28] = 8'hA9; pkt[29] = 8'hFE;
      pkt[30] = 8'h01; pkt[31] = 8'h01;
      // THA (target MAC — unknown)
      pkt[32] = 8'h00; pkt[33] = 8'h00; pkt[34] = 8'h00;
      pkt[35] = 8'h00; pkt[36] = 8'h00; pkt[37] = 8'h00;
      // TPA = 169.254.15.88 = A9FE0F58
      pkt[38] = 8'hA9; pkt[39] = 8'hFE;
      pkt[40] = 8'h0F; pkt[41] = 8'h58;

      pkt_len = 42;
    end
  endtask

  //-------------------------------------------------------------------
  // Simulation body
  //-------------------------------------------------------------------
  initial begin
    $dumpfile("xilinx_xc7a35tfgg484_webserver_top_iverilog.vcd");
    $dumpvars(1, u_dut);

    $display("============================================================");
    $display(" tb_webserver — xilinx top with GMII force injection");
    $display("============================================================");

    // Init
    reset_l      = 1'b0;
    rgmii_rx_ctl = 1'b0;
    rgmii_rxd    = 4'h0;

    // Hold reset 200ns
    repeat (10) @(posedge clk_50m_in);
    reset_l = 1'b1;
    $display("[%0t ns] Reset released", $time);

    // Wait for DUT init
    #5000;
    $display("[%0t ns] Sending ARP request...", $time);

    // Build and send ARP via forced GMII
    build_arp();
    gmii_send_frame();

    // Wait for firmware to process and respond
    #5000000;  // 5ms — gives firmware time to boot and process ARP
    $display("[%0t ns] Simulation complete", $time);
    $stop;
  end

  //-------------------------------------------------------------------
  // GMII RX monitor
  //-------------------------------------------------------------------
  reg [7:0] gmii_rx_prev;
  always @(posedge clk_50m_in) begin
    if (gmii_rx_dv && (gmii_rxd_int != gmii_rx_prev || gmii_rx_dv))
      $display("[%0t ns] GMII RX: data=0x%02h dv=%0d", $time, gmii_rxd_int, gmii_rx_dv);
    gmii_rx_prev <= gmii_rxd_int;
  end

  //-------------------------------------------------------------------
  // Packet receive monitor
  //-------------------------------------------------------------------
  integer rx_byte_count;
  reg [7:0] rx_bytes[0:2047];
  reg       rx_active;

  always @(posedge clk_50m_in) begin
    if (u_dut.u_webserver.eth0_mac_rx_sop) begin
      rx_byte_count <= 0;
      rx_active <= 1'b1;
      $display("[%0t ns] MAC RX SOP", $time);
    end
    if (rx_active && u_dut.u_webserver.eth0_mac_rx_en) begin
      rx_bytes[rx_byte_count] <= u_dut.u_webserver.eth0_mac_rx_data;
      rx_byte_count <= rx_byte_count + 1;
    end
    if (rx_active && u_dut.u_webserver.eth0_mac_rx_eop) begin
      rx_active <= 1'b0;
      $display("[%0t ns] MAC RX EOP (len=%0d)", $time, rx_byte_count);
    end
  end

  //-------------------------------------------------------------------
  // TX monitor
  //-------------------------------------------------------------------
  always @(posedge clk_50m_in) begin
    if (u_dut.u_webserver.eth0_mac_tx_sop)
      $display("[%0t ns] MAC TX SOP", $time);
    if (u_dut.u_webserver.eth0_mac_tx_eop)
      $display("[%0t ns] MAC TX EOP", $time);
  end

  //-------------------------------------------------------------------
  // CPU activity monitor
  //-------------------------------------------------------------------
  always @(posedge clk_50m_in) begin
    if (cpu_req)
      $display("[%0t ns] CPU REQ addr=0x%08h", $time, cpu_addr);
    if (cpu_ack)
      $display("[%0t ns] CPU ACK", $time);
  end

endmodule
