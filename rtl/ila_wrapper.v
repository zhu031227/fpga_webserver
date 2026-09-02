// ila_wrapper — 参数化 ILA 封装（纯 Verilog，无需预生成 IP）
//
// 通过 parameter 动态配置：采样深度、probe 数量、每个 probe 位宽。
// 使用 (* mark_debug *) + (* ILA_DEPTH *) 属性标记探针信号，
// Vivado 综合后在网表中自动保留所有参数信息。
//
// ====================================================================
// 例化示例（每实例独立配置深度）
// ====================================================================
//
//   // 3 probe, depth=1024
//   ila_wrapper #(.NUM_PROBES(3), .DATA_DEPTH(1024),
//       .PROBE0_WIDTH(8), .PROBE1_WIDTH(10), .PROBE2_WIDTH(32)
//   ) u_ila_eth (.clk(clk), .probe0(a), .probe1(b), .probe2(c));
//
//   // 1 probe, depth=131072 (深采样)
//   ila_wrapper #(.NUM_PROBES(1), .DATA_DEPTH(131072), .PROBE0_WIDTH(128)
//   ) u_ila_deep (.clk(clk), .probe0({addr,data,ctrl}));
//
// ====================================================================
// 综合后自动设置各 ILA 深度（Vivado TCL 控制台执行一次）:
//   foreach net [get_nets -hier -filter {NAME =~ */dbg* && MARK_DEBUG}] {
//     set d [get_property ILA_DEPTH $net]
//     if {$d ne ""} { set_property C_DATA_DEPTH $d [get_debug_cores -of $net] }
//   }
// ====================================================================

module ila_wrapper #(
    parameter DATA_DEPTH = 1024,  // 采样深度: 1024/2048/4096/8192/16384/32768/65536/131072
    parameter NUM_PROBES = 1,
    parameter PROBE0_WIDTH = 1,
    parameter PROBE1_WIDTH = 1,
    parameter PROBE2_WIDTH = 1,
    parameter PROBE3_WIDTH = 1,
    parameter PROBE4_WIDTH = 1,
    parameter PROBE5_WIDTH = 1,
    parameter PROBE6_WIDTH = 1,
    parameter PROBE7_WIDTH = 1,
    parameter PROBE8_WIDTH = 1,
    parameter PROBE9_WIDTH = 1,
    parameter PROBE10_WIDTH = 1,
    parameter PROBE11_WIDTH = 1,
    parameter PROBE12_WIDTH = 1,
    parameter PROBE13_WIDTH = 1,
    parameter PROBE14_WIDTH = 1,
    parameter PROBE15_WIDTH = 1,
    parameter PROBE16_WIDTH = 1,
    parameter PROBE17_WIDTH = 1,
    parameter PROBE18_WIDTH = 1,
    parameter PROBE19_WIDTH = 1,
    parameter PROBE20_WIDTH = 1,
    parameter PROBE21_WIDTH = 1,
    parameter PROBE22_WIDTH = 1,
    parameter PROBE23_WIDTH = 1,
    parameter PROBE24_WIDTH = 1
) (
    input clk,

    input [PROBE0_WIDTH -1:0] probe0 = '0,
    input [PROBE1_WIDTH -1:0] probe1 = '0,
    input [PROBE2_WIDTH -1:0] probe2 = '0,
    input [PROBE3_WIDTH -1:0] probe3 = '0,
    input [PROBE4_WIDTH -1:0] probe4 = '0,
    input [PROBE5_WIDTH -1:0] probe5 = '0,
    input [PROBE6_WIDTH -1:0] probe6 = '0,
    input [PROBE7_WIDTH -1:0] probe7 = '0,
    input [PROBE8_WIDTH -1:0] probe8 = '0,
    input [PROBE9_WIDTH -1:0] probe9 = '0,
    input [PROBE10_WIDTH-1:0] probe10 = '0,
    input [PROBE11_WIDTH-1:0] probe11 = '0,
    input [PROBE12_WIDTH-1:0] probe12 = '0,
    input [PROBE13_WIDTH-1:0] probe13 = '0,
    input [PROBE14_WIDTH-1:0] probe14 = '0,
    input [PROBE15_WIDTH-1:0] probe15 = '0,
    input [PROBE16_WIDTH-1:0] probe16 = '0,
    input [PROBE17_WIDTH-1:0] probe17 = '0,
    input [PROBE18_WIDTH-1:0] probe18 = '0,
    input [PROBE19_WIDTH-1:0] probe19 = '0,
    input [PROBE20_WIDTH-1:0] probe20 = '0,
    input [PROBE21_WIDTH-1:0] probe21 = '0,
    input [PROBE22_WIDTH-1:0] probe22 = '0,
    input [PROBE23_WIDTH-1:0] probe23 = '0,
    input [PROBE24_WIDTH-1:0] probe24 = '0
);

  // ============================================================
  // 每个 probe 独立 generate 块：
  //   mark_debug → Vivado 综合后映射到 ILA probe
  //   ILA_DEPTH  → 用户属性 = DATA_DEPTH 参数值（Verilog-2001 合法）
  //   dont_touch → 防止综合优化掉
  // ============================================================

  // ============================================================
  // ILA clock reference (each instance provides its clock to ILA)
  // ============================================================
  (* mark_debug = "true" *) (* ILA_IS_CLK = 1 *) wire ila_clk;
  assign ila_clk = clk;

  generate
    if (NUM_PROBES > 0) begin : g_p0
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE0_WIDTH-1:0] dbg0;
      assign dbg0 = probe0;
    end
    if (NUM_PROBES > 1) begin : g_p1
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE1_WIDTH-1:0] dbg1;
      assign dbg1 = probe1;
    end
    if (NUM_PROBES > 2) begin : g_p2
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE2_WIDTH-1:0] dbg2;
      assign dbg2 = probe2;
    end
    if (NUM_PROBES > 3) begin : g_p3
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE3_WIDTH-1:0] dbg3;
      assign dbg3 = probe3;
    end
    if (NUM_PROBES > 4) begin : g_p4
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE4_WIDTH-1:0] dbg4;
      assign dbg4 = probe4;
    end
    if (NUM_PROBES > 5) begin : g_p5
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE5_WIDTH-1:0] dbg5;
      assign dbg5 = probe5;
    end
    if (NUM_PROBES > 6) begin : g_p6
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE6_WIDTH-1:0] dbg6;
      assign dbg6 = probe6;
    end
    if (NUM_PROBES > 7) begin : g_p7
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE7_WIDTH-1:0] dbg7;
      assign dbg7 = probe7;
    end
    if (NUM_PROBES > 8) begin : g_p8
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE8_WIDTH-1:0] dbg8;
      assign dbg8 = probe8;
    end
    if (NUM_PROBES > 9) begin : g_p9
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE9_WIDTH-1:0] dbg9;
      assign dbg9 = probe9;
    end
    if (NUM_PROBES > 10) begin : g_p10
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE10_WIDTH-1:0] dbg10;
      assign dbg10 = probe10;
    end
    if (NUM_PROBES > 11) begin : g_p11
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE11_WIDTH-1:0] dbg11;
      assign dbg11 = probe11;
    end
    if (NUM_PROBES > 12) begin : g_p12
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE12_WIDTH-1:0] dbg12;
      assign dbg12 = probe12;
    end
    if (NUM_PROBES > 13) begin : g_p13
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE13_WIDTH-1:0] dbg13;
      assign dbg13 = probe13;
    end
    if (NUM_PROBES > 14) begin : g_p14
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE14_WIDTH-1:0] dbg14;
      assign dbg14 = probe14;
    end
    if (NUM_PROBES > 15) begin : g_p15
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE15_WIDTH-1:0] dbg15;
      assign dbg15 = probe15;
    end
    if (NUM_PROBES > 16) begin : g_p16
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE16_WIDTH-1:0] dbg16;
      assign dbg16 = probe16;
    end
    if (NUM_PROBES > 17) begin : g_p17
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE17_WIDTH-1:0] dbg17;
      assign dbg17 = probe17;
    end
    if (NUM_PROBES > 18) begin : g_p18
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE18_WIDTH-1:0] dbg18;
      assign dbg18 = probe18;
    end
    if (NUM_PROBES > 19) begin : g_p19
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE19_WIDTH-1:0] dbg19;
      assign dbg19 = probe19;
    end
    if (NUM_PROBES > 20) begin : g_p20
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE20_WIDTH-1:0] dbg20;
      assign dbg20 = probe20;
    end
    if (NUM_PROBES > 21) begin : g_p21
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE21_WIDTH-1:0] dbg21;
      assign dbg21 = probe21;
    end
    if (NUM_PROBES > 22) begin : g_p22
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE22_WIDTH-1:0] dbg22;
      assign dbg22 = probe22;
    end
    if (NUM_PROBES > 23) begin : g_p23
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE23_WIDTH-1:0] dbg23;
      assign dbg23 = probe23;
    end
    if (NUM_PROBES > 24) begin : g_p24
      (* mark_debug = "true" *) (* ILA_DEPTH = DATA_DEPTH *) (* dont_touch = "true" *)
      wire [PROBE24_WIDTH-1:0] dbg24;
      assign dbg24 = probe24;
    end
  endgenerate
endmodule
