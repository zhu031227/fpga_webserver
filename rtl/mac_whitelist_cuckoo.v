// mac_whitelist_cuckoo — BRAM cuckoo-hash MAC whitelist lookup engine
//
// MODE 2: Cuckoo hashing through two parallel BRAM banks
// - Two hash functions h0/h1 (XOR-fold of 48-bit MAC / byte-swapped MAC) give each
//   MAC exactly 2 candidate slots: bank0[row=h0(mac)] and bank1[row=h1(mac)].
// - Lookup reads both banks in parallel -> req→done = 2 cycles @125MHz = 16ns,
//   independent of table occupancy (vs mode0 18 / mode1 ~10-14).
// - Storage: 2 banks x 64 rows (BUCKET_NUM=64) = 128 physical slots
//   slot[6:0] = {bank, row[5:0]}  (0..63 = bank0, 64..127 = bank1)
//   Design capacity CAPACITY=96 = 75% load (eviction starts to fail above that).
// - Shadow storage = 128-deep register file (cfg_clk write, combinational read).
// - Insertion (incl. bounded eviction) is done in C firmware (c/whitelist.c);
//   RTL trusts invariant INV-A (each entry lives in one of its 2 hash slots).
//
// ============================================================================
// Software contracts (INV, mirrored from doc ED003R02-C 模式2 §1.2):
//   INV-A  every valid entry sits in slot {0,h0(mac)} or {1,h1(mac)}
//   INV-B  an entry in slot {bank,row} has h_bank(mac)==row (slot==its own hash bit)
//   INV-C  during an insert/delete transaction (<=8 hops x 4 subbus writes)
//          individual lookups may transiently miss; outside a transaction all hit.
//   RTL never recomputes hashes to verify INV-B — that is C's job + tb checker.
//   All-zero MAC forbidden (invalid entries read back 49'b0, never match).
//
// Hash definitions (RTL/C/tb must be bit-identical; single source in C wl_fold):
//   fold6(x[47:0]) = x[5:0]^x[11:6]^...^x[47:42]   (8 chunks of 6 bits, XOR)
//   h0(mac) = fold6(mac)
//   h1(mac) = fold6(byteswap48(mac))
//   C-side bit-exact copy: c/whitelist.c wl_fold()/wl_hash0_of()/wl_hash1_of()
//
// Parameters (doc 模式2 步骤1.2):
//   BUCKET_NUM=64, ADDR_WIDTH=$clog2(BUCKET_NUM)=6, CAPACITY=96 (75% load)
//   MAX_EVICTION_HOPS=8 (C firmware), lookup latency = 2 cycles.
// ============================================================================

`include "define.sv"

module mac_whitelist_cuckoo #(
    parameter int BUCKET_NUM  = 64,
    parameter int ADDR_WIDTH  = 6,    // $clog2(BUCKET_NUM)
    parameter int CAPACITY    = 96    // design capacity (75% load)
) (
    input clk,
    input reset_l,

    // Lookup port (125MHz)
    input             lookup_req,
    input      [47:0] lookup_mac,
    output reg        lookup_match,
    output reg        lookup_done,
    output            lookup_busy,

    // RAMIF config port (50MHz cfg_clk) — direct interface, no req/ack handshake
    input         cfg_clk,
    input         cfg_reset_l,
    input         cfg_rlwh,     // 1=write, 0=read
    input  [11:0] cfg_addr,
    input  [31:0] cfg_wdata,
    output [31:0] cfg_rdata,    // combinational mux

    input whitelist_en,
    input default_pass,

    // wl_status 观测口 (P2 已端到端驱动): cfg 域组合 popcount, 无需 CDC
    output wire [7:0] wl_used_cnt,

    // fpga_ila 调试总线（核 #8，标量；debug-ila 2026-09-03 添加）
    input  wire        ila_jtag_clk,
    input  wire        ila_core_we,
    input  wire        ila_core_re,
    input  wire [15:0] ila_core_addr,
    input  wire [31:0] ila_core_wdata,
    output wire [31:0] ila_core_rdata
);

  // ============================================================
  // Lookup FSM states
  // ============================================================
  localparam S_IDLE  = 2'd0;
  localparam S_DONE  = 2'd1;

  localparam int SLOTS = BUCKET_NUM * 2;              // 128 physical slots

  // ============================================================
  // Register map (SubBus 0x5000 base lives in reg_webserver; offsets below):
  //   0x00 WL_ENTRY_INDEX   RW  [6:0] slot# {bank,row}; [31]=1 → delete at slot
  //   0x01 WL_ENTRY_MAC_H   RW  MAC[47:16]
  //   0x02 WL_ENTRY_MAC_L   RW  MAC[15:0]
  //   0x03 WL_ENTRY_WR      WC  write {1'b1, cfg_mac} to both storages at cfg_idx
  //   0x04 WL_ENTRY_DEL     WC  write 49'b0 to both storages at cfg_idx
  //   0x05 WL_ENTRY_CLEAR   WC  clear all 128 slots (7-bit counter scans bank0+1)
  //   0x06 WL_ENTRY_RD_MAC_H RO  read back MAC[47:16] from shadow regfile
  //   0x07 WL_ENTRY_RD_MAC_L RO  read back MAC[15:0]
  //   0x08 WL_ENTRY_RD_VALID RO  read back valid bit
  //   0x09 WL_ENTRY_FREE_IDX RO  0x7F placeholder — no linear free slot in hash mode
  //   0x0A WL_MAX_ENTRIES    RO  CAPACITY (96) — C-side capacity check
  //   0x0B WL_USED_CNT       RO  popcount of valid_bits (0..128)
  // ============================================================

  reg  [           1:0] state;

  // ============================================================
  // Two main BRAMs (bank0 by h0, bank1 by h1): cfg_clk write, clk read
  // ============================================================
  wire [ADDR_WIDTH-1:0] bank0_rd_addr;
  wire [ADDR_WIDTH-1:0] bank1_rd_addr;
  wire [          48:0] bank0_q;
  wire [          48:0] bank1_q;

  wire [ADDR_WIDTH-1:0] bank0_wr_addr;
  wire [ADDR_WIDTH-1:0] bank1_wr_addr;
  wire                  bank0_wr_en;
  wire                  bank1_wr_en;
  wire [          48:0] bank0_wr_data;
  wire [          48:0] bank1_wr_data;

  // ============================================================
  // Shadow register file (cfg_clk write, combinational read) — 128 deep
  // ============================================================
  reg  [          48:0] shadow_rf                            [0:SLOTS-1];

  wire [           6:0] sh_wr_addr;
  wire                  sh_wr_en;
  wire [          48:0] sh_wr_data;
  wire [           6:0] sh_rd_addr;
  wire [          48:0] sh_rd_data;

  // ============================================================
  // Config registers (written via RAMIF, level-sensitive)
  // ============================================================
  reg  [           6:0] cfg_idx;       // slot# {bank, row[5:0]} (widened from seq 4-bit)
  reg  [          47:0] cfg_mac;

  // ============================================================
  // Entry valid bits — widened to SLOTS=128
  // ============================================================
  reg  [ SLOTS-1:0] valid_bits;

  // ============================================================
  // Clear sequencer — 7-bit counter, scans all 128 slots (bank = cnt[6])
  // ============================================================
  reg                   clear_active;
  reg  [           6:0] clear_cnt;

  // ============================================================
  // BRAM write control staging (single-pulse *_r, same as seq)
  // ============================================================
  reg                   bram_wr_en_r;
  reg  [           6:0] bram_wr_addr_r;    // slot# (bank+row)
  reg  [          48:0] bram_wr_data_r;
  reg                   sh_wr_en_r;
  reg  [           6:0] sh_wr_addr_r;
  reg  [          48:0] sh_wr_data_r;

  // ============================================================
  // Combinational used_cnt (popcount over 128 valid bits via generate)
  // ============================================================
  wire [           7:0] used_cnt_partial                          [SLOTS:0];

  wire [           7:0] used_cnt_comb = used_cnt_partial[SLOTS];

  // ============================================================
  // Combinational read mux (no state machine)
  // ============================================================
  wire [           3:0] rd_reg = cfg_addr[3:0];

  genvar gi;

  // ---- shadow regfile write / read ----
  always @(posedge cfg_clk) begin
    if (sh_wr_en) shadow_rf[sh_wr_addr] <= sh_wr_data;
  end
  assign sh_rd_data = shadow_rf[sh_rd_addr];

  // ============================================================
  // Config decode / clear sequencer / staging (cfg_clk domain)
  // ============================================================
  always @(posedge cfg_clk or negedge cfg_reset_l) begin
    if (!cfg_reset_l) begin
      cfg_idx      <= 0;
      cfg_mac      <= 48'b0;
      valid_bits   <= 0;
      clear_active <= 0;
      clear_cnt    <= 0;
      bram_wr_en_r <= 0;
      sh_wr_en_r   <= 0;
    end else begin
      bram_wr_en_r <= 1'b0;
      sh_wr_en_r   <= 1'b0;

      // ── Clear sequencer (autonomous after CLEAR; scans 0..127) ──
      if (clear_active) begin
        bram_wr_en_r   <= 1'b1;
        bram_wr_addr_r <= clear_cnt;
        bram_wr_data_r <= 49'b0;
        sh_wr_en_r     <= 1'b1;
        sh_wr_addr_r   <= clear_cnt;
        sh_wr_data_r   <= 49'b0;
        if (clear_cnt == (SLOTS - 1)) begin
          clear_active <= 1'b0;
          valid_bits   <= 0;
        end else begin
          clear_cnt <= clear_cnt + 1;
        end
      end

      // ── Normal write decode (level-sensitive, repeats safely) ──
      if (cfg_rlwh) begin
        case (cfg_addr[3:0])
          4'h0: begin  // INDEX: [6:0]=slot#; [31]=1 → delete entry at that slot
            cfg_idx <= cfg_wdata[6:0];
            if (cfg_wdata[31]) begin  // DELETE flag set
              bram_wr_en_r                          <= 1'b1;
              bram_wr_addr_r                        <= cfg_wdata[6:0];
              bram_wr_data_r                        <= 49'b0;
              sh_wr_en_r                            <= 1'b1;
              sh_wr_addr_r                          <= cfg_wdata[6:0];
              sh_wr_data_r                          <= 49'b0;
              valid_bits[cfg_wdata[6:0]]            <= 1'b0;
            end
          end
          4'h1:    cfg_mac[47:16] <= cfg_wdata[31:0];
          4'h2:    cfg_mac[15:0] <= cfg_wdata[15:0];
          4'h3: begin  // WR — write {1'b1, cfg_mac} to both storages at slot cfg_idx
            bram_wr_en_r        <= 1'b1;
            bram_wr_addr_r      <= cfg_idx;
            bram_wr_data_r      <= {1'b1, cfg_mac};
            sh_wr_en_r          <= 1'b1;
            sh_wr_addr_r        <= cfg_idx;
            sh_wr_data_r        <= {1'b1, cfg_mac};
            valid_bits[cfg_idx] <= 1'b1;
          end
          4'h4: begin  // DEL — write 49'b0 to both storages at slot cfg_idx
            bram_wr_en_r        <= 1'b1;
            bram_wr_addr_r      <= cfg_idx;
            bram_wr_data_r      <= 49'b0;
            sh_wr_en_r          <= 1'b1;
            sh_wr_addr_r        <= cfg_idx;
            sh_wr_data_r        <= 49'b0;
            valid_bits[cfg_idx] <= 1'b0;
          end
          4'h5: begin  // CLEAR — start clear sequencer
            clear_active <= 1'b1;
            clear_cnt    <= 0;
          end
          default: ;
        endcase
      end
    end
  end

  // ---- used_cnt popcount chain (SLOTS stages) ----
  assign used_cnt_partial[0] = 8'd0;
  generate
    for (gi = 0; gi < SLOTS; gi = gi + 1) begin : g_popcount
      assign used_cnt_partial[gi+1] = used_cnt_partial[gi] + {7'b0, valid_bits[gi]};
    end
  endgenerate
  assign wl_used_cnt = used_cnt_comb;

  // ---- Combinational read mux ----
  assign cfg_rdata =
    (!cfg_rlwh && rd_reg == 4'h0) ? {25'b0, cfg_idx} :          // 7-bit slot#
    (!cfg_rlwh && rd_reg == 4'h1) ? cfg_mac[47:16] :
    (!cfg_rlwh && rd_reg == 4'h2) ? {16'b0, cfg_mac[15:0]} :
    (!cfg_rlwh && rd_reg == 4'h6) ? sh_rd_data[47:16] :
    (!cfg_rlwh && rd_reg == 4'h7) ? {16'b0, sh_rd_data[15:0]} :
    (!cfg_rlwh && rd_reg == 4'h8) ? {31'b0, sh_rd_data[48]} :
    (!cfg_rlwh && rd_reg == 4'h9) ? 32'h0000_007F :             // FREE_IDX placeholder
    (!cfg_rlwh && rd_reg == 4'hA) ? CAPACITY[31:0] :            // MAX_ENTRIES = 96
    (!cfg_rlwh && rd_reg == 4'hB) ? {24'b0, used_cnt_comb} :
    32'b0;

  // Shadow read address: cfg_idx when reading shadow regs
  assign sh_rd_addr = (!cfg_rlwh && (rd_reg == 4'h6 || rd_reg == 4'h7 || rd_reg == 4'h8))
                      ? cfg_idx : 7'b0;

  // ============================================================
  // Write routing to the two banks (slot[6] = bank, [5:0] = row)
  // Clear sequencer selects bank by clear_cnt[6] (not cfg_idx)
  // ============================================================
  wire bram_sel_bank1 = bram_wr_addr_r[6];

  assign bank0_wr_en   = clear_active ? ~clear_cnt[6]          : (bram_wr_en_r & ~bram_sel_bank1);
  assign bank1_wr_en   = clear_active ?  clear_cnt[6]          : (bram_wr_en_r &  bram_sel_bank1);
  assign bank0_wr_addr = clear_active ? clear_cnt[ADDR_WIDTH-1:0] : bram_wr_addr_r[ADDR_WIDTH-1:0];
  assign bank1_wr_addr = bank0_wr_addr;
  assign bank0_wr_data = clear_active ? 49'b0 : bram_wr_data_r;
  assign bank1_wr_data = bank0_wr_data;

  // Shadow single storage write (7-bit slot index naturally spans both banks)
  assign sh_wr_en   = (clear_active) ? 1'b1 : sh_wr_en_r;
  assign sh_wr_addr = (clear_active) ? clear_cnt : sh_wr_addr_r;
  assign sh_wr_data = (clear_active) ? 49'b0 : sh_wr_data_r;

  // ============================================================
  // Hash functions (RTL, combinational) — bit-exact with C wl_fold (c/whitelist.c)
  // ============================================================
  // fold6: 48-bit split into 8 x 6-bit chunks, all XORed -> 6-bit
  function [ADDR_WIDTH-1:0] wl_fold(input [47:0] x);
    wl_fold = x[5:0] ^ x[11:6] ^ x[17:12] ^ x[23:18]
            ^ x[29:24] ^ x[35:30] ^ x[41:36] ^ x[47:42];
  endfunction
  function [ADDR_WIDTH-1:0] wl_hash0(input [47:0] mac);
    wl_hash0 = wl_fold(mac);
  endfunction
  function [ADDR_WIDTH-1:0] wl_hash1(input [47:0] mac);
    // byte-order reversal (6 bytes) then fold
    wl_hash1 = wl_fold({mac[7:0],   mac[15:8],  mac[23:16],
                        mac[31:24], mac[39:32], mac[47:40]});
  endfunction

  // ============================================================
  // Lookup FSM (clk domain) — cuckoo: 2 cycles, no iteration
  //  req in S_IDLE → hash addresses on both bank read ports that very cycle;
  //  next cycle (S_DONE) BRAM q valid → parallel 49-bit compare, latch, done.
  // ============================================================
  // ★ Read address combinational, driven straight from the hash while req is high.
  //   NOT gated on `state`: state transitions IDLE→DONE on the very edge the BRAM
  //   samples the address, so gating on state can collapse the address to 0 at that
  //   edge in event simulation (FSM NBA updates state before the BRAM samples).
  //   req-only drive keeps the address stable (= hash) across the launch edge;
  //   the extra reads while req is held (during the DONE cycle / back-to-back) are
  //   harmless — the FSM only latches the result sampled at the req→DONE edge.
  assign bank0_rd_addr = lookup_req ? wl_hash0(lookup_mac) : {ADDR_WIDTH{1'b0}};
  assign bank1_rd_addr = lookup_req ? wl_hash1(lookup_mac) : {ADDR_WIDTH{1'b0}};
  // 49-bit equality folds the valid bit into the compare: an invalid entry reads
  // back 49'b0, never equal to {1'b1, mac} (all-zero MAC is rejected in C).
  wire hit_comb = (bank0_q == {1'b1, lookup_mac}) || (bank1_q == {1'b1, lookup_mac});

  always @(posedge clk or negedge reset_l) begin
    if (!reset_l) begin
      state        <= S_IDLE;
      lookup_match <= 0;
      lookup_done  <= 0;
    end else begin
      lookup_done <= 1'b0;
      case (state)
        S_IDLE:
          if (lookup_req) state <= S_DONE;   // address is on the read ports this cycle
        S_DONE: begin
          // Gate semantics kept bit-identical to mode0 seq's DONE decision:
          //   match = default_pass || (whitelist_en && hit)
          // i.e. default_pass overrides even when the engine is enabled (keeps the
          // 2026-08-30 board-fix: "en=1 + default_pass=1 => allow all").
          lookup_match <= default_pass || (whitelist_en && hit_comb);
          lookup_done  <= 1'b1;
          state        <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end
  assign lookup_busy = (state != S_IDLE);

  // ============================================================
  // Two BRAM banks
  // ============================================================
  dual_clock_simple_dual_port_ram #(
      .data_width(49),
      .addr_width(ADDR_WIDTH),
      .depth(BUCKET_NUM),
      .block_ram_size(32),
      .ram_type(`LARGER_RAM),
      .vendor(`DEVICE_VENDOR)
  ) u_bank0 (
      .clock_a(cfg_clk),
      .clock_b(clk),
      .wren_a(bank0_wr_en),
      .data_a(bank0_wr_data),
      .address_a(bank0_wr_addr),
      .address_b(bank0_rd_addr),
      .q_b(bank0_q)
  );

  dual_clock_simple_dual_port_ram #(
      .data_width(49),
      .addr_width(ADDR_WIDTH),
      .depth(BUCKET_NUM),
      .block_ram_size(32),
      .ram_type(`LARGER_RAM),
      .vendor(`DEVICE_VENDOR)
  ) u_bank1 (
      .clock_a(cfg_clk),
      .clock_b(clk),
      .wren_a(bank1_wr_en),
      .data_a(bank1_wr_data),
      .address_a(bank1_wr_addr),
      .address_b(bank1_rd_addr),
      .q_b(bank1_q)
  );

  // ============================================================
  // fpga_ila 调试核 #8（debug-ila skill 添加 2026-09-03）
  // 探针全在 clk(125MHz) 域 —— 采样时钟必须与探针同域（核 7 同款铁律）
  // WL_SIM 仅在仿真侧定义（sim/define.sv）：仿真文件清单不含 fpga_ila，
  // 例化随之隔离；板上综合无此宏，核正常参与。
  // ============================================================
`ifndef WL_SIM
  soft_ila_top #(
      .CORE_EN       (1),
      .DATA_DEPTH    (2048),
      .MAX_WINDOWS   (1),
      .SAMPLE_HZ     (125_000_000),
      .RST_ACTIVE_LOW(1),
      .NUM_PROBES    (8),
      .PROBE0_WIDTH  (1),          // lookup_req
      .PROBE1_WIDTH  (1),          // lookup_match
      .PROBE2_WIDTH  (1),          // lookup_done
      .PROBE3_WIDTH  (1),          // lookup_busy
      .PROBE4_WIDTH  (2),          // state
      .PROBE5_WIDTH  (1),          // hit_comb
      .PROBE6_WIDTH  (ADDR_WIDTH), // bank0_rd_addr
      .PROBE7_WIDTH  (ADDR_WIDTH), // bank1_rd_addr
      .EXT_TRIG_EN   (1)
  ) u_ila_cuckoo (
      .sample_clk    (clk),
      .rst_in        (reset_l),
      .jtag_clk      (ila_jtag_clk),
      .probe0        (lookup_req),
      .probe1        (lookup_match),
      .probe2        (lookup_done),
      .probe3        (lookup_busy),
      .probe4        (state),
      .probe5        (hit_comb),
      .probe6        (bank0_rd_addr),
      .probe7        (bank1_rd_addr),
      .trigger_in    (1'b0),
      .trigger_out   (),
      .armed_out     (),
      .reg_we        (ila_core_we),
      .reg_re        (ila_core_re),
      .reg_addr      (ila_core_addr),
      .reg_wdata     (ila_core_wdata),
      .reg_rdata     (ila_core_rdata)
  );
`endif

endmodule
