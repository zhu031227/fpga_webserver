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
  integer    p;

  // ---- HTTP / TCP test globals ----
  reg  [7:0] fbuf   [0:2047];
  reg  [7:0] pload  [0:2047];
  reg  [7:0] rbuf   [0:2047];
  reg  [7:0] tx_q   [0:2047];
  reg  [7:0] tx_last[0:2047];
  integer    flen, plen, rlen;
  integer    tx_len, tx_last_len, tx_cnt;
  reg        tx_active;
  localparam [47:0] MY_MAC  = 48'h00_11_22_33_44_55;
  localparam [47:0] DUT_MAC = 48'h00_00_01_02_04_05;
  localparam [31:0] MY_IP   = 32'hC0_A8_01_01;
  localparam [31:0] DUT_IP  = 32'hC0_A8_01_58;
  localparam [15:0] TCP_SP  = 16'd1234;
  localparam [15:0] TCP_DP  = 16'd80;
  localparam [31:0] TCP_SEQ = 32'd1;

  // DUT
  xilinx_xc7a35tfgg484_webserver_top #(
      .sim_mod    (1),
      .script_file("InstructRAM_local.tcl")
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

  // ---- Send frame from fbuf[] (same RGMII encoding) ----
  task send_fbuf_frame;
    input integer len;
    integer total, pad, j, bi;
    reg [31:0] crc;
    reg [7:0]  b;
    reg        mix;
    begin
      pad = (len < 60) ? (60 - len) : 0;
      total = len + pad;
      crc = 32'hFFFF_FFFF;
      for (i = 0; i < len; i = i + 1) begin
        b = fbuf[i];
        for (bi = 0; bi < 8; bi = bi + 1) begin
          mix = crc[0] ^ b[bi];
          crc = {1'b0, crc[31:1]};
          if (mix) crc = crc ^ 32'hEDB8_8320;
        end
      end
      crc = ~crc;
      rgmii_send_idle(12);
      repeat (7) rgmii_send_byte(8'h55, 1'b1);
      rgmii_send_byte(8'hD5, 1'b1);
      for (i = 0; i < len; i = i + 1) rgmii_send_byte(fbuf[i], 1'b1);
      for (j = 0; j < pad; j = j + 1) rgmii_send_byte(8'h00, 1'b1);
      rgmii_send_byte(crc[7:0], 1'b1);  rgmii_send_byte(crc[15:8], 1'b1);
      rgmii_send_byte(crc[23:16], 1'b1); rgmii_send_byte(crc[31:24], 1'b1);
      rgmii_send_idle(2);
    end
  endtask

  // ---- Build TCP/IP/Ethernet frame in fbuf[] ----
  task tcp_pkt;
    input [15:0] sp, dp;
    input [31:0] sq, ak;
    input [7:0]  fl;
    input [31:0] pay_len;
    integer p, is, ts, ii;
    reg [31:0] sum;
    reg [15:0] tl;
    begin
      p = 0;
      fbuf[0]=DUT_MAC[47:40]; fbuf[1]=DUT_MAC[39:32]; fbuf[2]=DUT_MAC[31:24];
      fbuf[3]=DUT_MAC[23:16]; fbuf[4]=DUT_MAC[15:8];  fbuf[5]=DUT_MAC[7:0];  p=6;
      fbuf[6]=MY_MAC[47:40];  fbuf[7]=MY_MAC[39:32];  fbuf[8]=MY_MAC[31:24];
      fbuf[9]=MY_MAC[23:16];  fbuf[10]=MY_MAC[15:8];  fbuf[11]=MY_MAC[7:0]; p=12;
      fbuf[12]=8'h08; fbuf[13]=8'h00;  p = 14;  is = p;
      // IP total len = 20(IP) + 20(TCP) + payload
      tl = 40 + pay_len;
      fbuf[14]=8'h45; fbuf[15]=0; fbuf[16]=tl[15:8]; fbuf[17]=tl[7:0]; p=18;
      fbuf[18]=8'h56; fbuf[19]=8'h78; p=20;
      fbuf[20]=8'h40; fbuf[21]=0; p=22;
      fbuf[22]=8'h40; fbuf[23]=6;  p=24;
      fbuf[24]=0; fbuf[25]=0; p=26;
      fbuf[26]=MY_IP[31:24];  fbuf[27]=MY_IP[23:16];
      fbuf[28]=MY_IP[15:8];   fbuf[29]=MY_IP[7:0];  p=30;
      fbuf[30]=DUT_IP[31:24]; fbuf[31]=DUT_IP[23:16];
      fbuf[32]=DUT_IP[15:8];  fbuf[33]=DUT_IP[7:0]; p=34;
      // IP checksum
      sum = 0;
      for (ii = 0; ii < 20; ii = ii + 2) sum = sum + {fbuf[is+ii], fbuf[is+ii+1]};
      while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
      fbuf[is+10] = ~sum[15:8]; fbuf[is+11] = ~sum[7:0];
      // TCP header
      ts = p;
      fbuf[p]=sp[15:8]; fbuf[p+1]=sp[7:0]; p=p+2;
      fbuf[p]=dp[15:8]; fbuf[p+1]=dp[7:0]; p=p+2;
      fbuf[p]=sq[31:24]; fbuf[p+1]=sq[23:16];
      fbuf[p+2]=sq[15:8]; fbuf[p+3]=sq[7:0]; p=p+4;
      fbuf[p]=ak[31:24]; fbuf[p+1]=ak[23:16];
      fbuf[p+2]=ak[15:8]; fbuf[p+3]=ak[7:0]; p=p+4;
      fbuf[p]=8'h50; fbuf[p+1]=fl; p=p+2;
      fbuf[p]=8'h40; fbuf[p+1]=0; p=p+2;
      fbuf[p]=0; fbuf[p+1]=0; p=p+2;
      fbuf[p]=0; fbuf[p+1]=0; p=p+2;
      for (ii = 0; ii < pay_len; ii = ii + 1) fbuf[p+ii] = pload[ii];
      p = p + pay_len;
      // TCP checksum
      sum = 0;
      for (ii = 0; ii < 4; ii = ii + 1) sum = sum + {MY_IP[8*ii+:8], MY_IP[8*ii+8+:8]};
      for (ii = 0; ii < 4; ii = ii + 1) sum = sum + {DUT_IP[8*ii+:8], DUT_IP[8*ii+8+:8]};
      sum = sum + 32'd6 + (20 + pay_len);
      for (ii = 0; ii < 20 + pay_len; ii = ii + 2) sum = sum + {fbuf[ts+ii], fbuf[ts+ii+1]};
      while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
      fbuf[ts+16] = ~sum[15:8]; fbuf[ts+17] = ~sum[7:0];
      flen = p;
    end
  endtask

  // ---- DUT TX frame capture (125 MHz) ----
  always @(posedge u_dut.u_webserver.clk_125mhz) begin : tx_capture
    integer ci;
    if (u_dut.u_webserver.eth0_mac_tx_sop) begin
      $display("[%0t] TX_CAP SOP", $time);
      tx_active <= 1;
      if (u_dut.u_webserver.eth0_mac_tx_en) begin
        tx_q[0] <= u_dut.u_webserver.eth0_mac_tx_data;
        tx_len  <= 1;
      end else begin
        tx_len <= 0;
      end
    end else if (tx_active && u_dut.u_webserver.eth0_mac_tx_en) begin
      tx_q[tx_len] <= u_dut.u_webserver.eth0_mac_tx_data;
      tx_len       <= tx_len + 1;
    end
    if (tx_active && u_dut.u_webserver.eth0_mac_tx_eop) begin
      // When EN coincides with EOP, the byte was just captured in the
      // block above but tx_len hasn't been incremented yet (NBA).
      integer clen;
      clen = u_dut.u_webserver.eth0_mac_tx_en ? (tx_len + 1) : tx_len;
      for (ci = 0; ci < clen; ci = ci + 1) tx_last[ci] <= tx_q[ci];
      tx_last_len <= clen;
      tx_cnt      <= tx_cnt + 1;
      tx_active   <= 0;
    end
  end

  // ---- Wait for DUT TX frame ----
  task wait_frm;
    input time tmo_ns;
    integer sc, cnt, ci;
    begin
      sc = tx_cnt;  cnt = 0;
      while (tx_cnt == sc && cnt < tmo_ns / 8) begin
        @(posedge u_dut.u_webserver.clk_125mhz);
        cnt = cnt + 1;
      end
      if (tx_cnt > sc) begin
        for (ci = 0; ci < tx_last_len; ci = ci + 1) rbuf[ci] = tx_last[ci];
        rlen = tx_last_len;
      end else rlen = 0;
    end
  endtask

  // ---- Parse SYN+ACK ----
  task parse_synack;
    output reg [31:0] sseq;
    output reg        ok;
    integer ih;
    begin
      ok = 0;  sseq = 0;
      if (rlen >= 54 && {rbuf[12], rbuf[13]} == 16'h0800) begin
        ih = rbuf[14][3:0] * 4;
        if (ih >= 20 && rlen >= 14 + ih + 20) begin
          if (rbuf[14 + ih + 13] == 8'h12) begin
            sseq = {rbuf[14+ih+4], rbuf[14+ih+5], rbuf[14+ih+6], rbuf[14+ih+7]};
            ok = 1;
          end else
            $display("[%0t] TB: TCP flags=0x%02h (exp 0x12) rlen=%0d", $time, rbuf[14+ih+13], rlen);
        end
      end else begin
        $display("[%0t] TB: parse fail rlen=%0d ET=%02x%02x", $time, rlen, rbuf[12], rbuf[13]);
        for (i = 0; i < 16; i = i + 1) $write("%02x ", rbuf[i]); $display;
      end
    end
  endtask

  // ---- HTTP GET test ----
  task tcp_http;
    reg [31:0] cseq, sseq;
    reg        tok;
    integer    ii, ri, sc;
    reg [7:0]  get_req [0:53];
    begin
      get_req[0]=71; get_req[1]=69; get_req[2]=84; get_req[3]=32; get_req[4]=47; get_req[5]=32;
      get_req[6]=72; get_req[7]=84; get_req[8]=84; get_req[9]=80; get_req[10]=47; get_req[11]=49;
      get_req[12]=46; get_req[13]=49; get_req[14]=13; get_req[15]=10; get_req[16]=72; get_req[17]=111;
      get_req[18]=115; get_req[19]=116; get_req[20]=58; get_req[21]=32; get_req[22]=102; get_req[23]=112;
      get_req[24]=103; get_req[25]=97; get_req[26]=13; get_req[27]=10; get_req[28]=67; get_req[29]=111;
      get_req[30]=110; get_req[31]=110; get_req[32]=101; get_req[33]=99; get_req[34]=116; get_req[35]=105;
      get_req[36]=111; get_req[37]=110; get_req[38]=58; get_req[39]=32; get_req[40]=107; get_req[41]=101;
      get_req[42]=101; get_req[43]=112; get_req[44]=45; get_req[45]=97; get_req[46]=108; get_req[47]=105;
      get_req[48]=118; get_req[49]=101; get_req[50]=13; get_req[51]=10; get_req[52]=13; get_req[53]=10;

      $display("[%0t] === HTTP GET ===", $time);
      cseq = TCP_SEQ;
      tcp_pkt(TCP_SP, TCP_DP, cseq, 0, 8'h02, 0);
      send_fbuf_frame(flen);
      cseq = cseq + 1;
      wait_frm(1_500_000);
      parse_synack(sseq, tok);
      $display("[%0t] TB: <- SYN/ACK seq=%0d ok=%0d", $time, sseq, tok);
      if (tok) begin
        tcp_pkt(TCP_SP, TCP_DP, cseq, sseq + 1, 8'h10, 0);
        send_fbuf_frame(flen);
        for (ii = 0; ii < 54; ii = ii + 1) pload[ii] = get_req[ii];
        plen = 54;
        tcp_pkt(TCP_SP, TCP_DP, cseq, sseq + 1, 8'h18, plen);
        send_fbuf_frame(flen);
        cseq = cseq + plen;
        for (ri = 0; ri < 8; ri = ri + 1) begin : rloop
          sc = tx_cnt;
          wait_frm(2_000_000);
          if (tx_cnt > sc) begin
            $display("[%0t] TB: HTTP resp len=%0d", $time, rlen);
            disable rloop;
          end
        end
      end else $display("[%0t] TB: WARN no SYN+ACK, skipping GET", $time);
    end
  endtask

  // Monitor PicoRV32 mem_addr vs bridge output address
  wire [31:0] dbg_rv_addr = u_dut.u_webserver.u_cpu_subsystem.riscv_cpu_generation.u_riscv_cpu.u_RiscV32_LocalBus.u_RiscV32IntfBridge.rv_addr;
  wire        dbg_rv_valid  = u_dut.u_webserver.u_cpu_subsystem.riscv_cpu_generation.u_riscv_cpu.u_RiscV32_LocalBus.u_RiscV32IntfBridge.rv_valid;
  wire  [3:0] dbg_rv_wstrb  = u_dut.u_webserver.u_cpu_subsystem.riscv_cpu_generation.u_riscv_cpu.u_RiscV32_LocalBus.u_RiscV32IntfBridge.rv_wstrb;
  always @(posedge u_dut.u_webserver.clk_50mhz) begin
    if (dbg_rv_valid) begin
      if (dbg_rv_wstrb != 0)
        $display("[%0t] RV_WR: addr=0x%08h wstrb=%b", $time, dbg_rv_addr, dbg_rv_wstrb);
      else
        $display("[%0t] RV: addr=0x%08h", $time, dbg_rv_addr);
    end
  end

  // ---- riscv_reg BSS monitor (internal path for addresses < 0x80000000) ----
  wire        dbg_rreg_req;
  wire        dbg_rreg_rhwl;
  wire [31:0] dbg_rreg_addr;
  wire [31:0] dbg_rreg_wdata;
  wire [31:0] dbg_rreg_rdata;
  wire        dbg_rreg_ack;
  assign dbg_rreg_req   = u_dut.u_webserver.u_cpu_subsystem.riscv_cpu_generation.u_riscv_cpu.u_riscv_reg.req;
  assign dbg_rreg_rhwl  = u_dut.u_webserver.u_cpu_subsystem.riscv_cpu_generation.u_riscv_cpu.u_riscv_reg.rhwl;
  assign dbg_rreg_addr  = u_dut.u_webserver.u_cpu_subsystem.riscv_cpu_generation.u_riscv_cpu.u_riscv_reg.address;
  assign dbg_rreg_wdata = u_dut.u_webserver.u_cpu_subsystem.riscv_cpu_generation.u_riscv_cpu.u_riscv_reg.wdata;
  assign dbg_rreg_rdata = u_dut.u_webserver.u_cpu_subsystem.riscv_cpu_generation.u_riscv_cpu.u_riscv_reg.rdata;
  assign dbg_rreg_ack   = u_dut.u_webserver.u_cpu_subsystem.riscv_cpu_generation.u_riscv_cpu.u_riscv_reg.ack;

  // ---- riscv_reg ALL writes monitor ----
  always @(posedge u_dut.u_webserver.clk_50mhz) begin
    if (dbg_rreg_req && !dbg_rreg_rhwl)
      $display("[%0t] RREG_WR: addr=0x%08h data=0x%08h", $time, dbg_rreg_addr, dbg_rreg_wdata);
  end

  // Track BSS accesses at ack time (rdata is only valid then)
  reg [31:0] rreg_addr_cap;
  reg        rreg_is_read;
  always @(posedge u_dut.u_webserver.clk_50mhz) begin
    if (dbg_rreg_req && dbg_rreg_addr >= 32'h24C0 && dbg_rreg_addr <= 32'h2700) begin
      rreg_addr_cap <= dbg_rreg_addr;
      rreg_is_read  <= dbg_rreg_rhwl;
      if (!dbg_rreg_rhwl)
        $display("[%0t] RREG BSS WR: addr=0x%08h data=0x%08h", $time, dbg_rreg_addr, dbg_rreg_wdata);
    end
    if (dbg_rreg_ack && rreg_is_read)
      $display("[%0t] RREG BSS RD_DONE: addr=0x%08h data=0x%08h", $time, rreg_addr_cap, dbg_rreg_rdata);
  end

  // ---- TX FIFO byte-level monitor ----
  always @(posedge u_dut.u_webserver.clk_50mhz) begin
    if (u_dut.u_webserver.cpu_wr_wen_ind)
      $display("[%0t] TXFIFO WR: a=0x%04h d=0x%02h", $time,
               u_dut.u_webserver.cpu_wr_waddr, u_dut.u_webserver.cpu_wr_wdata);
    if (u_dut.u_webserver.cpu_wr_wpkt_push_ind)
      $display("[%0t] TXFIFO PUSH len=%0d", $time, u_dut.u_webserver.cpu_wr_wpkt_len);
  end

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

  // ---- ICMP Ping test ----
  task icmp_ping;
    reg [31:0] sum;
    reg [15:0] icmp_len;
    integer    ii, is, pi, icmp_ih;
    begin
      $display("[%0t] === ICMP Ping ===", $time);
      // ICMP payload: "ping test data 0123456789abcdef"
      pload[0]=112; pload[1]=105; pload[2]=110; pload[3]=103;
      pload[4]=32;  pload[5]=116; pload[6]=101; pload[7]=115;
      pload[8]=116; pload[9]=32;  pload[10]=100; pload[11]=97;
      pload[12]=116; pload[13]=97; pload[14]=32; pload[15]=48;
      pload[16]=49; pload[17]=50; pload[18]=51; pload[19]=52;
      pload[20]=53; pload[21]=54; pload[22]=55; pload[23]=56;
      pload[24]=57; pload[25]=97; pload[26]=98; pload[27]=99;
      pload[28]=100; pload[29]=101; pload[30]=102; pload[31]=103;
      plen = 32;

      // Build Ethernet + IP + ICMP frame in fbuf[]
      // ICMP header: type(1) + code(1) + checksum(2) + id(2) + seq(2) = 8 bytes
      icmp_len = 8 + plen;  // ICMP header + payload

      // Ethernet header
      p = 0;
      fbuf[0]=DUT_MAC[47:40]; fbuf[1]=DUT_MAC[39:32]; fbuf[2]=DUT_MAC[31:24];
      fbuf[3]=DUT_MAC[23:16]; fbuf[4]=DUT_MAC[15:8];  fbuf[5]=DUT_MAC[7:0];  p=6;
      fbuf[6]=MY_MAC[47:40];  fbuf[7]=MY_MAC[39:32];  fbuf[8]=MY_MAC[31:24];
      fbuf[9]=MY_MAC[23:16];  fbuf[10]=MY_MAC[15:8];  fbuf[11]=MY_MAC[7:0]; p=12;
      fbuf[12]=8'h08; fbuf[13]=8'h00;  p=14;  is=p;
      // IP: total len = 20(IP) + icmp_len
      fbuf[14]=8'h45; fbuf[15]=0;
      fbuf[16]=(20+icmp_len)>>8; fbuf[17]=(20+icmp_len)&8'hFF; p=18;
      fbuf[18]=8'h12; fbuf[19]=8'h34; p=20;  // ID
      fbuf[20]=8'h40; fbuf[21]=0; p=22;       // flags+frag
      fbuf[22]=8'h40; fbuf[23]=1;  p=24;       // TTL=64, Proto=ICMP
      fbuf[24]=0; fbuf[25]=0; p=26;             // checksum placeholder
      fbuf[26]=MY_IP[31:24];  fbuf[27]=MY_IP[23:16];
      fbuf[28]=MY_IP[15:8];   fbuf[29]=MY_IP[7:0];  p=30;
      fbuf[30]=DUT_IP[31:24]; fbuf[31]=DUT_IP[23:16];
      fbuf[32]=DUT_IP[15:8];  fbuf[33]=DUT_IP[7:0]; p=34;
      // IP checksum
      sum = 0;
      for (ii = 0; ii < 20; ii = ii + 2) sum = sum + {fbuf[is+ii], fbuf[is+ii+1]};
      while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
      fbuf[is+10] = ~sum[15:8]; fbuf[is+11] = ~sum[7:0];

      // ICMP header
      pi = p;
      fbuf[p]=8;  fbuf[p+1]=0;  p=p+2;  // type=8(EchoReq), code=0
      fbuf[p]=0;  fbuf[p+1]=0;  p=p+2;  // checksum placeholder
      fbuf[p]=8'h12; fbuf[p+1]=8'h34; p=p+2;  // ID=0x1234
      fbuf[p]=0;  fbuf[p+1]=1;  p=p+2;  // Seq=1
      // Payload
      for (ii = 0; ii < plen; ii = ii + 1) fbuf[p+ii] = pload[ii];
      p = p + plen;
      // ICMP checksum (over type+code+checksum+id+seq+payload)
      sum = 0;
      fbuf[pi+2] = 0; fbuf[pi+3] = 0;  // zero checksum for calc
      for (ii = 0; ii < icmp_len; ii = ii + 2) sum = sum + {fbuf[pi+ii], fbuf[pi+ii+1]};
      while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
      fbuf[pi+2] = ~sum[15:8]; fbuf[pi+3] = ~sum[7:0];
      flen = p;

      send_fbuf_frame(flen);
      $display("[%0t] ICMP Echo Request sent", $time);

      // Wait for ICMP Echo Reply
      wait_frm(3_000_000);
      if (rlen > 0) begin
        $display("[%0t] TB: ICMP reply len=%0d", $time, rlen);
        // Verify it's an ICMP Echo Reply (type=0)
        if (rlen >= 42 && {rbuf[12], rbuf[13]} == 16'h0800) begin
          reg [7:0] ip_ver_ihl;
          ip_ver_ihl = rbuf[14];
          icmp_ih = (ip_ver_ihl & 8'h0F) * 4;
          $display("[%0t] TB: ICMP debug: rbuf[14]=0x%02h ih=%0d", $time, ip_ver_ihl, icmp_ih);
          if (rlen >= 14 + icmp_ih + 8) begin
            $display("[%0t] TB: ICMP type=%0d code=%0d", $time, rbuf[14+icmp_ih], rbuf[14+icmp_ih+1]);
            if (rbuf[14+icmp_ih] == 0)
              $display("[%0t] TB: ICMP ping OK (Echo Reply received)", $time);
            else
              $display("[%0t] TB: ICMP ping FAIL (type=%0d)", $time, rbuf[14+icmp_ih]);
          end
        end
      end else begin
        $display("[%0t] TB: ICMP ping FAIL (no reply)", $time);
      end
    end
  endtask

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

    // ==== Phase 1: ARP ====
    tx_cnt    = 0;
    tx_active = 0;
    $display("[%0t] === Phase 1: ARP ===", $time);
    build_arp();
    send_frame();
    $display("[%0t] ARP frame sent", $time);
    #800000;
    $display("[%0t] ARP phase done", $time);

    // ==== Phase 2: ICMP Ping ====
    $display("[%0t] === Phase 2: ICMP Ping ===", $time);
    icmp_ping;
    #1000000;

    // ==== Phase 3: HTTP GET ====
    $display("[%0t] === Phase 3: HTTP GET ===", $time);
    tcp_http;

    // Run for additional time
    #2000000;
    $display("[%0t] === Simulation complete ===", $time);
    $finish;
  end

endmodule
