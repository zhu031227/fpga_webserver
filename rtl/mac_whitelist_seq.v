// mac_whitelist_seq — BRAM-based sequential MAC whitelist lookup engine
//
// MODE 0: Sequential search through Block RAM entries
// - Main BRAM: dual_clock_simple_dual_port_ram (Port A=cfg_clk write, Port B=clk read)
// - Shadow BRAM: single_clock_simple_dual_port_ram (cfg_clk, CPU read-back)
// - Lookup: 1 IDLE + 16 CMP + 1 DONE = 18 cycles @125MHz = 144ns
// - LCPU bus slave interface for entry management

`include "define.sv"

module mac_whitelist_seq #(
    parameter int ENTRY_NUM  = 16,
    parameter int ADDR_WIDTH = 4    // $clog2(ENTRY_NUM)
) (
    input clk,
    input reset_l,

    // Lookup port (125MHz)
    input             lookup_req,
    input      [47:0] lookup_mac,
    output reg        lookup_match,
    output reg        lookup_done,
    output            lookup_busy,

    // LCPU bus config port (50MHz cfg_clk)
    input             cfg_clk,
    input             cfg_reset_l,
    input             cfg_req,
    input             cfg_rhwl,
    input      [31:0] cfg_wdata,
    input      [15:0] cfg_address,
    output reg [31:0] cfg_rdata,
    output reg        cfg_ack,

    input whitelist_en,
    input default_pass
);

  // ============================================================
  // Lookup FSM states
  // ============================================================
  localparam S_IDLE = 2'd0;
  localparam S_COMPARE = 2'd1;
  localparam S_DONE = 2'd2;

  // CPU read FSM: handles BRAM 1-cycle read latency and multi-entry scans
  localparam CFG_IDLE = 3'd0;
  localparam CFG_WAIT_RD = 3'd1;  // wait 1 cycle for BRAM read data
  localparam CFG_SCAN_NEXT = 3'd2;  // scan next entry (free_idx / used_cnt)

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
  // Shadow BRAM: single-clock (cfg_clk) for CPU read-back
  //   Port A: write (mirrors main BRAM)
  //   Port B: read (CPU status reads, 1-cycle latency handled by FSM)
  // ============================================================
  wire [ADDR_WIDTH-1:0] sh_wr_addr;
  wire                  sh_wr_en;
  wire [          48:0] sh_wr_data;
  wire [ADDR_WIDTH-1:0] sh_rd_addr;
  wire [          48:0] sh_rd_data;

  // ============================================================
  // LCPU Bus Config Interface (cfg_clk domain, 50MHz)
  //
  // Register map:
  //   0x00 WL_ENTRY_INDEX   RW  [3:0]
  //   0x01 WL_ENTRY_MAC_H   RW  MAC[47:16]
  //   0x02 WL_ENTRY_MAC_L   RW  MAC[15:0]
  //   0x03 WL_ENTRY_WR      WC  write {valid, mac} to both BRAMs
  //   0x04 WL_ENTRY_DEL     WC  write {0, 48'b0} to both BRAMs
  //   0x05 WL_ENTRY_CLEAR   WC  write 0 to entry 0 (full clear via iteration)
  //   0x06 WL_ENTRY_RD_MAC_H RO  read back MAC[47:16] from shadow
  //   0x07 WL_ENTRY_RD_MAC_L RO  read back MAC[15:0]
  //   0x08 WL_ENTRY_RD_VALID RO  read back valid bit
  //   0x09 WL_ENTRY_FREE_IDX RO  first free index (shadow scan FSM)
  //   0x0A WL_MAX_ENTRIES    RO  ENTRY_NUM
  //   0x0B WL_USED_CNT       RO  count of valid entries (shadow scan FSM)
  // ============================================================

  reg  [ADDR_WIDTH-1:0] cfg_idx;
  reg  [          47:0] cfg_mac;
  reg bram_wr_en_r, sh_wr_en_r;
  reg [ADDR_WIDTH-1:0] bram_wr_addr_r, sh_wr_addr_r;
  reg [48:0] bram_wr_data_r, sh_wr_data_r;
  reg [ADDR_WIDTH-1:0] sh_rd_addr_r;

  reg [           2:0] cfg_state;
  reg [           3:0] cfg_rd_reg;  // which register is being read
  reg [ADDR_WIDTH-1:0] cfg_scan_idx;  // scan index for free_idx / used_cnt
  reg [           7:0] cfg_scan_cnt;  // running count for used_cnt

  assign bram_rd_addr = (state == S_COMPARE) ? cmp_index : {ADDR_WIDTH{1'b0}};

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

  single_clock_simple_dual_port_ram #(
      .data_width(49),
      .addr_width(ADDR_WIDTH),
      .depth(ENTRY_NUM),
      .block_ram_size(32),
      .ram_type(`LARGER_RAM),
      .vendor(`DEVICE_VENDOR)
  ) u_shadow (
      .clk(cfg_clk),
      .wren_a(sh_wr_en),
      .data_a(sh_wr_data),
      .address_a(sh_wr_addr),
      .address_b(sh_rd_addr),
      .q_b(sh_rd_data)
  );

  // ============================================================
  // Lookup FSM (clk domain, 125MHz)
  // ============================================================
  always @(posedge clk or negedge reset_l) begin
    if (!reset_l) begin
      state <= S_IDLE;
      cmp_index <= 0;
      match_found <= 0;
      lookup_match <= 0;
      lookup_done <= 0;
    end else begin
      lookup_done <= 1'b0;
      case (state)
        S_IDLE:
        if (lookup_req) begin
          state <= S_COMPARE;
          cmp_index <= 0;
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
  assign bram_wr_en = bram_wr_en_r;
  assign bram_wr_addr = bram_wr_addr_r;
  assign bram_wr_data = bram_wr_data_r;
  assign sh_wr_en = sh_wr_en_r;
  assign sh_wr_addr = sh_wr_addr_r;
  assign sh_wr_data = sh_wr_data_r;
  assign sh_rd_addr = sh_rd_addr_r;

  always @(posedge cfg_clk or negedge cfg_reset_l) begin
    if (!cfg_reset_l) begin
      cfg_idx <= 0;
      cfg_mac <= 48'b0;
      cfg_rdata <= 0;
      cfg_ack <= 0;
      cfg_state <= CFG_IDLE;
      cfg_rd_reg <= 0;
      cfg_scan_idx <= 0;
      cfg_scan_cnt <= 0;
      bram_wr_en_r <= 0;
      sh_wr_en_r <= 0;
    end else begin
      cfg_ack      <= 1'b0;
      bram_wr_en_r <= 1'b0;
      sh_wr_en_r   <= 1'b0;

      case (cfg_state)

        CFG_IDLE: begin
          if (cfg_req) begin
            cfg_rd_reg <= cfg_address[3:0];

            if (cfg_rhwl == 1'b0) begin  // ── WRITE ──
              case (cfg_address[3:0])
                4'h0: cfg_idx <= cfg_wdata[ADDR_WIDTH-1:0];
                4'h1: cfg_mac[47:16] <= cfg_wdata[31:0];
                4'h2: cfg_mac[15:0] <= cfg_wdata[15:0];
                4'h3: begin  // WR — write both BRAMs
                  bram_wr_en_r <= 1'b1;
                  bram_wr_addr_r <= cfg_idx;
                  bram_wr_data_r <= {1'b1, cfg_mac};
                  sh_wr_en_r <= 1'b1;
                  sh_wr_addr_r <= cfg_idx;
                  sh_wr_data_r <= {1'b1, cfg_mac};
                end
                4'h4: begin  // DEL — write 0 to both
                  bram_wr_en_r <= 1'b1;
                  bram_wr_addr_r <= cfg_idx;
                  bram_wr_data_r <= 49'b0;
                  sh_wr_en_r <= 1'b1;
                  sh_wr_addr_r <= cfg_idx;
                  sh_wr_data_r <= 49'b0;
                end
                4'h5: begin  // CLEAR — write 0 to entry 0
                  bram_wr_en_r <= 1'b1;
                  bram_wr_addr_r <= 0;
                  bram_wr_data_r <= 49'b0;
                  sh_wr_en_r <= 1'b1;
                  sh_wr_addr_r <= 0;
                  sh_wr_data_r <= 49'b0;
                end
                default: ;
              endcase
              cfg_ack <= 1'b1;

            end else begin  // ── READ ──
              case (cfg_address[3:0])
                4'h0: begin
                  cfg_rdata <= {28'b0, cfg_idx};
                  cfg_ack   <= 1'b1;
                end
                4'h1: begin
                  cfg_rdata <= cfg_mac[47:16];
                  cfg_ack   <= 1'b1;
                end
                4'h2: begin
                  cfg_rdata <= {16'b0, cfg_mac[15:0]};
                  cfg_ack   <= 1'b1;
                end
                4'hA: begin
                  cfg_rdata <= ENTRY_NUM;
                  cfg_ack   <= 1'b1;
                end
                // Shadow BRAM reads (1-cycle latency)
                4'h6, 4'h7, 4'h8: begin
                  sh_rd_addr_r <= cfg_idx;
                  cfg_state <= CFG_WAIT_RD;
                end
                // Free index scan
                4'h9: begin
                  cfg_scan_idx <= 0;
                  cfg_scan_cnt <= 0;
                  sh_rd_addr_r <= 0;
                  cfg_state <= CFG_WAIT_RD;
                end
                // Used count scan
                4'hB: begin
                  cfg_scan_idx <= 0;
                  cfg_scan_cnt <= 0;
                  sh_rd_addr_r <= 0;
                  cfg_state <= CFG_WAIT_RD;
                end
                default: begin
                  cfg_rdata <= 32'b0;
                  cfg_ack   <= 1'b1;
                end
              endcase
            end
          end
        end

        CFG_WAIT_RD: begin
          // BRAM read data valid this cycle
          case (cfg_rd_reg)
            4'h6: begin
              cfg_rdata <= sh_rd_data[47:16];
              cfg_ack   <= 1'b1;
              cfg_state <= CFG_IDLE;
            end
            4'h7: begin
              cfg_rdata <= {16'b0, sh_rd_data[15:0]};
              cfg_ack   <= 1'b1;
              cfg_state <= CFG_IDLE;
            end
            4'h8: begin
              cfg_rdata <= {31'b0, sh_rd_data[48]};
              cfg_ack   <= 1'b1;
              cfg_state <= CFG_IDLE;
            end
            4'h9: begin  // free_idx — check current entry
              if (!sh_rd_data[48]) begin
                // Found free entry at cfg_scan_idx
                cfg_rdata <= {28'b0, cfg_scan_idx};
                cfg_ack   <= 1'b1;
                cfg_state <= CFG_IDLE;
              end else if (cfg_scan_idx == (ENTRY_NUM - 1)) begin
                // Table full
                cfg_rdata <= 32'hFF;
                cfg_ack   <= 1'b1;
                cfg_state <= CFG_IDLE;
              end else begin
                // Check next entry
                cfg_scan_idx <= cfg_scan_idx + 1;
                sh_rd_addr_r <= cfg_scan_idx + 1;
                // Stay in CFG_WAIT_RD
              end
            end
            4'hB: begin  // used_cnt — count valid entries
              if (sh_rd_data[48]) cfg_scan_cnt <= cfg_scan_cnt + 1;
              if (cfg_scan_idx == (ENTRY_NUM - 1)) begin
                cfg_rdata <= {24'b0, sh_rd_data[48] ? (cfg_scan_cnt + 1) : cfg_scan_cnt};
                cfg_ack   <= 1'b1;
                cfg_state <= CFG_IDLE;
              end else begin
                cfg_scan_idx <= cfg_scan_idx + 1;
                sh_rd_addr_r <= cfg_scan_idx + 1;
                // Stay in CFG_WAIT_RD
              end
            end
            default: begin
              cfg_ack   <= 1'b1;
              cfg_state <= CFG_IDLE;
            end
          endcase
        end

        default: cfg_state <= CFG_IDLE;
      endcase
    end
  end
endmodule
