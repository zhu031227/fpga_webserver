// mac_whitelist_seq — BRAM-based sequential MAC whitelist lookup engine
//
// MODE 0: Sequential search through Block RAM entries
// - Main BRAM: dual_clock_simple_dual_port_ram (Port A=cfg_clk write, Port B=clk read)
// - Shadow BRAM: single_clock_simple_dual_port_ram (cfg_clk, CPU read-back)
// - Lookup: 1 IDLE + 16 CMP + 1 DONE = 18 cycles @125MHz = 144ns
// - RAMIF config port: direct rlwh/addr/wdata → combinational rdata, no state machine

`include "define.sv"

module mac_whitelist_seq #(
    parameter int ENTRY_NUM = 16,
    parameter int ADDR_WIDTH = 4,  // $clog2(ENTRY_NUM)
    parameter ILA_NUM_CORES = 2  // fpga_ila 调试核数（写口+读口）
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

    // fpga_ila 调试总线
    input  wire [   ILA_NUM_CORES-1:0] ila_core_we,
    input  wire [                15:0] ila_core_addr,
    input  wire [                31:0] ila_core_wdata,
    output wire [ILA_NUM_CORES*32-1:0] ila_core_rdata,
    output wire [   ILA_NUM_CORES-1:0] ila_core_cross,
    input  wire                        ila_cross_in,
    output wire [   ILA_NUM_CORES-1:0] ila_core_trig
);

  // ============================================================
  // Lookup FSM states
  // ============================================================
  localparam S_IDLE = 2'd0;
  localparam S_COMPARE = 2'd1;
  localparam S_DONE = 2'd2;

  // ============================================================
  // Register map:
  //   0x00 WL_ENTRY_INDEX   RW  [ADDR_WIDTH-1:0]
  //   0x01 WL_ENTRY_MAC_H   RW  MAC[47:16]
  //   0x02 WL_ENTRY_MAC_L   RW  MAC[15:0]
  //   0x03 WL_ENTRY_WR      WC  write {1'b1, cfg_mac} to both BRAMs at cfg_idx
  //   0x04 WL_ENTRY_DEL     WC  write 49'b0 to both BRAMs at cfg_idx
  //   0x05 WL_ENTRY_CLEAR   WC  clear all entries (writes 0 to every BRAM addr)
  //   0x06 WL_ENTRY_RD_MAC_H RO  read back MAC[47:16] from shadow BRAM
  //   0x07 WL_ENTRY_RD_MAC_L RO  read back MAC[15:0]
  //   0x08 WL_ENTRY_RD_VALID RO  read back valid bit
  //   0x09 WL_ENTRY_FREE_IDX RO  first free index (priority encoder on valid_bits)
  //   0x0A WL_MAX_ENTRIES    RO  ENTRY_NUM
  //   0x0B WL_USED_CNT       RO  popcount of valid_bits
  // ============================================================

  reg  [           1:0] state;
  reg  [ADDR_WIDTH-1:0] cmp_index;
  reg                   match_found;

  // ============================================================
  // Main BRAM: dual-clock (cfg_clk write, clk read) for lookup
  // ============================================================
  wire [ADDR_WIDTH-1:0] bram_wr_addr;
  wire                  bram_wr_en;
  wire [          48:0] bram_wr_data;

  wire [ADDR_WIDTH-1:0] bram_rd_addr;
  wire [          48:0] bram_rd_data;

  wire                  bram_rd_valid = bram_rd_data[48];
  wire [          47:0] bram_rd_mac = bram_rd_data[47:0];

  // ============================================================
  // Shadow register file (replaces shadow BRAM — combinational read)
  // ============================================================
  // Declared below in BRAM write control section
  wire [ADDR_WIDTH-1:0] sh_wr_addr;
  wire                  sh_wr_en;
  wire [          48:0] sh_wr_data;
  wire [ADDR_WIDTH-1:0] sh_rd_addr;
  reg  [          48:0] shadow_rf                                   [0:ENTRY_NUM-1];

  // Combinational read from register file
  wire [          48:0] sh_rd_data;

  // ============================================================
  // Config registers (written via RAMIF, level-sensitive)
  // ============================================================
  reg  [ADDR_WIDTH-1:0] cfg_idx;
  reg  [          47:0] cfg_mac;

  // ============================================================
  // Entry valid bits (maintained on every write, no scan FSM)
  // ============================================================
  reg  [ ENTRY_NUM-1:0] valid_bits;

  // ============================================================
  // Clear sequencer — simple counter, not a state machine
  // ============================================================
  reg                   clear_active;
  reg  [ADDR_WIDTH-1:0] clear_cnt;

  // ============================================================
  // BRAM write control (normal writes + clear sequencer)
  // ============================================================
  reg                   bram_wr_en_r;
  reg  [ADDR_WIDTH-1:0] bram_wr_addr_r;
  reg  [          48:0] bram_wr_data_r;
  reg                   sh_wr_en_r;
  reg  [ADDR_WIDTH-1:0] sh_wr_addr_r;
  reg  [          48:0] sh_wr_data_r;

  // ============================================================
  // Combinational free_idx (priority encoder chain via generate)
  // ============================================================
  wire [ADDR_WIDTH-1:0] free_idx_stage                              [  ENTRY_NUM:0];

  wire [ADDR_WIDTH-1:0] free_idx_comb = free_idx_stage[0];

  // ============================================================
  // Combinational used_cnt (popcount via generate)
  // ============================================================
  wire [           7:0] used_cnt_partial                            [  ENTRY_NUM:0];

  wire [           7:0] used_cnt_comb = used_cnt_partial[ENTRY_NUM];

  // ============================================================
  // Combinational read mux (no state machine)
  // Shadow read: combinational from register file (0-cycle latency)
  // ============================================================
  wire [           3:0] rd_reg = cfg_addr[3:0];

  genvar gi;

  always @(posedge cfg_clk) begin
    if (sh_wr_en) shadow_rf[sh_wr_addr] <= sh_wr_data;
  end
  assign sh_rd_data = shadow_rf[sh_rd_addr];

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

      // ── Clear sequencer (runs autonomously after CLEAR command) ──
      if (clear_active) begin
        bram_wr_en_r   <= 1'b1;
        bram_wr_addr_r <= clear_cnt;
        bram_wr_data_r <= 49'b0;
        sh_wr_en_r     <= 1'b1;
        sh_wr_addr_r   <= clear_cnt;
        sh_wr_data_r   <= 49'b0;
        if (clear_cnt == (ENTRY_NUM - 1)) begin
          clear_active <= 1'b0;
          valid_bits   <= 0;
        end else begin
          clear_cnt <= clear_cnt + 1;
        end
      end

      // ── Normal write decode (level-sensitive, repeats safely) ──
      if (cfg_rlwh) begin
        case (cfg_addr[3:0])
          4'h0: begin  // INDEX: [3:0]=index, [31]=1→delete entry at that index
            cfg_idx <= cfg_wdata[ADDR_WIDTH-1:0];
            if (cfg_wdata[31]) begin  // DELETE flag set
              bram_wr_en_r                          <= 1'b1;
              bram_wr_addr_r                        <= cfg_wdata[ADDR_WIDTH-1:0];
              bram_wr_data_r                        <= 49'b0;
              sh_wr_en_r                            <= 1'b1;
              sh_wr_addr_r                          <= cfg_wdata[ADDR_WIDTH-1:0];
              sh_wr_data_r                          <= 49'b0;
              valid_bits[cfg_wdata[ADDR_WIDTH-1:0]] <= 1'b0;
            end
          end
          4'h1:    cfg_mac[47:16] <= cfg_wdata[31:0];
          4'h2:    cfg_mac[15:0] <= cfg_wdata[15:0];
          4'h3: begin  // WR — write {1'b1, cfg_mac} to both BRAMs
            bram_wr_en_r        <= 1'b1;
            bram_wr_addr_r      <= cfg_idx;
            bram_wr_data_r      <= {1'b1, cfg_mac};
            sh_wr_en_r          <= 1'b1;
            sh_wr_addr_r        <= cfg_idx;
            sh_wr_data_r        <= {1'b1, cfg_mac};
            valid_bits[cfg_idx] <= 1'b1;
          end
          4'h4: begin  // DEL — write 49'b0 to both BRAMs
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
  assign free_idx_stage[ENTRY_NUM] = {ADDR_WIDTH{1'b1}};  // default: table full
  generate
    for (gi = ENTRY_NUM - 1; gi >= 0; gi = gi - 1) begin : g_free_idx
      assign free_idx_stage[gi] = !valid_bits[gi] ? gi[ADDR_WIDTH-1:0] : free_idx_stage[gi+1];
    end
  endgenerate
  assign used_cnt_partial[0] = 8'd0;

  generate
    for (gi = 0; gi < ENTRY_NUM; gi = gi + 1) begin : g_popcount
      assign used_cnt_partial[gi+1] = used_cnt_partial[gi] + {7'b0, valid_bits[gi]};
    end
  endgenerate
  assign cfg_rdata =
    (!cfg_rlwh && rd_reg == 4'h0) ? {28'b0, cfg_idx} :
    (!cfg_rlwh && rd_reg == 4'h1) ? cfg_mac[47:16] :
    (!cfg_rlwh && rd_reg == 4'h2) ? {16'b0, cfg_mac[15:0]} :
    (!cfg_rlwh && rd_reg == 4'h6) ? sh_rd_data[47:16] :
    (!cfg_rlwh && rd_reg == 4'h7) ? {16'b0, sh_rd_data[15:0]} :
    (!cfg_rlwh && rd_reg == 4'h8) ? {31'b0, sh_rd_data[48]} :
    (!cfg_rlwh && rd_reg == 4'h9) ? {28'b0, free_idx_comb} :
    (!cfg_rlwh && rd_reg == 4'hA) ? ENTRY_NUM[31:0] :
    (!cfg_rlwh && rd_reg == 4'hB) ? {24'b0, used_cnt_comb} :
    32'b0;

  // Shadow BRAM read address: driven by cfg_idx when reading shadow regs
  assign sh_rd_addr = (!cfg_rlwh && (rd_reg == 4'h6 || rd_reg == 4'h7 || rd_reg == 4'h8))
                      ? cfg_idx : {ADDR_WIDTH{1'b0}};

  // ============================================================
  // BRAM write port assignments
  // ============================================================
  assign bram_wr_en = (clear_active) ? 1'b1 : bram_wr_en_r;
  assign bram_wr_addr = (clear_active) ? clear_cnt : bram_wr_addr_r;
  assign bram_wr_data = (clear_active) ? 49'b0 : bram_wr_data_r;
  assign sh_wr_en = (clear_active) ? 1'b1 : sh_wr_en_r;
  assign sh_wr_addr = (clear_active) ? clear_cnt : sh_wr_addr_r;
  assign sh_wr_data = (clear_active) ? 49'b0 : sh_wr_data_r;

  // ============================================================
  // ILA Core 0: BRAM/shadow write port monitor (depth=1024)
  //   采样时钟统一用 clk(125MHz)，cfg_clk 域信号被过采样(波形中见连续重复值)
  // ============================================================
  soft_ila_top #(
      .CORE_EN       (1),
      .DATA_DEPTH    (1024),
      .MAX_WINDOWS   (4),
      .SAMPLE_HZ     (125_000_000),
      .RST_ACTIVE_LOW(1),
      .NUM_PROBES    (7),
      .PROBE0_WIDTH  (1),
      .PROBE1_WIDTH  (1),
      .PROBE2_WIDTH  (ADDR_WIDTH),
      .PROBE3_WIDTH  (49),
      .PROBE4_WIDTH  (1),
      .PROBE5_WIDTH  (ADDR_WIDTH),
      .PROBE6_WIDTH  (49)
  ) u_ila_wr (
      .sample_clk    (clk),
      .rst_in        (reset_l),
      .probe0        (clear_active),
      .probe1        (bram_wr_en),
      .probe2        (bram_wr_addr),
      .probe3        (bram_wr_data),
      .probe4        (sh_wr_en),
      .probe5        (sh_wr_addr),
      .probe6        (sh_wr_data),
      .ext_trig_in   (1'b0),
      .trig_out      (ila_core_trig[0]),
      .cross_trig_in (ila_cross_in),
      .cross_trig_out(ila_core_cross[0]),
      .reg_we        (ila_core_we[0]),
      .reg_re        (1'b1),
      .reg_addr      (ila_core_addr),
      .reg_wdata     (ila_core_wdata),
      .reg_rdata     (ila_core_rdata[0*32+:32])
  );

  assign bram_rd_addr = (state == S_COMPARE) ? cmp_index : {ADDR_WIDTH{1'b0}};

  // ============================================================
  // BRAM instances
  // ============================================================
  dual_clock_simple_dual_port_ram #(
      .data_width(49),
      .addr_width(ADDR_WIDTH),
      .depth(ENTRY_NUM),
      .block_ram_size(32),
      .ram_type(`LARGER_RAM),
      .vendor(`DEVICE_VENDOR)
  ) u_bram (
      .clock_a(cfg_clk),
      .clock_b(clk),
      .wren_a(bram_wr_en),
      .data_a(bram_wr_data),
      .address_a(bram_wr_addr),
      .address_b(bram_rd_addr),
      .q_b(bram_rd_data)
  );

  // ============================================================
  // ILA Core 1: BRAM read port monitor (depth=1024, clk=125MHz)
  // ============================================================
  soft_ila_top #(
      .CORE_EN       (1),
      .DATA_DEPTH    (1024),
      .MAX_WINDOWS   (4),
      .SAMPLE_HZ     (125_000_000),
      .RST_ACTIVE_LOW(1),
      .NUM_PROBES    (2),
      .PROBE0_WIDTH  (4),
      .PROBE1_WIDTH  (49)
  ) u_ila_bram (
      .sample_clk    (clk),
      .rst_in        (reset_l),
      .probe0        (bram_rd_addr),
      .probe1        (bram_rd_data),
      .ext_trig_in   (1'b0),
      .trig_out      (ila_core_trig[1]),
      .cross_trig_in (ila_cross_in),
      .cross_trig_out(ila_core_cross[1]),
      .reg_we        (ila_core_we[1]),
      .reg_re        (1'b1),
      .reg_addr      (ila_core_addr),
      .reg_wdata     (ila_core_wdata),
      .reg_rdata     (ila_core_rdata[1*32+:32])
  );

  // ============================================================
  // Lookup FSM (clk domain, 125MHz) — unchanged
  // ============================================================
  always @(posedge clk or negedge reset_l) begin
    if (!reset_l) begin
      state        <= S_IDLE;
      cmp_index    <= 0;
      match_found  <= 0;
      lookup_match <= 0;
      lookup_done  <= 0;
    end else begin
      lookup_done <= 1'b0;
      case (state)
        S_IDLE:
        if (lookup_req) begin
          state       <= S_COMPARE;
          cmp_index   <= 0;
          match_found <= 0;
        end
        S_COMPARE: begin
          if (cmp_index > 0 && bram_rd_valid && (bram_rd_mac == lookup_mac)) match_found <= 1'b1;
          if (cmp_index == (ENTRY_NUM - 1)) state <= S_DONE;
          else cmp_index <= cmp_index + 1;
        end
        S_DONE: begin
          if (bram_rd_valid && (bram_rd_mac == lookup_mac)) match_found <= 1'b1;
          lookup_match <= whitelist_en ?
              (match_found || (bram_rd_valid && (bram_rd_mac == lookup_mac))) :
              default_pass;
          lookup_done <= 1'b1;
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end
  assign lookup_busy = (state != S_IDLE);
endmodule
