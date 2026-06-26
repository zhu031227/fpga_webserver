//-------------------------------------------------------------------
// tb_webserver.cpp — Verilator C++ testbench
//
// Drives clocks continuously, sets RGMII data at scheduled times.
//-------------------------------------------------------------------
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vxilinx_xc7a35tfgg484_webserver_top.h"
#include "Vxilinx_xc7a35tfgg484_webserver_top___024root.h"

#define TRACE_ON 1

// Internal signal access via rootp (enabled by --public-depth 2)
#define MAC_RXSOP top->rootp->xilinx_xc7a35tfgg484_webserver_top__DOT__u_webserver__DOT__eth0_mac_rx_sop
#define MAC_RXEN  top->rootp->xilinx_xc7a35tfgg484_webserver_top__DOT__u_webserver__DOT__eth0_mac_rx_en
#define MAC_RXDAT top->rootp->xilinx_xc7a35tfgg484_webserver_top__DOT__u_webserver__DOT__eth0_mac_rx_data
#define MAC_RXEOP top->rootp->xilinx_xc7a35tfgg484_webserver_top__DOT__u_webserver__DOT__eth0_mac_rx_eop
#define MAC_TXSOP top->rootp->xilinx_xc7a35tfgg484_webserver_top__DOT__u_webserver__DOT__eth0_mac_tx_sop
#define MAC_TXEN  top->rootp->xilinx_xc7a35tfgg484_webserver_top__DOT__u_webserver__DOT__eth0_mac_tx_en
#define MAC_TXDAT top->rootp->xilinx_xc7a35tfgg484_webserver_top__DOT__u_webserver__DOT__eth0_mac_tx_data
#define MAC_TXEOP top->rootp->xilinx_xc7a35tfgg484_webserver_top__DOT__u_webserver__DOT__eth0_mac_tx_eop
#define CPU_REQ   top->rootp->xilinx_xc7a35tfgg484_webserver_top__DOT__u_webserver__DOT__cpu_req
#define CPU_ADDR  top->rootp->xilinx_xc7a35tfgg484_webserver_top__DOT__u_webserver__DOT__cpu_address

//-------------------------------------------------------------------
// CRC32
//-------------------------------------------------------------------
static uint32_t crc32(const uint8_t* buf, int len) {
  uint32_t crc = 0xFFFFFFFF;
  for (int i = 0; i < len; i++) {
    crc ^= buf[i];
    for (int b = 0; b < 8; b++) {
      if (crc & 1) crc = (crc >> 1) ^ 0xEDB88320;
      else         crc >>= 1;
    }
  }
  return ~crc;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  Vxilinx_xc7a35tfgg484_webserver_top* top =
    new Vxilinx_xc7a35tfgg484_webserver_top;

#if TRACE_ON
  VerilatedVcdC* tfp = new VerilatedVcdC;
  Verilated::traceEverOn(true);
  top->trace(tfp, 1);
  tfp->open("xilinx_xc7a35tfgg484_webserver_top_verilator.vcd");
#endif

  //-------------------------------------------------------------------
  // Build ARP request frame
  //-------------------------------------------------------------------
  uint8_t pkt[64];
  int pkt_len = 42;
  for (int i = 0; i < 6; i++) pkt[i] = 0xFF;   // DST MAC broadcast
  pkt[6]=0x00; pkt[7]=0x11; pkt[8]=0x22; pkt[9]=0x33; pkt[10]=0x44; pkt[11]=0x55; // SRC MAC
  pkt[12]=0x08; pkt[13]=0x06;   // EtherType ARP
  pkt[14]=0x00; pkt[15]=0x01;   // HTYPE=1
  pkt[16]=0x08; pkt[17]=0x00;   // PTYPE=0x0800
  pkt[18]=0x06; pkt[19]=0x04;   // HLEN=6, PLEN=4
  pkt[20]=0x00; pkt[21]=0x01;   // OPER=1
  for (int i=0;i<6;i++) pkt[22+i]=pkt[6+i]; // SHA = SRC MAC
  pkt[28]=0xA9; pkt[29]=0xFE; pkt[30]=0x01; pkt[31]=0x01; // SPA 169.254.1.1
  for (int i=0;i<6;i++) pkt[32+i]=0x00;   // THA
  pkt[38]=0xC0; pkt[39]=0xA8; pkt[40]=0x01; pkt[41]=0x58; // TPA 192.168.1.88 (matches Local_IP_ADDR)

  uint32_t fcs = crc32(pkt, pkt_len);

  // Build the complete RGMII nibble sequence for each half-cycle.
  // Clock starts at 0. First RGMII edge is posedge (clk 0→1).
  // RGMII: posedge→low nibble+dv, negedge→high nibble+(dv^er)
  //
  // Nibble timeline: [posedge=low, negedge=high, posedge=low, ...]
  // We'll index with half_cycle; half_cycle 0 = clk=0 = initial state
  // First drive happens at half_cycle 1 (posedge).
  struct Nibble {
    uint8_t val, ctl;
  };
  Nibble nibble_seq[8192];
  int n_total = 0;

  auto add_byte = [&](uint8_t d, bool dv, bool er) {
    nibble_seq[n_total++] = { (uint8_t)(d & 0xF),       (uint8_t)(dv ? 1 : 0) };
    nibble_seq[n_total++] = { (uint8_t)((d >> 4) & 0xF), (uint8_t)((dv ^ er) ? 1 : 0) };
  };

  // Inter-frame gap
  for (int i = 0; i < 12; i++) add_byte(0x00, false, false);
  // Preamble (7 bytes 0x55)
  for (int i = 0; i < 7; i++) add_byte(0x55, true, false);
  // SFD
  add_byte(0xD5, true, false);
  // Data
  for (int i = 0; i < pkt_len; i++) add_byte(pkt[i], true, false);
  // FCS (LSB first)
  add_byte((uint8_t)(fcs & 0xFF), true, false);
  add_byte((uint8_t)((fcs >> 8) & 0xFF), true, false);
  add_byte((uint8_t)((fcs >> 16) & 0xFF), true, false);
  add_byte((uint8_t)((fcs >> 24) & 0xFF), true, false);
  // Trailing idle
  for (int i = 0; i < 2; i++) add_byte(0x00, false, false);

  // Prepend a dummy nibble so that nibble_seq[hc] maps directly to half_cycle.
  // half_cycle 0=clk=0 (no drive, initial state)
  // half_cycle 1=posedge → nibble_seq[1] = first LOW nibble
  // half_cycle 2=negedge → nibble_seq[2] = first HIGH nibble
  for (int i = n_total; i >= 0; i--)
    nibble_seq[i + 1] = nibble_seq[i];
  nibble_seq[0] = { 0, 0 };  // dummy for half_cycle=0
  n_total++;

  //-------------------------------------------------------------------
  // Simulation phases (time-driven)
  //   Phase 0: reset (0 .. 250us) — holds CPU in reset while BFM loads firmware
  //   Phase 1: boot wait (250us .. 300us) — CPU starts executing firmware
  //   Phase 2: send frame (starting at 300us, after firmware is loaded)
  //   Phase 3: monitor (after frame .. 7ms)
  //-------------------------------------------------------------------
  vluint64_t sim_ns = 0;
  bool frame_sent = false;
  bool rx_sop = false;
  int  rx_ctr = 0;

  int  half_cycle = 0;  // count of half-cycles (10ns steps)
  int  frame_start_hc = 300'000 / 10;  // start at 300us (after firmware loads at ~186us)

  #define END_HC (7'000'000LL / 10)

  while (half_cycle < END_HC) {
    bool clk = half_cycle & 1;  // toggles each half-cycle
    sim_ns = half_cycle * 10LL;

    bool sending = (half_cycle >= frame_start_hc &&
                    half_cycle < frame_start_hc + n_total);

    // --- Phase 0: Reset ---
    if (half_cycle < 20) {  // 200ns
      top->reset_l = 0;
      top->rgmii_rxd = 0;
      top->rgmii_rx_ctl = 0;
    }
    // --- Phase 1: Boot wait ---
    else if (!sending || half_cycle < frame_start_hc) {
      top->reset_l = 1;
      top->rgmii_rxd = 0;
      top->rgmii_rx_ctl = 0;
    }
    // --- Phase 2: Send frame ---
    if (sending) {
      top->reset_l = 1;
      if (!frame_sent) {
        printf("[%lu ns] Starting frame transmission\n", sim_ns);
        frame_sent = true;
      }
      // nibble_seq[half_cycle - frame_start_hc] maps directly
      int ni = half_cycle - frame_start_hc;
      top->rgmii_rxd = nibble_seq[ni].val;
      top->rgmii_rx_ctl = nibble_seq[ni].ctl;
    }

    // Update clocks
    top->clk_50m_in = clk ? 1 : 0;
    top->rgmii_rxc = clk ? 1 : 0;

    // Advance Verilator timing context (10ns = 10,000ps per half-cycle)
    Verilated::timeInc(10000);

    // Evaluate DUT
    top->eval();

    // Monitor MAC/CPU signals (only on posedge to avoid double-counting)
    // The DUT updates registers on posedge (odd half_cycles where clk==1).
    // Sampling on both half-cycles would count each byte twice.
    if (clk && MAC_RXSOP && !rx_sop) {
      rx_sop = true;
      rx_ctr = 0;
      printf("[%lu ns] MAC RX SOP\n", sim_ns);
    }
    if (clk && rx_sop && MAC_RXEN) {
      rx_ctr++;
      printf("[%lu ns]   MAC RX byte[%d] = 0x%02x\n", sim_ns, rx_ctr,
             (uint8_t)MAC_RXDAT);
    }
    if (clk && rx_sop && MAC_RXEOP) {
      rx_sop = false;
      printf("[%lu ns] MAC RX EOP (len=%d)\n", sim_ns, rx_ctr);
    }
    if (clk && MAC_TXSOP)
      printf("[%lu ns] MAC TX SOP\n", sim_ns);
    if (clk && MAC_TXSOP && MAC_TXEN)
      printf("[%lu ns]   MAC TX byte = 0x%02x\n", sim_ns, (uint8_t)MAC_TXDAT);
    if (clk && MAC_TXEOP)
      printf("[%lu ns] MAC TX EOP\n", sim_ns);

    static bool last_cpu = false;
    if (clk && CPU_REQ && !last_cpu)
      printf("[%lu ns] CPU REQ addr=0x%08x\n", sim_ns, (uint32_t)CPU_ADDR);
    last_cpu = CPU_REQ;

#if TRACE_ON
    if ((half_cycle % 2) == 0) tfp->dump(sim_ns * 1000);  // every 20ns, ns→ps
#endif

    half_cycle++;

    // Progress
    if ((half_cycle & 0xFFFF) == 0)
      printf("[%lu ms] sim running...\n", (unsigned long)(sim_ns / 1'000'000LL));
  }

  printf("[%lu ns] Simulation complete\n", sim_ns);

#if TRACE_ON
  tfp->close();
  delete tfp;
#endif
  top->final();
  delete top;
  return 0;
}
