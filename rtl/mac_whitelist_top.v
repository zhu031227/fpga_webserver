// mac_whitelist_top — MAC whitelist top-level wrapper
//
// Instantiates the lookup engine based on LOOKUP_MODE parameter:
//   MODE 0: Sequential search (mac_whitelist_seq) — THIS IMPLEMENTATION
//   MODE 1: Binary search (mac_whitelist_bin) — reserved skeleton
//   MODE 2: Cuckoo hash (mac_whitelist_cuckoo) — THIS IMPLEMENTATION
//
// All modes share the same external interface.

module mac_whitelist_top #(
    parameter int LOOKUP_MODE = 0,
    parameter int ENTRY_NUM = 16,
    parameter int ADDR_WIDTH = 4
) (
    input clk,
    input reset_l,

    // Lookup port
    input         lookup_req,
    input  [47:0] lookup_mac,
    output        lookup_match,
    output        lookup_done,
    output        lookup_busy,

    // LCPU bus config port (RAMIF interface, same as program_ram)
    input         cfg_clk,
    input         cfg_reset_l,
    input         cfg_rlwh,
    input  [11:0] cfg_addr,
    input  [31:0] cfg_wdata,
    output [31:0] cfg_rdata,

    // Global control
    input whitelist_en,
    input default_pass,

    // 运行时查找模式选择（2026-09-03 起）：1=布谷鸟(模式2), 0=顺序(模式0)。
    // 由 wl_ctrl[2] 经 CDC 同步进来；替代原先综合期 LOOKUP_MODE 二选一。
    input lookup_mode_sel,

    // wl_status 观测口 (P2修复 wl_status 驱动, 2026-08-31):
    // [7:0]=运行时 lookup_mode(0 或 2), [15:8]=活跃引擎 used_cnt(cfg域popcount)
    output wire [15:0] wl_status
);

  // ============================================================
  // 双引擎常驻 + 运行时切换（2026-09-03）
  //   原先 LOOKUP_MODE 是综合期 generate 二选一，切模式须重出 bit。
  //   现同时实例化 seq(模式0) 与 cuckoo(模式2)，运行时由 lookup_mode_sel 选活跃引擎。
  //   cfg 写口同拍广播给两引擎（写幂等、CLEAR 会同时清空两引擎）；
  //   读口(cfg_rdata)/lookup 结果/wl_status 按活跃引擎 mux。
  //   LOOKUP_MODE 参数保留但不再决定综合（仅作文档语义参照）。
  // ============================================================

  // ---- 模式 0：顺序查找 ----
  wire [7:0]  seq_used_cnt;
  wire        seq_match, seq_done, seq_busy;
  wire [31:0] seq_cfg_rdata;
  mac_whitelist_seq #(
      .ENTRY_NUM(ENTRY_NUM),
      .ADDR_WIDTH(ADDR_WIDTH)
  ) u_seq (
      .clk           (clk),
      .reset_l       (reset_l),
      .lookup_req    (lookup_req),
      .lookup_mac    (lookup_mac),
      .lookup_match  (seq_match),
      .lookup_done   (seq_done),
      .lookup_busy   (seq_busy),
      .cfg_clk       (cfg_clk),
      .cfg_reset_l   (cfg_reset_l),
      .cfg_rlwh      (cfg_rlwh),
      .cfg_addr      (cfg_addr),
      .cfg_wdata     (cfg_wdata),
      .cfg_rdata     (seq_cfg_rdata),
      .whitelist_en  (whitelist_en),
      .default_pass  (default_pass),
      .wl_used_cnt   (seq_used_cnt)
  );

  // ---- 模式 2：布谷鸟哈希 ----
  wire [7:0]  ck_used_cnt;
  wire        ck_match, ck_done, ck_busy;
  wire [31:0] ck_cfg_rdata;
  mac_whitelist_cuckoo #(
      .BUCKET_NUM(64),
      .ADDR_WIDTH(6),
      .CAPACITY(96)
  ) u_cuckoo (
      .clk           (clk),
      .reset_l       (reset_l),
      .lookup_req    (lookup_req),
      .lookup_mac    (lookup_mac),
      .lookup_match  (ck_match),
      .lookup_done   (ck_done),
      .lookup_busy   (ck_busy),
      .cfg_clk       (cfg_clk),
      .cfg_reset_l   (cfg_reset_l),
      .cfg_rlwh      (cfg_rlwh),
      .cfg_addr      (cfg_addr),
      .cfg_wdata     (cfg_wdata),
      .cfg_rdata     (ck_cfg_rdata),
      .whitelist_en  (whitelist_en),
      .default_pass  (default_pass),
      .wl_used_cnt   (ck_used_cnt)
  );

  // ---- 运行时 mux ----
  wire mode2 = lookup_mode_sel;   // 1=布谷鸟(模式2), 0=顺序(模式0)
  assign lookup_match = mode2 ? ck_match : seq_match;
  assign lookup_done  = mode2 ? ck_done  : seq_done;
  assign lookup_busy  = mode2 ? ck_busy  : seq_busy;
  assign cfg_rdata    = mode2 ? ck_cfg_rdata : seq_cfg_rdata;
  // wl_status: [15:8]=活跃引擎 used_cnt, [7:0]=运行时模式(0 或 2，固件 wl_is_mode2 判读)
  assign wl_status    = { mode2 ? ck_used_cnt : seq_used_cnt,
                          6'b0, mode2 ? 2'b10 : 2'b00 };
endmodule
