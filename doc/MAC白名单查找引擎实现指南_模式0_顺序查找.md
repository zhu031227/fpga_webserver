# MAC 白名单查找引擎实现指南 · 模式 0 —— BRAM 顺序查找（从零实现）

> 文档编号：ED003R01-A
> 日期：2026-08-28
> 适用工程：`fpga_webserver-whitelist_dev`（whitelist_dev 分支）
> 平台：Xilinx XC7A35T-FGG484-2（ACX750 开发板）
> 性质：**从零实现指南**。仓库中已有的 `rtl/mac_whitelist_seq.v` 是本模式的**参考答案**（已上板验证跑通），本文按"假设它不存在"的完整流程编写，每步末尾附「参考答案对照」，适合边写边对照自查。
> 姐妹篇：《MAC白名单查找引擎实现指南_模式1_二分查找.md》（前置条件：本文档全部完成）

---

## 第 0 章 文档定位与总路线

### 0.1 本文档覆盖什么

在现有 fpga_webserver 框架上，**从零实现** MAC 白名单查找引擎的模式 0（顺序查找）：

- RTL：新建 `mac_whitelist_seq.v`（存储 + 配置译码 + 查找 FSM）
- 集成：`mac_whitelist_top.v` 模式分发、`webserver_wrapper.v` 例化（集成层工程已就位，本文教你确认每一根连线）
- 软件：`c/whitelist.c` C 驱动（影子表 + SubBus 操作）
- 验证：单元仿真（8 用例）→ 板级验证（管理面 + 数据面）

### 0.2 两阶段路线图（与模式 1 的关系）

| 阶段 | 内容 | 交付物 | 验收 |
|------|------|--------|------|
| **本文：阶段一** | 模式 0 顺序查找 | `mac_whitelist_seq.v` + C 驱动 + tb | 仿真 8 用例过；板上 Web 增删 MAC，过滤行为正确；tag `mode0-verified` |
| 阶段二（姐妹篇） | 模式 1 二分查找 | `mac_whitelist_bin.v` + C 有序化改造 + 对拍 tb | 与模式 0 对拍全过；切 MODE=1 板上行为一致，查找 18 拍→10 拍 |

**为什么必须先做模式 0**：模式 1 完全复用模式 0 的配置通路、存储结构、寄存器表和上层集成，只换查找算法核心；且模式 1 的仿真验证需要模式 0 作为对照基准。跳过模式 0 直接做模式 1 = 没有地基也没有参照。

### 0.3 白名单在整机中的位置（先建立全局图）

```
                        ┌──────────────────────── FPGA ────────────────────────┐
  eth0 RGMII(管理口)    │                                                       │
  ─────────────────────► rgmii2gmii ─► gmii2mac ─┐                             │
  ◄─────────────────────                (125MHz) │ mac0 口                      │
                                                 ▼                             │
                                    ┌─────────────────────┐                    │
                                    │  cpu_channel_tri     │                    │
                    eth1 SFP(LAN)   │                     │    eth2 SFP(WAN)   │
  用户PC ──────► SFP1 ──────────────►│ mac1 RX──►提取SrcMAC │                    │
  (白名单过滤方向)                   │    │                │──► mac2 TX 转发    │
  ◄────────────── SFP2 ◄────────────│    ▼                │   (过滤后的包)      │
                    (回程透传)       │ whitelist_lookup ○──┼──► mac1 TX (透传)  │
                                    │  结果门控 wpkt_push  │                    │
                                    └──────────┬──────────┘                    │
                                               │ cfg 口 (50MHz)                │
                          ┌────────────────────▼───────────────────┐           │
                          │ mac_whitelist_top (LOOKUP_MODE=0)       │           │
                          │   ├─ 查找FSM (125MHz, 读BRAM)           │           │
                          │   └─ 配置译码 (50MHz, SubBus寄存器)      │           │
                          └────────────────────▲───────────────────┘           │
                                               │ RAMIF (12bit addr)            │
                          ┌────────────────────┴───────────────────┐           │
                          │ reg_webserver: SubBus 0x5000~0x5FFF     │           │
                          │   wl_ctrl(0x300) enable/default_pass    │           │
                          └────────────────────▲───────────────────┘           │
                                               │ LCPU 总线 (0x80005000)        │
                                     RISC-V 固件 whitelist.c (sw 影子表)        │
                                               │                              │
                                     SPI Flash 0xC20000 (持久化) ◄─────────────┘
```

**一句话数据流**：eth1 收到包 → 硬件提取源 MAC（帧字节 6~13）→ 发 `lookup_req` → 查找引擎查 BRAM → `lookup_match` 回来 → `cpu_channel_tri` 用它门控这个包的 `wpkt_push`（放行=转发到 eth2，拦截=丢弃并计数）。**CPU 不参与逐包过滤**，只在网页操作时通过 SubBus 配置白名单表。

---

## 第 1 章 现有框架关键机制（动笔前必须吃透）

> 本章的机制**已经存在于工程中**，你不需要重写，但每一条都直接影响你 RTL 代码的写法。实现前逐节确认理解。

### 1.1 数据通路：查找在哪里被触发、结果如何生效

文件：`rtl/cpu_channel_tri.v`（三端口 L2 桥接通道，125MHz 域）。摘录关键逻辑（174~248、306~307 行）：

```text
① 提取源 MAC（每包一次）：
   mac1_rx_en && !mac1_header_done 期间逐字节移位收集字节 6~11
   → mac1_src_mac[47:0]；收到字节 13 时 mac1_header_done=1
   （帧格式：字节 0~5 目的 MAC，6~11 源 MAC，12~13 类型）

② 触发查找：
   if (mac1_header_done && !wl_lookup_pending && !wl_lookup_busy)
       → wl_lookup_req 拉高一拍，wl_lookup_mac ← mac1_src_mac

③ 结果捕获：
   if (wl_lookup_done) → wl_result_match ← wl_lookup_match
   （新包 SOP 到来时 wl_result_valid 清零）

④ 门控转发（过滤的真正执行点，306 行）：
   assign eth1_fwd_wpkt_push = eth1_fwd_wpkt_push_raw &&
       (wl_result_match || (!whitelist_en && default_pass));
```

**四个关键理解**：

1. 包数据在查找进行期间（144ns）**已经整包写入 ram2pktfifo_int 缓冲**——查表不会丢字节，只推迟转发决策；
2. 过滤的实现方式是"**push 门控**"：不 push 的包留在缓冲里自然作废，同时 `eth1_rx_drop_cnt++`（→ `debug_ro_1`，地址 0x21）；
3. `eth2 → eth1` 回程**完全不经过白名单**（无条件透传）；
4. `whitelist_en=0` 时查找结果被无视，由 `default_pass` 决定全断(0)/全放(1)——这个兜底逻辑在 `cpu_channel_tri` 的门控表达式里，你的 RTL 里也要实现同样语义（见步骤 6）。

### 1.2 配置通路：CPU 怎么读写白名单寄存器

```text
C 固件 (50MHz)                       RTL (50MHz cfg_clk 域)
──────────────                       ─────────────────────
LCPU_REG32_WRITE(0x5000+off, data)   reg_webserver.v (1197~1207 行)：
  即 CPU 写物理地址                      address∈[0x5000,0x5FFF] 段命中
  0x80000000 + (0x5000+off)*4            → SUBBUS_mac_whitelist_* 打拍寄存
      │                              ramintf #(.AddrBits(12)) RAMIF_mac_whitelist：
      ▼                                  Ram_RlWh = !rhwl（SubBus 写时=1）
webserver_wrapper (1033/1152 行)：        Ram_Addr = address[11:0]
  wl_ram_rlwh / wl_ram_addr ─────────► mac_whitelist_top.cfg_rlwh / cfg_addr / cfg_wdata
```

**三个必须遵守的特性**（违反任何一条都会出诡异 bug）：

| # | 特性 | 原因 | 对你代码的要求 |
|---|------|------|--------------|
| 1 | **电平敏感写、无 req/ack 握手** | ramintf 直通，SubBus 写事务期间 `cfg_rlwh=1` 持续约 3 拍，同一笔写会被译码多次 | 所有写动作必须**幂等**：寄存器加载重复无害；WR/DEL 触发用"`*_r` 暂存寄存器 1 拍脉冲"结构（见步骤 4），不要设计边沿检测 |
| 2 | **C 侧每笔写后必须 flush** | SubBus 打拍链路上前一笔可能未落地，连续写会互相覆盖 | `subbus_write()` 写后读一次 `0x500A`（MAX_ENTRIES，恒定的安全地址）再返回；C 驱动所有 HW 写必须走它 |
| 3 | **BRAM 与 shadow_rf 双副本同步写** | BRAM 同步读 1 拍延迟，而 ramintf 读采样窗口只有 3 拍，容不下 → CPU 回读必须走组合逻辑的 shadow_rf | 每条写路径都要**同时**写 BRAM（给 125MHz 查找用）和 shadow_rf（给 CPU 回读用），漏一边就会出现"查找生效但网页回读不对"（或反之） |

### 1.3 时钟域与复位

| 时钟 | 频率 | 域内逻辑 | 跨域手段 |
|------|------|---------|---------|
| `clk` | 125MHz | 查找 FSM、BRAM 读口 | 查找请求/结果不出域（cpu_channel_tri 与白名单同域直连） |
| `cfg_clk` | 50MHz | 配置译码、BRAM 写口、shadow_rf | SubBus 链路天然同步；ramintf 已处理握手 |
| — | — | `whitelist_en / default_pass`（wl_ctrl 2bit，reg_webserver 0x300） | wrapper 里 `cdc_bus_sync MODE=1`（970~985 行，已存在） |
| — | — | 手动触发 `debug_wc_0_ind` 脉冲 | wrapper 里 `pulse_clock_region_pass`（1039~1045 行，已存在） |

复位：`reset_l` 低有效、异步 assert；125MHz 域用它，50MHz 域用 `cfg_reset_l`（wrapper 里同源）。**BRAM 和 shadow_rf 不做复位**（BRAM 无法异步复位；FPGA 上电存储器即零）。

### 1.4 存储结构：49-bit 条目 + 双副本 + 辅助位

```
每条目 49 bit：{ valid[48], mac[47:0] }
                    │
    ┌───────────────┴───────────────┐
    ▼                               ▼
主存储 BRAM                      副本 shadow_rf
dual_clock_simple_dual_port_ram   16×49 寄存器阵列
  A口: cfg_clk 写（CPU 配置）       组合逻辑读（零延迟）
  B口: clk 读（查找，1拍延迟）       仅服务 CPU 回读 0x06/07/08
    │
    └─ valid_bits[15:0] 独立寄存器
         ├─ free_idx：generate 优先编码器链（首个空闲槽）
         └─ used_cnt：generate 加法器链（popcount）
```

BRAM 用 ip_common 的 `dual_clock_simple_dual_port_ram`，参数 `data_width(49), addr_width(4), depth(16), block_ram_size(32), ram_type(`LARGER_RAM), vendor(`DEVICE_VENDOR)`——宏来自 `define.sv`，Xilinx 下综合为 BlockRAM。

### 1.5 寄存器表（SubBus 基址 0x5000，偏移 = cfg_addr[3:0]）

| 偏移 | 名称 | 类型 | 位宽 | 写入行为 / 读出内容 |
|-----|------|------|------|---------------------|
| 0x00 | INDEX | RW | [3:0] | 写：加载 cfg_idx；**wdata[31]=1 时附带删除该索引条目**（本工程扩展，省一笔写） |
| 0x01 | MAC_H | RW | [31:0] | 写：暂存 cfg_mac[47:16]；读：返回 cfg_mac[47:16] |
| 0x02 | MAC_L | RW | [15:0] | 写：暂存 cfg_mac[15:0]；读：返回 cfg_mac[15:0] |
| 0x03 | WR | WC | — | 触发：{1'b1, cfg_mac} 写入 BRAM[cfg_idx] + shadow_rf[cfg_idx]，valid 置 1 |
| 0x04 | DEL | WC | — | 触发：49'b0 写入两存储，valid 清 0 |
| 0x05 | CLEAR | WC | — | 启动清除序列器（16 拍逐条清全表） |
| 0x06 | RD_MAC_H | RO | [31:0] | 读 shadow_rf[cfg_idx][47:16] |
| 0x07 | RD_MAC_L | RO | [15:0] | 读 shadow_rf[cfg_idx][15:0] |
| 0x08 | RD_VALID | RO | [0] | 读 shadow_rf[cfg_idx][48] |
| 0x09 | FREE_IDX | RO | [3:0] | 首个空闲索引（全满 = 4'hF） |
| 0x0A | MAX_ENTRIES | RO | [7:0] | 恒 = 16（**C 侧 flush 读固定用这个地址**） |
| 0x0B | USED_CNT | RO | [7:0] | 有效条目数 |

> 与设计文档 V4（`doc/MAC_Whitelist_Design_Plan.md`）的差异：V4 规划的 0x0C~0x0F 命中/丢弃 64bit 计数**未实现**。丢弃计数已由 `cpu_channel_tri` 统计并映射到 `debug_ro_1`(0x21)。可作为完成后的扩展练习。

### 1.6 C 驱动现状（`c/whitelist.c`，346 行）

| 函数 | 职责 |
|------|------|
| `subbus_write(base, off, data)` | 写 + 读 0x500A flush（1.2 特性 2 的落实，**所有 HW 写必须走它**） |
| `sw_wl_valid[16] / sw_wl_mac[16][6] / sw_wl_count` | 软件影子表——Web 显示、Flash 持久化的权威数据源 |
| `whitelist_add/delete/clear_all` | 影子表 + HW SubBus 双写 |
| `whitelist_hw_read_entry(i)` | 经 0x06/07/08 读 HW 真实内容（`/api/wl/list`、`/api/wl/hwlist` 用） |
| `whitelist_hw_diag(buf,size)` | 硬件诊断 JSON（寄存器快照 + 删除功能自测） |
| `whitelist_get/apply_snapshot` | 与 `flash_cfg.c`（0xC20000 持久化）的保存/恢复接口 |

### 1.7 构建与烧录链（改完代码怎么验证）

```bash
# RTL 改动 → bitstream（约 20~60 分钟）：
cd build_xilinx_xc7a35tfgg484 && ./build_fpga.sh <版本号4位hex>

# C 改动 → 固件（约 1 分钟）：
cd c_build && make PLATFORM=xilinx riscv_reset_addr=0xf TCL_BASE=0x8000

# 烧录 + 加载（顺序执行）：
openFPGALoader -c digilent_hs2 <工程目录>/<名字>.bit
vivado -mode batch -source load_fw.tcl     # JTAG-AXI 执行 tcl/InstructRAM.tcl
```

**调试黄金法则**：只改 C → 重跑 make + load_fw（1 分钟）；改了 RTL → 必须重编 bitstream（半小时起）。所以 RTL 阶段尽量用仿真把问题清干净，别靠上板试错。

---

## 第 2 章 从零实现八步

> 每步格式：目标 → 详细做法 → 验证标准 → 参考答案对照。

### 步骤 1：需求与规格定义

**目标**：把需求翻译成可实现、可验证的规格，重点是时序可行性论证。

1. 容量：`ENTRY_NUM=16`，`ADDR_WIDTH=$clog2(16)=4`；
2. 条目格式：49bit = {valid, mac[47:0]}；
3. **时序预算推导**（顺序查找可行性的核心，必须能口算复述）：

```
千兆网最小帧间隔 = (64B 最小帧 + 8B 前导 + 12B IFG) × 8ns/字节
                 = 84 × 8 = 672ns

顺序查找全表耗时 = IDLE(1拍) + COMPARE(16拍) + DONE(1拍) = 18 拍
                 = 18 × 8ns(125MHz) = 144ns

144ns ≪ 672ns  →  查完一条包的间隙里下一个请求还没到
且触发条件有 !wl_lookup_busy 兜底  →  线速不丢包 ✓
```

4. 关闭行为：`whitelist_en=0` → 不查表，match 输出恒为 `default_pass`；
5. 表项语义：index 是**物理槽位**（无顺序要求）——模式 0 与模式 1 的本质区别之一。

**验证标准**：以上 5 条写成模块头部注释（参考答案 1~7 行）。

### 步骤 2：接口与寄存器表设计

**目标**：定对外契约（一旦定下，模式 1 沿用）。

端口四组（完整代码）：

```verilog
module mac_whitelist_seq #(
    parameter int ENTRY_NUM  = 16,
    parameter int ADDR_WIDTH = 4      // $clog2(ENTRY_NUM)
) (
    input  clk,                        // 125MHz 查找域
    input  reset_l,
    // ── 查找口（与 cpu_channel_tri 直连，同域）──
    input             lookup_req,      // 1 拍脉冲
    input      [47:0] lookup_mac,
    output reg        lookup_match,    // done 拍有效
    output reg        lookup_done,     // 1 拍脉冲
    output            lookup_busy,     // 电平：state != IDLE
    // ── 配置口（50MHz，接 ramintf，电平敏感无握手）──
    input             cfg_clk,
    input             cfg_reset_l,
    input             cfg_rlwh,        // 1=写 0=读
    input      [11:0] cfg_addr,        // 译码用 [3:0]
    input      [31:0] cfg_wdata,
    output     [31:0] cfg_rdata,       // 组合读 mux，无延迟
    // ── 全局控制（125MHz 域，上游 CDC 已做）──
    input             whitelist_en,
    input             default_pass
);
```

寄存器表：采用 1.5 节（已定稿）。

**验证标准**：对照 wrapper 1138~1158 行的例化，四组端口逐根能说出连到哪。

### 步骤 3：模块骨架与存储实例化

**目标**：文件立起来、存储结构就位（不含查找逻辑），先保证编译干净。

需要声明的信号（按功能分组）：

```verilog
// 查找 FSM
reg [1:0]               state;         // S_IDLE/S_COMPARE/S_DONE
reg [ADDR_WIDTH-1:0]    cmp_index;
reg                     match_found;
// 配置暂存
reg [ADDR_WIDTH-1:0]    cfg_idx;
reg [47:0]              cfg_mac;
// 辅助
reg [ENTRY_NUM-1:0]     valid_bits;
reg                     clear_active;
reg [ADDR_WIDTH-1:0]    clear_cnt;
// 写请求暂存（1 拍脉冲语义，见 1.2 特性 1）
reg                     bram_wr_en_r;   reg [ADDR_WIDTH-1:0] bram_wr_addr_r;  reg [48:0] bram_wr_data_r;
reg                     sh_wr_en_r;     reg [ADDR_WIDTH-1:0] sh_wr_addr_r;    reg [48:0] sh_wr_data_r;
// shadow_rf 副本
reg [48:0]              shadow_rf [0:ENTRY_NUM-1];
```

实例化 BRAM（写口 A=cfg_clk，读口 B=clk）：

```verilog
dual_clock_simple_dual_port_ram #(
    .data_width(49), .addr_width(ADDR_WIDTH), .depth(ENTRY_NUM),
    .block_ram_size(32), .ram_type(`LARGER_RAM), .vendor(`DEVICE_VENDOR)
) u_bram (
    .clock_a(cfg_clk), .wren_a(bram_wr_en), .data_a(bram_wr_data), .address_a(bram_wr_addr),
    .clock_b(clk),     .address_b(bram_rd_addr), .q_b(bram_rd_data)
);
```

**写仲裁约定**：普通写先打入 `*_r` 暂存寄存器（下一拍有效），再与 CLEAR 序列器输出 OR-mux 后接 BRAM/shadow 写口——CLEAR 期间普通写让位且不冲突：

```verilog
assign bram_wr_en   = clear_active ? 1'b1        : bram_wr_en_r;
assign bram_wr_addr = clear_active ? clear_cnt   : bram_wr_addr_r;
assign bram_wr_data = clear_active ? 49'b0       : bram_wr_data_r;
// shadow 侧三行同理
```

shadow_rf 写读：

```verilog
always @(posedge cfg_clk) if (sh_wr_en) shadow_rf[sh_wr_addr] <= sh_wr_data;
assign sh_rd_data = shadow_rf[sh_rd_addr];   // 组合读，零延迟
```

**验证标准**：`iverilog -o /dev/null <所有依赖文件>` 编译 0 error；无 implicit wire 警告。

### 步骤 4：配置通路编码（50MHz 域）

**目标**：实现 1.5 节寄存器表的全部写入行为。

一个 `always @(posedge cfg_clk or negedge cfg_reset_l)` 块，结构：

```verilog
if (!cfg_reset_l) begin
    cfg_idx<=0; cfg_mac<=0; valid_bits<=0; clear_active<=0; clear_cnt<=0;
    bram_wr_en_r<=0; sh_wr_en_r<=0;
end else begin
    bram_wr_en_r <= 1'b0;          // 默认单拍脉冲
    sh_wr_en_r   <= 1'b0;

    // ── CLEAR 序列器：每拍清一个地址，16 拍自动停（计数器实现，别用状态机）──
    if (clear_active) begin
        bram_wr_en_r<=1; bram_wr_addr_r<=clear_cnt; bram_wr_data_r<=49'b0;
        sh_wr_en_r<=1;   sh_wr_addr_r<=clear_cnt;   sh_wr_data_r<=49'b0;
        if (clear_cnt == ENTRY_NUM-1) begin clear_active<=0; valid_bits<=0; end
        else clear_cnt <= clear_cnt + 1;
    end

    // ── 电平敏感写译码 ──
    if (cfg_rlwh) case (cfg_addr[3:0])
        4'h0: begin
            cfg_idx <= cfg_wdata[ADDR_WIDTH-1:0];
            if (cfg_wdata[31]) begin          // bit31 附带删除（一笔完成选+删）
                bram_wr_en_r<=1; bram_wr_addr_r<=cfg_wdata[3:0]; bram_wr_data_r<=49'b0;
                sh_wr_en_r<=1;   sh_wr_addr_r<=cfg_wdata[3:0];   sh_wr_data_r<=49'b0;
                valid_bits[cfg_wdata[ADDR_WIDTH-1:0]] <= 1'b0;
            end
        end
        4'h1: cfg_mac[47:16] <= cfg_wdata[31:0];
        4'h2: cfg_mac[15:0]  <= cfg_wdata[15:0];
        4'h3: begin                          // WR：双副本同步写（1.2 特性 3）
            bram_wr_en_r<=1; bram_wr_addr_r<=cfg_idx; bram_wr_data_r<={1'b1,cfg_mac};
            sh_wr_en_r<=1;   sh_wr_addr_r<=cfg_idx;   sh_wr_data_r<={1'b1,cfg_mac};
            valid_bits[cfg_idx]<=1'b1;
        end
        4'h4: begin                          // DEL：双副本清零
            bram_wr_en_r<=1; bram_wr_addr_r<=cfg_idx; bram_wr_data_r<=49'b0;
            sh_wr_en_r<=1;   sh_wr_addr_r<=cfg_idx;   sh_wr_data_r<=49'b0;
            valid_bits[cfg_idx]<=1'b0;
        end
        4'h5: begin clear_active<=1'b1; clear_cnt<=0; end   // CLEAR：启动序列器
        default: ;
    endcase
end
```

**要点回顾**：`*_r` 脉冲寄存器保证"电平采样多次=执行一次"；WR/DEL 写双副本；CLEAR 是计数器不是状态机。

**验证标准**：仿真写 INDEX→MAC_H→MAC_L→WR 后读 0x06/07/08 回读正确；DEL 后 0x08=0；CLEAR 后 USED_CNT=0。

### 步骤 5：辅助组合逻辑

**目标**：free_idx、used_cnt、读 mux、shadow 读地址。

```verilog
// free_idx：generate 级联优先编码器（高→低传递，!valid 处截住）
wire [ADDR_WIDTH-1:0] free_idx_stage [ENTRY_NUM:0];
assign free_idx_stage[ENTRY_NUM] = {ADDR_WIDTH{1'b1}};         // 全满默认
genvar gi;
generate for (gi = ENTRY_NUM-1; gi >= 0; gi = gi-1) begin : g_free
    assign free_idx_stage[gi] = !valid_bits[gi] ? gi[ADDR_WIDTH-1:0]
                                                : free_idx_stage[gi+1];
end endgenerate
wire [ADDR_WIDTH-1:0] free_idx_comb = free_idx_stage[0];
// ★ 不要写带退出条件的 for 循环——Vivado 综合不支持运行期 break 语义

// used_cnt：generate 加法器链 popcount
wire [7:0] used_cnt_partial [ENTRY_NUM:0];
assign used_cnt_partial[0] = 8'd0;
generate for (gi = 0; gi < ENTRY_NUM; gi = gi+1) begin : g_pop
    assign used_cnt_partial[gi+1] = used_cnt_partial[gi] + {7'b0, valid_bits[gi]};
end endgenerate
wire [7:0] used_cnt_comb = used_cnt_partial[ENTRY_NUM];

// 读 mux：级联三元（读也是电平组合的，1.2 特性 1）
wire [3:0] rd_reg = cfg_addr[3:0];
assign cfg_rdata =
    (!cfg_rlwh && rd_reg==4'h0) ? {28'b0, cfg_idx}              :
    (!cfg_rlwh && rd_reg==4'h1) ? cfg_mac[47:16]                :
    (!cfg_rlwh && rd_reg==4'h2) ? {16'b0, cfg_mac[15:0]}        :
    (!cfg_rlwh && rd_reg==4'h6) ? sh_rd_data[47:16]             :
    (!cfg_rlwh && rd_reg==4'h7) ? {16'b0, sh_rd_data[15:0]}     :
    (!cfg_rlwh && rd_reg==4'h8) ? {31'b0, sh_rd_data[48]}       :
    (!cfg_rlwh && rd_reg==4'h9) ? {28'b0, free_idx_comb}        :
    (!cfg_rlwh && rd_reg==4'hA) ? ENTRY_NUM[31:0]               :
    (!cfg_rlwh && rd_reg==4'hB) ? {24'b0, used_cnt_comb}        :
    32'b0;

// shadow 读地址：仅读 0x06/07/08 时指向 cfg_idx，其余指 0（防误读）
assign sh_rd_addr = (!cfg_rlwh && (rd_reg==4'h6||rd_reg==4'h7||rd_reg==4'h8))
                    ? cfg_idx : {ADDR_WIDTH{1'b0}};
```

**验证标准**：加 3 条后读 0x09=下一个空槽、0x0B=3；清空后 0x09=0、0x0B=0。

### 步骤 6：查找 FSM（模式 0 核心，125MHz 域）

**目标**：三态 FSM 顺序比对，重点处理 BRAM 1 拍读延迟。

```verilog
localparam S_IDLE=2'd0, S_COMPARE=2'd1, S_DONE=2'd2;

assign bram_rd_addr = (state==S_COMPARE) ? cmp_index : {ADDR_WIDTH{1'b0}};

always @(posedge clk or negedge reset_l) begin
    if (!reset_l) begin
        state<=S_IDLE; cmp_index<=0; match_found<=0;
        lookup_match<=0; lookup_done<=0;
    end else begin
        lookup_done <= 1'b0;                                  // done 默认单拍
        case (state)
        S_IDLE: if (lookup_req) begin
                    state<=S_COMPARE; cmp_index<=0; match_found<=0;
                end
        S_COMPARE: begin
            // BRAM 1 拍延迟：本拍比较的是上一拍地址的数据
            // → cmp_index>0 才开始比；最后一条(idx=15)的数据在 S_DONE 到达
            if (cmp_index > 0 && bram_rd_valid && (bram_rd_mac == lookup_mac))
                match_found <= 1'b1;
            if (cmp_index == ENTRY_NUM-1) state <= S_DONE;
            else cmp_index <= cmp_index + 1;
        end
        S_DONE: begin
            // 补上最后一条(idx=15)的比较，再锁存
            if (bram_rd_valid && (bram_rd_mac == lookup_mac))
                match_found <= 1'b1;
            lookup_match <= whitelist_en ? match_found : default_pass;
            lookup_done  <= 1'b1;
            state <= S_IDLE;
        end
        default: state <= S_IDLE;
        endcase
    end
end
assign lookup_busy = (state != S_IDLE);
```

**逐拍时序表**（照着画波形核对，这是最容易写错的地方）：

```
拍:    0      1      2      3     ...   16      17
状态:  IDLE   CMP    CMP    CMP   ...   CMP     DONE
地址:  -      发0    发1    发2   ...   发15     -
数据:  -      -      d0     d1    ...   d14     d15
比较:  -      -      cmp0   cmp1  ...   cmp14   cmp15 ← 补比
                                     done 拍=17 → req到done共18拍 ✓
```

**验证标准**：表首/表尾/中间三条 MAC 命中；不存在 MAC miss；done 宽 1 拍；en=0 时 match=default_pass。

### 步骤 7：单元仿真

**目标**：8 用例全过。新建 `sim/tb_mac_whitelist_seq.sv`，独立例化 DUT（不需要整个 SoC），50MHz cfg_clk + 125MHz clk 各起一个。

| # | 用例 | 激励 | 期望 | 断言点 |
|---|------|------|------|--------|
| 1 | 写 3 条（表首 idx0、中间 idx7、表尾 idx15）→ 逐条查找 | SubBus 写序列 + lookup_req | 全命中 | done 拍 match=1 |
| 2 | 查未添加 MAC | lookup_req | miss | match=0 |
| 3 | DEL idx7 → 再查 idx7 / idx0 | 两步删除 | idx7 miss，idx0 仍 hit | — |
| 4 | CLEAR → 查任意 + 读 USED_CNT | 0x05 写 1，等 16+ 拍 | miss，0x0B=0 | — |
| 5 | 加满 16 条 | 循环写 | 0x09=0xF（表满） | — |
| 6 | en=0 + default_pass 0/1 两态 | 改 wl_ctrl | match 恒=default_pass | — |
| 7 | **周期数断言** | 记 req↑ 到 done↑ 的拍数 | ==18 | 数错=FSM 写错 |
| 8 | busy 期间再发 req | done 后立即 req | 第二笔正常完成不丢 | — |

tb 技巧：SubBus 写任务直接 `cfg_rlwh=1; cfg_addr=..; #30; cfg_rlwh=0;`（模拟 3 拍写事务）；查找结果检查**必须等 done 再采 match**，别在 req 后固定延时。

**验证标准**：8 用例全 PASS；用例 7 的 18 拍是强校验。

### 步骤 8：系统集成与上板

1. `mac_whitelist_top.v`：`LOOKUP_MODE==0` 分支把 placeholder 换成例化你的模块（其余分支不动）；
2. `webserver_wrapper.v`：确认 1138 行 `u_mac_wl` 已就位（cfg 口←`wl_ram_*`，查找口↔`cpu_channel_tri`，en/defpass←`wl_ctrl_125m`）——**集成层已存在，只需连线核对**；
3. `build_xilinx_xc7a35tfgg484/filelist.cfg`：确认含 `../rtl/mac_whitelist_seq.v`；
4. C 驱动按 1.6 节就位（模式 0 无顺序要求，add 找 free slot 直接写）；
5. 板级验证（对照 `doc/Board_Test_Plan.md`）：

| # | 板测项 | 操作 | 期望 |
|---|--------|------|------|
| 1 | 管理面回读 | Web `/api/wl/hwlist` | 与添加一致 |
| 2 | 过滤生效 | 白名单加本机 PC MAC，enable=1，PC ping 网关对端 | 通 |
| 3 | 过滤拦截 | 删除 PC MAC（defpass=0） | ping 不通，drop_cnt 增长 |
| 4 | 全放模式 | defpass=1 | 任意 MAC 都通 |
| 5 | 持久化 | 加 2 条→掉电→重启 | `/api/wl/list` 恢复，过滤行为不变 |

**验证标准**：5 项全过 → git tag `mode0-verified`。

### 参考答案对照表（自查用）

| 本文步骤 | 参考答案位置（`rtl/mac_whitelist_seq.v`） |
|---------|------------------------------------------|
| 步骤 2 端口 | 11~35 行 |
| 步骤 3 骨架/存储 | 60~142、249~276 行 |
| 步骤 4 配置通路 | 144~216 行 |
| 步骤 5 辅助逻辑 | 217~244 行 |
| 步骤 6 查找 FSM | 256、281~314 行 |
| 步骤 7 tb | 无现成，自建（工程 sim/ 下有 tb_webserver 系统级可参考风格） |
| 步骤 8 集成 | `mac_whitelist_top.v:39-59`、`webserver_wrapper.v:1138`、`c/whitelist.c` |

---

## 第 3 章 常见错误与排查

| 症状 | 根因（对应 1.2 特性） | 排查 |
|------|----------------------|------|
| 查找永远 miss，但网页回读正常 | BRAM 没写进去（只写了 shadow） | 检查 WR 分支是否双副本同写 |
| 网页回读错，但过滤行为正确 | 只写了 BRAM（漏 shadow） | 同上反向 |
| 连续加多条，只有最后一条在 | C 侧没 flush，前写被覆盖 | 检查 subbus_write 是否读 0x500A |
| WR 偶尔执行两次/状态错乱 | 译码非幂等（用了边沿检测） | 回到 `*_r` 单拍脉冲结构 |
| 周期数 ≠18 | FSM 最后一条比较位置错 | 重画步骤 6 逐拍表 |
| en=0 时 match 恒 0 不随 defpass | S_DONE 锁存逻辑漏了 default_pass 分支 | 核对锁存行 |
| 上板查找行为间歇错 | en/defpass 跨时钟域没同步 | 确认用的是 `wl_ctrl_125m` 不是 50M 域信号 |

---

## 第 4 章 验收清单与里程碑

| 里程碑 | 完成判据 |
|--------|---------|
| M0-1 RTL 完成 | 步骤 7 仿真 8 用例 PASS |
| M0-2 集成完成 | MODE=0 出 bit，`/api/wl/diag` 寄存器快照正常 |
| M0-3 上板验收 | 步骤 8 板测 5 项过 + ILA（可选）实测 req→done=18 拍 |
| 收尾 | git commit/tag `mode0-verified`，进入姐妹篇《模式 1》 |

---

## 附录

### A. 寄存器速查（C 视角）

```c
#define WL_SUBBUS_ADDR 0x5000   // 0x00 INDEX(|bit31删) 0x01 H 0x02 L 0x03 WR
// 0x04 DEL 0x05 CLEAR 0x06 RD_H 0x07 RD_L 0x08 RD_V 0x09 FREE 0x0A MAX(flush用)
// wl_ctrl@0x300(bit0=en, bit1=defpass)   drop计数@0x21(debug_ro_1)
```

### B. 文件索引

| 文件 | 角色 |
|------|------|
| `rtl/mac_whitelist_seq.v` | 本模式参考答案（315 行） |
| `rtl/mac_whitelist_top.v` | LOOKUP_MODE 分发 |
| `rtl/cpu_channel_tri.v` | 查找调用方 + push 门控 |
| `rtl/reg_webserver.v` | SubBus 0x5000 译码、wl_ctrl |
| `rtl/webserver_wrapper.v` | 例化 + CDC |
| `c/whitelist.c` / `inc/whitelist.h` | C 驱动 |
| `doc/MAC_Whitelist_Design_Plan.md` | 上游设计文档 V4 |

---
*下一步：《MAC白名单查找引擎实现指南_模式1_二分查找.md》*
