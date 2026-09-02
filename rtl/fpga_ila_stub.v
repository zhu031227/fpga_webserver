// fpga_ila_stub.v — 临时 stub，替代 fpga_ila 私有依赖（上板跑模式0用）
//
// fpga_ila 是纯 ILA 逻辑分析仪调试模块，不影响核心以太网/WebServer/白名单功能。
// 因团队 fpga_ila 私有仓库暂无法访问，用这两个 stub 让综合通过：
//   - soft_ila_top：查找/抓波核心，stub 成空置（reg_rdata 恒 0）
//   - ila_hub_top：调试传输 hub，stub 成空置（UART idle、core 总线恒 0）
//
// 注意：这只是上板验证的临时手段，验证完模式0后应恢复真正的 fpga_ila 依赖。
// 本文件不进主线。

// ---- soft_ila_top stub：参数化 probe 端口，空置 ----
module soft_ila_top #(
    parameter CORE_EN        = 0,
    parameter DATA_DEPTH     = 1024,
    parameter MAX_WINDOWS    = 1,
    parameter SAMPLE_HZ      = 50_000_000,
    parameter RST_ACTIVE_LOW = 1,
    parameter NUM_PROBES     = 1,
    parameter PROBE0_WIDTH   = 1,
    parameter PROBE1_WIDTH   = 1,
    parameter PROBE2_WIDTH   = 1,
    parameter PROBE3_WIDTH   = 1,
    parameter PROBE4_WIDTH   = 1,
    parameter PROBE5_WIDTH   = 1,
    parameter PROBE6_WIDTH   = 1,
    parameter PROBE7_WIDTH   = 1,
    parameter PROBE8_WIDTH   = 1,
    parameter PROBE9_WIDTH   = 1,
    parameter PROBE10_WIDTH  = 1,
    parameter PROBE11_WIDTH  = 1,
    parameter PROBE12_WIDTH  = 1,
    parameter PROBE13_WIDTH  = 1,
    parameter PROBE14_WIDTH  = 1,
    parameter EXT_TRIG_EN    = 1
) (
    input  sample_clk,
    input  rst_in,
    input  jtag_clk,
    input  [PROBE0_WIDTH-1:0]  probe0,
    input  [PROBE1_WIDTH-1:0]  probe1,
    input  [PROBE2_WIDTH-1:0]  probe2,
    input  [PROBE3_WIDTH-1:0]  probe3,
    input  [PROBE4_WIDTH-1:0]  probe4,
    input  [PROBE5_WIDTH-1:0]  probe5,
    input  [PROBE6_WIDTH-1:0]  probe6,
    input  [PROBE7_WIDTH-1:0]  probe7,
    input  [PROBE8_WIDTH-1:0]  probe8,
    input  [PROBE9_WIDTH-1:0]  probe9,
    input  [PROBE10_WIDTH-1:0] probe10,
    input  [PROBE11_WIDTH-1:0] probe11,
    input  [PROBE12_WIDTH-1:0] probe12,
    input  [PROBE13_WIDTH-1:0] probe13,
    input  [PROBE14_WIDTH-1:0] probe14,
    input  trigger_in,
    output trigger_out,
    output armed_out,
    input  reg_we,
    input  reg_re,
    input  [15:0] reg_addr,
    input  [31:0] reg_wdata,
    output [31:0] reg_rdata
);
    assign trigger_out = 1'b0;
    assign armed_out   = 1'b0;
    assign reg_rdata   = 32'b0;
endmodule

// ---- ila_hub_top stub：空置调试 hub ----
module ila_hub_top #(
    parameter [2:0]  TRANSPORT_EN = 3'b000,
    parameter        ILA_BAUD      = 115200,
    parameter [47:0] ETH_MAC       = 48'h0,
    parameter [31:0] ETH_IP        = 32'h0,
    parameter [15:0] ETH_PORT      = 16'h0,
    parameter        NUM_CORES     = 6,
    parameter        ILA_CLK_HZ    = 50_000_000
) (
    input  clk,
    input  rst,
    input  uart_rxd,
    output uart_txd,
    input        gmii_rx_clk,
    input  [7:0] gmii_rxd,
    input        gmii_rx_dv,
    input  [7:0] gmii_txd,
    input        gmii_tx_en,
    input  [NUM_CORES-1:0] core_reg_we,
    input        core_reg_re,
    input  [15:0] core_reg_addr,
    input  [31:0] core_reg_wdata,
    output [NUM_CORES*32-1:0] core_reg_rdata,
    output core_jtag_clk,
    output core_jtag_rst
);
    assign uart_txd      = 1'b1;                       // UART idle high
    assign core_reg_rdata = {(NUM_CORES*32){1'b0}};
    assign core_jtag_clk  = 1'b0;
    assign core_jtag_rst  = 1'b1;                      // 释放（rst 高有效）
endmodule
