// mac_whitelist_seq_my.v —— 我的模式 0 顺序查找实现（学习版，对着三图手写）
//
// 规则：
//   * 依据 exercise/MODE0_设计先行_三图.md 编写；写绿之前不看 rtl/ 正身与 exercise/ 旧版
//   * 全绿后再三方对照（我的版 / exercise 旧版 / rtl 正身），差异即教材
//   * 模块名必须是 mac_whitelist_seq（TB 按此名实例化）
//
// 核心预算（T7 硬断言）：T0 采样 req → done 可见 = 恰好 18 拍
//   1(采样起步) + 1(BRAM 同步读填充) + 15(CMP 比 entry0~14) + 1(DONE 比 entry15+出结果)
// 七坑位清单：三图文档第④节
//
// L1 验收命令：
//   cd /home/haitaoz/work/FPGA_Prj/fpga_webserver-wldev-v2
//   iverilog -g2012 -s tb_mac_whitelist_seq -o /tmp/tb_seq.vvp -I sim \
//       sim/define.sv sim/tb_mac_whitelist_seq.sv \
//       exercise/mac_whitelist_seq_my.v \
//       ../ip_common/rtl/dual_clock_simple_dual_port_ram.v
//   vvp /tmp/tb_seq.vvp      # 期望: ALL 8 TESTS PASSED

module mac_whitelist_seq #(
    parameter int ENTRY_NUM  = 16,
    parameter int ADDR_WIDTH = 4   // $clog2(ENTRY_NUM)
) (
    // ===== 查找口 (clk 125MHz, req/done 握手) =====
    input  clk,
    input  reset_l,
    input             lookup_req,
    input      [47:0] lookup_mac,
    output reg        lookup_match,
    output reg        lookup_done,
    output            lookup_busy,   // 纯组合 = state != IDLE

    // ===== RAMIF 配置口 (cfg_clk 50MHz, 电平敏感, 无握手) =====
    input         cfg_clk,
    input         cfg_reset_l,
    input         cfg_rlwh,    // 1=写, 0=读
    input  [11:0] cfg_addr,
    input  [31:0] cfg_wdata,
    output [31:0] cfg_rdata,   // 纯组合读 mux

    input  whitelist_en,
    input  default_pass,

    // wl_status 观测口（L1 TB 不接; L2/上板 0x301 需要）
    output wire [7:0] wl_used_cnt
);

  // ============================================================
  // 块 A —— 查找 FSM (clk 域) 【第一块，核心】
  //
  //   3 态: IDLE / COMPARE / DONE（图②）
  //   写完逐拍对图③的表检查：
  //   * T0 采样 req: cmp_index←0, match_found←0
  //   * T1: q_b 未就绪 → idx>0 才比（坑1）
  //   * T16: idx==15 → 转 DONE
  //   * T17 DONE 双职责: 比 entry15 + 寄存 match/done（坑2/3/4/5）
  //
  //   假设 BRAM 已存在，只用两根线（块 C 再实例化换上真端口）：
  wire [48:0]           bram_rd_data;   // q_b: {valid, mac[47:0]}，同步读 1 拍延迟
  wire [ADDR_WIDTH-1:0] bram_rd_addr;   // FSM 驱动

  // TODO(A): 状态编码 / state / cmp_index / match_found
  // TODO(A): match 输出语义（坑4）:
  //   en=1: match = match_found || default_pass || (末条 hit)
  //   en=0: match = default_pass
  // TODO(A): lookup_done 单拍脉冲, 与 match 同拍有效（坑5）; busy 纯组合（坑6）

  // ============================================================
  // 块 B —— 配置口 (cfg_clk 域) 【第二块】
  //
  //   寄存器映射 0x0~0xB（图①）
  //   写: 0x0 INDEX(bit31=1 连带删除该槽) / 0x1 MAC_H / 0x2 MAC_L / 0x3 WR / 0x4 DEL / 0x5 CLEAR
  //   电平敏感：cfg_rlwh 拉高期间每拍都解码，重复写必须安全 → 写脉冲打一拍
  //   valid_bits 每次写/删都维护（全设计的唯一真源）
  //   CLEAR = 命令触发 16 拍自动序列器，期间查找口照常可跑（坑7，L2 case600）

  // ============================================================
  // 块 C —— 存储与派生 【第三块】
  //
  //   * 主 BRAM: dual_clock_simple_dual_port_ram —— A口=cfg_clk 写, B口=clk 读
  //     （宏 `LARGER_RAM / `DEVICE_VENDOR 需 `include "define.sv"，编译命令已带 -I sim）
  //   * Shadow 寄存器堆: cfg_clk 单时钟写, 组合读（CPU 回读 0x6/7/8, 0 拍延迟）
  //   * free_idx: valid_bits 优先编码链, 全满 = 0xF
  //   * used_cnt: popcount 链 → wl_used_cnt 与 0xB
  //   * cfg_rdata 读 mux（读 0x6/7/8 时地址来自 cfg_idx）

endmodule
