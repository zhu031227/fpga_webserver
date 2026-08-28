// mac_whitelist_top — MAC whitelist top-level wrapper
//
// Instantiates the lookup engine based on LOOKUP_MODE parameter:
//   MODE 0: Sequential search (mac_whitelist_seq) — THIS IMPLEMENTATION
//   MODE 1: Binary search (mac_whitelist_bin) — reserved skeleton
//   MODE 2: Hash-based (mac_whitelist_hash) — reserved skeleton
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
    input default_pass
);

  generate
    if (LOOKUP_MODE == 0) begin : g_mode_seq
      mac_whitelist_seq #(
          .ENTRY_NUM(ENTRY_NUM),
          .ADDR_WIDTH(ADDR_WIDTH)
      ) u_lookup (
          .clk           (clk),
          .reset_l       (reset_l),
          .lookup_req    (lookup_req),
          .lookup_mac    (lookup_mac),
          .lookup_match  (lookup_match),
          .lookup_done   (lookup_done),
          .lookup_busy   (lookup_busy),
          .cfg_clk       (cfg_clk),
          .cfg_reset_l   (cfg_reset_l),
          .cfg_rlwh      (cfg_rlwh),
          .cfg_addr      (cfg_addr),
          .cfg_wdata     (cfg_wdata),
          .cfg_rdata     (cfg_rdata),
          .whitelist_en  (whitelist_en),
          .default_pass  (default_pass)
      );
    end else begin : g_mode_placeholder
      // Placeholder: tie off lookup outputs
      assign lookup_match = default_pass;
      assign lookup_done  = lookup_req;
      assign lookup_busy  = 1'b0;
      assign cfg_rdata    = 32'b0;
    end
  endgenerate
endmodule
