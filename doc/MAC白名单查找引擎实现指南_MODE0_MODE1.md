# MAC 白名单查找引擎实现指南 —— 模式 0（顺序查找）→ 模式 1（二分查找）

> 文档编号：ED003R01
> 日期：2026-08-28
> 适用工程：`fpga_webserver-whitelist_dev`（whitelist_dev 分支）
> 平台：Xilinx XC7A35T-FGG484-2（ACX750）
> 性质：**从零实现指南**。仓库中已有的 `mac_whitelist_seq.v` 是模式 0 的**参考答案**（已上板验证），本文按"假设它不存在"的完整流程编写，每步末尾附「参考答案对照」；模式 1 当前**不存在任何实现**（top 里是 placeholder），本文给出完整设计与实现步骤。

---

## 第 0 章 总路线图

### 0.1 目标与阶段划分

| 阶段 | 内容 | 交付物 | 验收标准 |
|------|------|--------|---------|
| **阶段一** | 模式 0：BRAM 顺序查找引擎 | `mac_whitelist_seq.v` + top 集成 + C 驱动 + 仿真 tb | 仿真全用例通过；板上 Web 增删 MAC 生效，白名单过滤行为正确 |
| **阶段二** | 模式 1：BRAM 二分查找引擎 | `mac_whitelist_bin.v` + top MODE=1 集成 + C 驱动有序化改造 + 对拍 tb | 仿真与模式 0 对拍全通过；切 MODE=1 上板，行为与模式 0 一致，查找周期 18→10 |

两个阶段**串行**：模式 1 完全复用模式 0 的配置通路、存储结构、上层集成，只替换查找算法核心；没有模式 0 打底，模式 1 无法调试（没有对照基准）。

### 0.2 白名单在整机中的位置（先建立全局图）

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
                          │ mac_whitelist_top (LOOKUP_MODE=0/1)     │           │
                          │   ├─ 查找FSM (125MHz, BRAM读)           │           │
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

**一句话数据流**：eth1 收到包 → 硬件提取源 MAC（字节 6~13）→ 发 `lookup_req` → 查找引擎查 BRAM → `lookup_match` 结果回来 → `cpu_channel_tri` 用它门控这个包的 `wpkt_push`（push=转发到 eth2，不 push=丢弃并计数）。CPU 不参与逐包过滤，只通过 SubBus 配置白名单表。

### 0.3 阅读本文需要的背景

- Verilog 双always 风格（时序逻辑 + assign 组合）、generate、参数化模块
- 简单双口 BRAM 概念（写口 A、读口 B，读延迟 1 拍）
- 二分查找算法本身（软件层面）

---

## 第 1 章 现有框架关键机制（两个模式共用的地基）

> 本章内容两个模式**完全共用**，实现任何模式之前必须先理解。这些机制已经存在于工程中，你不需要重写，但必须知道它们怎么工作、为什么这样设计。

### 1.1 数据通路：查找在哪里被触发、结果如何生效

文件：`rtl/cpu_channel_tri.v`（三端口 L2 桥接通道，125MHz 域）

```text
① 提取源 MAC：
   mac1_rx_en && !mac1_header_done 期间，逐字节移位收集字节 6~11
   → mac1_src_mac[47:0]；字节 13 结束时 mac1_header_done=1
   （注意字节 0~5 是目的 MAC，6~11 才是源 MAC）

② 触发查找（每包一次）：
   if (mac1_header_done && !wl_lookup_pending && !wl_lookup_busy)
       → lookup_req 拉高一拍，lookup_mac ← mac1_src_mac

③ 结果捕获：
   if (wl_lookup_done) → wl_result_match ← wl_lookup_match

④ 门控转发（过滤的真正执行点）：
   assign eth1_fwd_wpkt_push = eth1_fwd_wpkt_push_raw &&
       (wl_result_match || (!whitelist_en && default_pass));
   // 包数据本来就已经整包写入 ram2pktfifo_int 缓冲，
   // 只有 push 被放行，包才会进入 package_fifo → eth2 TX。
   // 不 push = 整包自然作废 + eth1_rx_drop_cnt++。
```

**关键理解**：
- 过滤是"**整包缓存后按 push 门控**"实现的——包在查找进行期间（144ns）已被缓冲，不会丢字节；
- `eth2 → eth1` 方向**完全不经过白名单**（无条件透传），白名单只管 LAN 出方向；
- `whitelist_en / default_pass` 在门控表达式里兜底：关闭白名单时由 default_pass 决定全断还是全放。

### 1.2 配置通路：CPU 怎么读写白名单寄存器

```text
C 固件 (50MHz)                       RTL (50MHz cfg_clk 域)
──────────────                       ─────────────────────
LCPU_REG32_WRITE(0x5000+off, data)   reg_webserver.v:
  即写地址 0x80000000+(0x5000+off)*4     address∈[0x5000,0x5FFF] → SUBBUS_mac_whitelist_*
      │                              ramintf #(.AddrBits(12)) RAMIF_mac_whitelist:
      ▼                                  Ram_RlWh = !rhwl (写时=1)
webserver_wrapper:                       Ram_Addr = address[11:0]
  wl_ram_rlwh / wl_ram_addr ────────► mac_whitelist_top.cfg_rlwh/cfg_addr/cfg_wdata
```

**三个必须知道的特性**：

1. **电平敏感写、无 req/ack 握手**：`cfg_rlwh=1` 期间（SubBus 写事务约 3 拍），`case (cfg_addr[3:0])` 直接译码写入。同一笔写会被采样多次——所以所有写动作必须是"幂等"的（写寄存器重复写无害；WR/DEL 触发器写成"写同一值多次=写一次"的语义）。**不要**设计成"边沿触发一次"的语义。
2. **写后必读（flush）**：C 侧 `subbus_write()` 在每次写后读一次 `0x500A`（MAX_ENTRIES），目的是**等这笔 SubBus 事务真正完成**再发下一笔。连续两笔写之间若不 flush，前一笔可能还在 reg_webserver 的打拍寄存器里，后一笔就把前一笔覆盖了。模式 1 软件搬移条目时要大量连续写，**每一笔都必须走这个 flush**。
3. **写口与读口数据来源不同**：读 `0x06/0x07/0x08`（回读 MAC/valid）来自 **shadow_rf 寄存器阵列**（组合逻辑读、零延迟），不是 BRAM——因为 ramintf 的采样窗口（3 拍）容不下 BRAM 的 1 拍同步读延迟。BRAM 只用于 125MHz 查找。**两份存储必须同步写**（所有写路径都同时写 BRAM 和 shadow_rf，seq 参考答案是这么做的）。

### 1.3 时钟域与复位

| 时钟 | 频率 | 域内逻辑 | 跨域手段 |
|------|------|---------|---------|
| `clk` | 125MHz | 查找 FSM、BRAM 读口 | 查找请求/结果不出域（cpu_channel_tri 同域） |
| `cfg_clk` | 50MHz | 配置译码、BRAM 写口、shadow_rf | SubBus 打拍天然同步；ramintf 已处理 |
| — | — | `whitelist_en/default_pass`（wl_ctrl 2bit） | `cdc_bus_sync MODE=1`（ReqAck），wrapper 已做 |
| — | — | 手动触发脉冲 debug_wc_0_ind | `pulse_clock_region_pass`，wrapper 已做 |

复位：`reset_l` 低有效，异步 assert。125MHz 域用 `reset_l`，50MHz 域用 `cfg_reset_l`（wrapper 里两者同源）。

### 1.4 存储结构：49-bit 条目 + 双副本

```
每条目 49 bit：{ valid[48], mac[47:0] }
主存储：  dual_clock_simple_dual_port_ram（A口=cfg_clk写，B口=clk读，读延迟1拍）→ 给查找用
副本：    shadow_rf 寄存器阵列（组合读）→ 给 CPU 回读用
辅助：    valid_bits[ENTRY_NUM-1:0] 寄存器 → 生成 free_idx（优先编码器链）和 used_cnt（popcount链）
```

### 1.5 寄存器表（SubBus 基址 0x5000，偏移 = cfg_addr[3:0]）

| 偏移 | 名称 | 类型 | 位宽 | 说明 |
|-----|------|------|------|------|
| 0x00 | INDEX | RW | [3:0] | 选中条目索引；**bit31=1 时附带删除该索引条目**（本工程扩展） |
| 0x01 | MAC_H | RW | [31:0] | 暂存 MAC[47:16] |
| 0x02 | MAC_L | RW | [15:0] | 暂存 MAC[15:0] |
| 0x03 | WR | WC | — | 触发：把 {1'b1, 暂存MAC} 写入索引处（BRAM+shadow 同步写） |
| 0x04 | DEL | WC | — | 触发：清零索引处 |
| 0x05 | CLEAR | WC | — | 启动清除序列器（逐拍清全表，ENTRY_NUM 拍完成） |
| 0x06 | RD_MAC_H | RO | [31:0] | 回读 shadow_rf[INDEX] 的 MAC[47:16] |
| 0x07 | RD_MAC_L | RO | [15:0] | 回读 MAC[15:0] |
| 0x08 | RD_VALID | RO | [0] | 回读 valid 位 |
| 0x09 | FREE_IDX | RO | [3:0] | 首个空闲索引（全满=4'hF） |
| 0x0A | MAX_ENTRIES | RO | [7:0] | =16 |
| 0x0B | USED_CNT | RO | [7:0] | 有效条目数 |

> 与设计文档 V4 的差异：V4 规划的 0x0C~0x0F（命中/丢弃 64bit 计数）**未实现**，丢弃计数由 `cpu_channel_tri` 统计并映射到 reg_webserver 的 `debug_ro_1`（0x21）。命中/丢弃计数如需可在阶段二完成后作为扩展练习。

### 1.6 C 驱动现状（`c/whitelist.c`）

- `subbus_write(base, off, data)`：写 + 读 0x500A flush（见 1.2）；
- **软件影子表**：`sw_wl_valid[16] / sw_wl_mac[16][6] / sw_wl_count` —— Web 页面显示、Flash 持久化都以它为权威；
- `whitelist_add/delete/clear_all`：影子表 + HW SubBus 双写；
- `whitelist_hw_read_entry(i)`：经 0x06/07/08 读 HW 真实内容（tcp.c 的 `/api/wl/list`、`/api/wl/hwlist` 用它）；
- `whitelist_get/apply_snapshot`：与 `flash_cfg.c`（0xC20000 持久化）的接口。

### 1.7 构建与烧录链（改完代码怎么验证）

```bash
# RTL 改动后（bitstream）：
cd build_xilinx_xc7a35tfgg484 && ./build_fpga.sh <ver>
# C 改动后（固件）：
cd c_build && make PLATFORM=xilinx riscv_reset_addr=0xf TCL_BASE=0x8000
# 烧录 + 加载（顺序）：
openFPGALoader -c digilent_hs2 <proj>.bit
vivado -mode batch -source load_fw.tcl      # JTAG-AXI 逐字写 InstructRAM.tcl
vivado -mode batch -source flash_web2.tcl   # （若网页也要更新）
```

---

## 第 2 章 阶段一：模式 0 —— BRAM 顺序查找，从零实现

> 本章按"参考答案不存在"来写。每步给出：目标 / 详细做法 / 验证标准 / 参考答案对照位置。

### 步骤 1：需求与规格定义

**做什么**：把需求翻译成可实现、可验证的规格。

1. 容量：16 条目（`ENTRY_NUM=16`，`ADDR_WIDTH=$clog2(16)=4`）；
2. 查找对象：48bit MAC + 1bit valid；
3. **时序预算**（这是顺序查找可行性的核心论证，写进设计说明）：
   - 千兆最小帧间隔：84 字节（64B 最小帧 + preamble/IFG）× 8ns = **672ns**；
   - 顺序查找全表：IDLE(1) + COMPARE(16) + DONE(1) = **18 拍** × 8ns = **144ns**；
   - 144ns < 672ns → 查找完成时下一个包的查找请求还没来（触发条件里有 `!wl_lookup_busy` 兜底），**不丢包**；
4. 空表/关闭行为：`whitelist_en=0` 时不查表，由 `default_pass` 决定（0=全断，1=全放）；
5. 表项管理：CPU 经 SubBus 寄存器增删查清，无顺序约束（模式 0 的槽位语义：index 只是物理位置）。

**验证标准**：规格文档化（本文档即），周期预算数字能口算复述。

### 步骤 2：接口与寄存器表设计

**做什么**：定模块端口和寄存器映射（对外契约，一旦定下，模式 1 也要遵守）。

端口分四组：
```verilog
module mac_whitelist_seq #(
    parameter int ENTRY_NUM  = 16,
    parameter int ADDR_WIDTH = 4
) (
    // ── 查找口（125MHz，与 cpu_channel_tri 直连）──
    input             clk, reset_l,
    input             lookup_req,        // 1 拍脉冲
    input      [47:0] lookup_mac,
    output reg        lookup_match,      // done 时有效
    output reg        lookup_done,       // 1 拍脉冲
    output            lookup_busy,       // 电平：非 IDLE 即 1
    // ── 配置口（50MHz，接 ramintf，电平敏感无握手）──
    input             cfg_clk, cfg_reset_l,
    input             cfg_rlwh,          // 1=写 0=读
    input      [11:0] cfg_addr,          // 用 [3:0]
    input      [31:0] cfg_wdata,
    output     [31:0] cfg_rdata,         // 组合读 mux
    // ── 全局控制（125MHz 域，上游 CDC 已做）──
    input             whitelist_en,
    input             default_pass
);
```
寄存器表：直接采用第 1.5 节（已定稿）。

**验证标准**：端口表与 top 封装的例化连线一致（第 1.2 节通路能逐根线走通）。

### 步骤 3：模块骨架与存储实例化

**做什么**：搭文件骨架，先让存储和辅助结构立起来（不含查找逻辑）。

1. 信号声明：`state/cmp_index/match_found`（查找FSM）、`cfg_idx/cfg_mac`（配置暂存）、`valid_bits`、`clear_active/clear_cnt`（清除序列器）、`bram_wr_*_r / sh_wr_*_r`（写请求暂存寄存器）；
2. 实例化主 BRAM：`dual_clock_simple_dual_port_ram #(.data_width(49), .addr_width(4), .depth(16), .ram_type(`LARGER_RAM), .vendor(`DEVICE_VENDOR))`，A 口接 cfg_clk 写，B 口接 clk 读；
3. 声明 `shadow_rf[0:15]` 寄存器阵列 + 组合读 `assign sh_rd_data = shadow_rf[sh_rd_addr]`；
4. **写仲裁约定**：普通写请求先打入 `*_r` 暂存寄存器（1 拍有效），再与清除序列器的输出做 OR-mux 后接到 BRAM/shadow 写口——保证 CLEAR 期间普通写不冲突。

**验证标准**：`iverilog -o /dev/null`（或 lint）编译通过，无隐式 wire。

### 步骤 4：配置通路编码（写译码 + 清除序列器）

**做什么**：实现 50MHz 域的全部寄存器写入行为。

编码要点（每一条都是踩过的坑）：
1. 一个 `always @(posedge cfg_clk)` 块内：默认 `bram_wr_en_r<=0; sh_wr_en_r<=0;`（1 拍脉冲语义）；
2. `if (cfg_rlwh) case (cfg_addr[3:0])`：
   - `4'h0`：`cfg_idx <= wdata[3:0]`；**若 `wdata[31]` 同时置 1 → 附带删除该索引**（防 C 侧两次写之间的竞态）；
   - `4'h1 / 4'h2`：暂存 MAC 高/低位（纯寄存器，电平语义）；
   - `4'h3`（WR）：`{bram,sh}_wr_* <= {1'b1, cfg_mac}` @ cfg_idx，`valid_bits[cfg_idx]<=1`；
   - `4'h4`（DEL）：写 49'b0 @ cfg_idx，`valid_bits[cfg_idx]<=0`；
   - `4'h5`（CLEAR）：`clear_active<=1, clear_cnt<=0`；
3. 清除序列器：`clear_active` 期间每拍清一个地址（BRAM+shadow+最后清 valid_bits），计满自动停——**计数器实现，不要状态机**；
4. 复位：cfg_idx/cfg_mac/valid_bits/clear_active/写请求寄存器清零。**BRAM 和 shadow_rf 内容不复位**（FPGA 上电即零，且 BRAM 无法异步复位）。

**验证标准**：仿真中依次写 INDEX/MAC/WR，读 0x06/07/08 能回读正确值；DEL/CLEAR 后 valid=0。

### 步骤 5：辅助组合逻辑（free_idx / used_cnt / 读 mux）

**做什么**：

1. `free_idx`：generate 级联优先编码器——从高索引往低传，`!valid_bits[gi] ? gi : stage[gi+1]`，默认全满=4'hF。（**不要用 for 循环带 break**——Vivado 综合不了退出条件变量）；
2. `used_cnt`：generate 加法器链 popcount；
3. 读 mux：`cfg_rdata` 用 `(!cfg_rlwh && rd_reg==X) ? 值 : ...` 级联 assign（见 1.2 特性 1：读也是电平组合的）；
4. `sh_rd_addr`：仅当读 0x06/07/08 时指向 cfg_idx，否则指向 0（防止非预期读）。

**验证标准**：仿真读 0x09/0x0A/0x0B 与写入情况一致。

### 步骤 6：查找 FSM 编码（模式 0 的核心）

**做什么**：125MHz 域三态 FSM。

```text
S_IDLE ──lookup_req──► S_COMPARE ──cmp_index==15──► S_DONE ──► S_IDLE
                        │  每拍:                    │
                        │  发 bram_rd_addr=cmp_index │ (该拍比较的是"上一拍地址"
                        │  cmp_index++               │  读回的数据"——BRAM 1拍延迟!)
```

三个必须处理的细节：
1. **BRAM 读延迟 1 拍**：S_COMPARE 第 i 拍比较的是第 i-1 拍发出的地址的数据。所以 `cmp_index>0` 时才开始比较，且**最后一条（index=15）的数据在 S_DONE 才到达**——S_DONE 里要补一次比较再锁存结果；
2. 结果锁存：`S_DONE: lookup_match <= whitelist_en ? (match_found || 本拍命中) : default_pass; lookup_done <= 1;`（done 是 1 拍脉冲，每拍默认清零）；
3. `assign lookup_busy = (state != S_IDLE)`。

**验证标准**：仿真造 3 条 MAC（含表首、表尾、中间），逐条 lookup_req，done 后 match=1；查不存在 MAC match=0；done 脉冲宽度=1 拍；req→done 间隔=18 拍（数波形）。

### 步骤 7：单元仿真

**做什么**：写 `sim/tb_mac_whitelist_seq.sv`（独立 tb，不需要整个 SoC），用例矩阵：

| # | 用例 | 期望 |
|---|------|------|
| 1 | 写 3 条 → 逐条查找 | 全命中 |
| 2 | 查未添加 MAC | miss |
| 3 | 删除中间一条 → 再查 | 命中→miss，其余不受影响 |
| 4 | CLEAR → 查任意 | miss，USED_CNT=0 |
| 5 | 加满 16 条 → FREE_IDX=0xF | 表满语义 |
| 6 | whitelist_en=0 + default_pass 两态 | match 恒等于 default_pass |
| 7 | req→done 周期数断言 | =18 |
| 8 | 连续背靠背 lookup（busy 时 req） | busy 期间 req 被忽略，不丢后续 |

用 Verilator 或 iverilog 均可（BRAM 模型在 ip_common，仿真友 好）。

**验证标准**：8 个用例全 PASS。

### 步骤 8：系统集成与上板

1. `mac_whitelist_top.v`：`LOOKUP_MODE==0` 分支例化你的模块（原本是 placeholder）；
2. `webserver_wrapper.v`：确认 `u_mac_wl` 例化（cfg 口接 `wl_ram_*`，查找口接 `cpu_channel_tri` 的 `wl_*`）——集成层工程里已就位，无需改；
3. `build_xilinx.../filelist.cfg`：加入 `../rtl/mac_whitelist_seq.v`（top 已在）；
4. C 驱动 `whitelist.c` 按第 1.6 节编写（无序表，free slot 分配即可）；
5. 板级验证（对照 `doc/Board_Test_Plan.md`）：烧 bit+固件 → Web `/wlconfig` 添加本机 PC 的 MAC → `ping 192.168.1.88` 通 → 删除后（enable=1, defpass=0）ping 不通 → `/api/wl/hwlist` 回读与添加一致。

**参考答案对照表（模式 0）**

| 本文步骤 | 参考答案位置 |
|---------|-------------|
| 步骤 3~6 全部 | `rtl/mac_whitelist_seq.v`（315 行，逐段对应） |
| 步骤 7 | 无现成 tb（工程只有系统级 tb），自建 |
| 步骤 8 | `mac_whitelist_top.v:39-59`、`webserver_wrapper.v:1138`、`c/whitelist.c` |

---

## 第 3 章 阶段二：模式 1 —— BRAM 二分查找，从零实现

### 3.0 与模式 0 的差异总览

| 维度 | 模式 0 | 模式 1（要做的） |
|------|--------|----------------|
| 查找算法 | 线性扫 16 条，18 拍 | 二分 4 迭代，**10 拍** |
| 表的有序性 | 无要求 | **valid 条目占据 [0, used-1] 连续区间，MAC 严格升序**（软硬件契约） |
| index 语义 | 物理槽位（任意） | **有序排名**（index=第几小） |
| 增删条目 | 直接写 free slot | **软件搬移保持有序**（3.2 节） |
| 配置通路/寄存器表/shadow_rf/CLEAR | — | **完全复用，零改动** |
| 上层集成（wrapper/cpu_channel_tri/C 接口签名） | — | **完全复用**（只改 C 内部实现） |

### 3.1 核心设计决策：排序维护放软件（已拍板）

**理由**：
- 增删是**低频配置操作**（人手在网页上点），逐包查找才是热路径——把复杂度从热路径挪到冷路径；
- 硬件自动搬移需要多周期写序列状态机（读-改-写 15 条 × 跨时钟域），调试成本高、引入新风险；
- 软件已有影子表（`sw_wl_mac`），搬移只是"数组插入/删除 + 重写 HW"，代码量 ~40 行；
- HW 寄存器接口（INDEX/MAC/WR/DEL）**零改动**即够用。

**代价**：加/删一条需要重写受影响区间的若干条目（每次 SubBus 写约 1µs，最坏 16 条 ≈ 50µs）——完全无感。

### 3.2 软件契约（模式 1 正确性的根基，必须写进代码注释）

```text
不变式 INV1：有效条目占据 index ∈ [0, used_cnt-1] 的连续区间，其后全部 invalid(49'b0)。
不变式 INV2：∀ i < j ≤ used_cnt-1：mac[i] < mac[j]（48bit 无符号严格升序，无重复）。
不变式 INV3：任意时刻表都满足 INV1/INV2 ——包括软件搬移的中间状态（见 3.5 搬移顺序设计）。
```

### 3.3 步骤 1：查找算法的硬件时序展开

软件二分人人会写，硬件版的本质变化是**每次 BRAM 读有 1 拍延迟，且下一跳依赖上一跳的比较结果，无法流水**：

```text
软件:  lo=0, hi=used-1
       while (lo <= hi):
           mid = (lo+hi)/2
           if mac[mid] == target: hit
           elif mac[mid] < target: lo = mid+1
           else:                    hi = mid-1
       miss

硬件时序（每迭代 2 拍：拍A 发地址，拍B 数据有效+比较+算出下一 mid）:
  拍 0  (IDLE→B_ISSUE0)  发地址 mid0=(0+used-1)/2
  拍 1  (B_CMP0)         数据0有效，比较；算出 mid1
  拍 2  (B_ISSUE1)       发地址 mid1
  拍 3  (B_CMP1)         比较；算出 mid2
  拍 4~7                 同理（共 4 次迭代 = log2(16)）
  拍 8  (B_DONE)         锁存 match，拉 done 一拍
  → req 到 done = 10 拍（vs 模式 0 的 18 拍）
```

两个硬件特有的优化/细节：
1. **提前命中退出**：任一迭代命中即转 B_DONE（不必跑满 4 次），平均命中延迟 ~8 拍；
2. **边界/invalid 处理（最容易踩的坑）**：
   - hi 初值不用 `ENTRY_NUM-1` 而用 **`used_cnt-1`**——used_cnt 已有组合逻辑（popcount 链，模式 0 步骤 5 的产物直接复用）。因为 INV1 保证有效条目连续在前，这个初值是精确的；
   - 双保险：若读回 `!bram_rd_valid`（理论上 mid 越过 used-1 才会发生），**强制向左**（`hi=mid-1`）。若不处理，invalid 条目 mac=0 会被当成"比任何 MAC 都小"而向右走，**永不收敛到正确结果**；
   - 软件禁止添加全零 MAC（`00:00:00:00:00:00`），使"mac=0 即 invalid"的推断恒成立；
3. 比较器：48bit 无符号比较（Verilog reg/wire 天然无符号，**别把端口声明成 signed**）；125MHz 下 48bit 比较 1 拍完成，无时序压力（最坏路径在别处，参考已建工程的时序报告）。

### 3.4 步骤 2：`mac_whitelist_bin.v` 编码

**做什么**：新建 `rtl/mac_whitelist_bin.v`。

**复用策略**：把 `mac_whitelist_seq.v` 整体复制改名，然后**只动两处**——

改动 1（删除）：查找 FSM 三态 → 换成下面的五态：

```verilog
localparam S_IDLE    = 3'd0;
localparam S_ISSUE   = 3'd1;   // 发当前 mid 地址
localparam S_CMP     = 3'd2;   // 数据有效：比较 + 算下一 mid
localparam S_DONE    = 3'd3;

reg [ADDR_WIDTH-1:0] lo, hi, mid;
reg                  hit;

S_IDLE:    if (lookup_req) begin
               lo <= 0; hi <= used_cnt_comb - 4'd1;   // ★ 关键：used-1
               hit <= 0;
               if (used_cnt_comb == 0) state <= S_DONE;  // 空表直接 miss
               else state <= S_ISSUE;
           end
S_ISSUE:   bram_rd_addr <= mid;  state <= S_CMP;
           // （bram_rd_addr 改成寄存器驱动，不再像 seq 那样挂在 state 上）
S_CMP:     if (bram_rd_valid && bram_rd_mac == lookup_mac) begin
               hit <= 1; state <= S_DONE;                 // ★ 提前退出
           end else if (!bram_rd_valid || bram_rd_mac > lookup_mac) begin
               if (mid == 0) state <= S_DONE;             // 向左越界 → miss
               else begin hi <= mid - 1; mid <= (lo + mid - 1) >> 1; state <= S_ISSUE; end
           end else begin
               if (mid == hi) state <= S_DONE;            // 向右越界 → miss
               else begin lo <= mid + 1; mid <= (mid + 1 + hi) >> 1; state <= S_ISSUE; end
           end
S_DONE:    lookup_match <= whitelist_en ? hit : default_pass;
           lookup_done  <= 1'b1;  state <= S_IDLE;
```

改动 2（删除/保留）：配置通路（步骤 4/5 的全部代码）、shadow_rf、CLEAR 序列器、free_idx/popcount **原样保留，一行不改**。寄存器表语义不变——**但 C 侧语义变化见 3.5**。

顺手修复（集成时做）：`webserver_wrapper.v` 的 `wl_status` 目前**未驱动**（声明了没 assign，读 0x301 恒 0）——补一行：
```verilog
assign wl_status = {8'b0, 8'd1};   // 低 8 位 = LOOKUP_MODE(1)；如需实时 used_cnt 可从模块引出
```
（更完整做法：给 `mac_whitelist_top` 加 `output [7:0] used_cnt_o`，wrapper 拼 `{used_cnt_o, 8'd1}`——Web 状态栏就能同时显示模式和实时条目数。）

**验证标准**：编译 0 error/0 critical warning；`wl_status` 读回低 8 位=1。

### 3.5 步骤 3：C 驱动有序化改造（`c/whitelist.c`）

**做什么**：影子表从"槽位表"变"有序表"，add/delete 改为搬移式。**改动集中在这一个文件**，`tcp.c`/`http.c`/`flash_cfg.c` 全部不动（接口签名不变）。

```c
// ★ 新增工具：把影子表第 i 条写入 HW（INDEX+MAC_H+MAC_L+WR，每笔带 flush）
static void wl_hw_write_entry(int i, const uint8_t mac[6]);

// ★ 新增工具：HW 删除（INDEX|0x80000000 一笔带 bit31 删除，比两笔更快）
static void wl_hw_delete_entry(int i);

// ---- 有序插入（替换原 whitelist_add 的主体）----
int whitelist_add(uint8_t mac[6]) {
    // 1. 查重（线性扫 16 条即可）：已存在 → 返回其 index（幂等）
    // 2. 表满(sw_wl_count==16) → -1
    // 3. 二分/线性找插入位 pos：第一个 mac[pos] > 新 MAC 的位置
    // 4. 影子表 memmove 上移: sw_wl_mac[pos+1..count-1] ← [pos..count-2]
    // 5. ★ HW 搬移【从高往低】写：
    //      for (i = count-1; i >= pos+1; i--) wl_hw_write_entry(i, sw_wl_mac[i]);
    //    ——从高往低保证任意中间态都满足 INV2：
    //      写 pos+1 时（覆盖旧 mac[pos+1] 为旧 mac[pos]），旧值暂存于 pos+1 与 pos 两处，
    //      表中有瞬时重复但依然有序，查找语义不受影响（命中哪个都=命中）；
    //    若从低往高写，中间态会出现 mac[pos] 同时"小于前一条"的乱序点，查找可能漏判！
    // 6. wl_hw_write_entry(pos, 新MAC)；影子表落位，count++
    // 7. 返回 pos
}

// ---- 有序删除（替换原 whitelist_delete 的主体）----
int whitelist_delete(uint8_t index) {
    // 1. index >= sw_wl_count 或 !sw_wl_valid[index] → -1
    // 2. 影子表 memmove 下移: [index..count-2] ← [index+1..count-1]
    // 3. ★ HW 搬移【从低往高】覆盖：
    //      for (i = index; i < count-1; i++) wl_hw_write_entry(i, sw_wl_mac[i]);
    //      wl_hw_delete_entry(count-1);   // 清最后一条
    //    ——从低往高写：每一步都是"小值覆盖大位置"，中间态保持有序（INV3 成立）
    // 4. 影子表 count--，清 valid
    // 5. 返回 0
}

// ---- 快照恢复（whitelist_apply_snapshot）----
// Flash 里存的顺序即有序序（保存时影子表本就有序）；
// 防御性做法：先在影子表内排序，再按 index 0..n-1 逐条 wl_hw_write_entry。
```

> **为什么搬移期间不用关白名单**：按上述"插入从高到低、删除从低到高"的覆盖顺序，HW 表在每一笔写之间都保持有序（可能有瞬时重复，不影响命中判断），过滤功能全程无感。若你选择无序覆盖，就必须搬移前置 `wl_ctrl[0]=0`、搬完恢复——两种都正确，前者更优雅，后者更简单，任选其一并在代码注释里写明。

**回归注意**：`/api/wl/list`（tcp.c）按 index 0..15 逐条 `whitelist_hw_read_entry` 读的是 HW shadow_rf——搬移实现正确的话它自动与 Web 显示一致（顺序变为 MAC 升序，这是**预期行为变化**，页面无需改）。

**验证标准**（纯 C 层，可先在 x86 上用单测跑通算法再上板）：随机 1000 次增删后影子表始终有序无重复；HW 回读与影子表逐条一致。

### 3.6 步骤 4：top 集成与模式切换

1. `mac_whitelist_top.v`：generate 加 `else if (LOOKUP_MODE == 1) begin : g_mode_bin` 分支例化 `mac_whitelist_bin`（端口连线照抄 mode 0 分支）；最后的 placeholder 分支保留给 MODE=2；
2. 切换方式：`webserver_wrapper.v:1139` 的 `LOOKUP_MODE(0)` 改 `1` → 重编 bitstream。**C 固件不用改**（两模式共用一份固件，只是行为从有序表角度操作同一组寄存器）；
3. `filelist.cfg` 增加 `../rtl/mac_whitelist_bin.v`。

**验证标准**：MODE=1 出 bit；Web `/api/wl/status` 的 `lookup_mode` 字段（`wl_status[7:0]`）读回 1。

### 3.7 步骤 5：单元仿真 + 两模式对拍

**做什么**：新建 `sim/tb_mac_whitelist_bin.sv`，在模式 0 的 8 个用例基础上增补：

| # | 新增用例 | 期望 |
|---|---------|------|
| 9 | 有序表（8 条随机 MAC 排序灌入）查 16 个目标（8 命中+8 miss） | 全部判断正确 |
| 10 | req→done 周期数断言 | ≤10（命中且首迭代命中时更短） |
| 11 | **金模型对拍**：tb 内用 SV 队列维护影子表，随机 500 次 add/del/lookup，每次 lookup 后比对 RTL match 与软件模型 | 100% 一致 |
| 12 | 空表 lookup | done=1 且 match=0（1 拍也不多等） |
| 13 | 查最小/最大/中间值 | 边界命中 |
| 14 | used_cnt=1 单条表 | 二分区间 [0,0] 收敛正确 |

**对拍也是回归**：保留 tb 的 MODE 参数化（`if (MODE) 实例化 bin else seq`），模式 0 用例 1~8 在 bin 上也要全过（除用例 7 的周期数断言改为 ≤10）。

**验证标准**：14 用例全 PASS + 500 次随机对拍 0 mismatch。

### 3.8 步骤 6：上板验证

1. MODE=1 编译烧录（流程见 1.7）；
2. 功能回归：Web 增 3 条 → `/api/wl/list` 显示为**升序** → PC ping 通（MAC 在表）→ 删除后 ping 不通；
3. **搬移并发验证**（本模式特有）：启用白名单、持续 ping 打流的同时，在 Web 上连续增删 10 次——ping 允许瞬态抖动但**不允许长期不通**（验证 3.5 的"搬移期间表始终有序"）；
4. 掉电重启 → Flash 加载后 `/api/wl/list` 仍有序、过滤行为不变（`apply_snapshot` 排序灌入正确）；
5. 性能记录（选做）：ILA 抓 `lookup_req→lookup_done` 实测周期数，与理论 10 拍对照。

### 步骤参考答案对照（模式 1）

| 本文小节 | 参考位置 |
|---------|---------|
| 3.4 FSM | **无**（全新实现，本文即设计稿） |
| 3.4 配置通路复用 | `mac_whitelist_seq.v` 原样抄 |
| 3.5 C 搬移 | `c/whitelist.c` 现有 add/delete 为改造前基线 |
| 3.6 集成点 | `mac_whitelist_top.v:60-66`（placeholder 待替换处） |

---

## 第 4 章 验证矩阵与回归清单（两阶段共用）

| 层级 | 模式 0 | 模式 1 | 工具 |
|------|--------|--------|------|
| 单元：查找算法 | tb 用例 1~8 | 用例 1~6、9~14（+对拍） | iverilog/Verilator |
| 单元：配置通路 | 用例 1~5、8 | 同左（共用代码，跑一遍即可） | 同上 |
| 集成：系统仿真 | （可选，工程 tb_webserver 规模大，白名单路径可用 ILA 代替） | 同左 | Verilator |
| 板级：管理面 | Web 增删清、list/diag、Flash 重启恢复 | 同左 + list 升序 + lookup_mode=1 | 浏览器/curl |
| 板级：数据面 | 打流下增删 MAC 观察通断 | 同左 + 搬移期间持续打流 | ping/iperf3 |
| 板级：性能 | （基线 18 拍） | ILA 实测 ≤10 拍 | fpga_ila |

**每步完成即 git commit**（信息写明步骤号），任一阶段出问题可回退。

---

## 第 5 章 里程碑、风险与注意事项

### 5.1 里程碑

| 里程碑 | 内容 | 完成判据 |
|--------|------|---------|
| M0-1 | 模式 0 RTL 完成 | 步骤 7 仿真 8 用例过 |
| M0-2 | 模式 0 上板 | 板级管理面+数据面全过，打 tag `mode0-verified` |
| M1-1 | 二分 FSM + C 搬移完成 | 步骤 3.7 仿真 14 用例+对拍过 |
| M1-2 | 模式 1 上板 | 板级全过 + 搬移并发验证过 + ILA 实测 ≤10 拍，打 tag `mode1-verified` |

### 5.2 风险与对策

| 风险 | 影响 | 对策 |
|------|------|------|
| BRAM 1 拍读延迟处理错（最后一条/首拍比较） | 查表漏判/误判 | 步骤 6/3.3 的时序展开逐拍画波形核对；tb 周期数断言兜底 |
| 二分 hi 初值用 ENTRY_NUM-1 而非 used-1 | invalid(mac=0) 被当最小值向右走，**永不正确收敛** | 3.3 细节 2：used-1 初值 + invalid 强制向左双保险 |
| 连续 SubBus 写不 flush | 前一笔被后一笔覆盖，搬移丢条目 | 强制走 `subbus_write()`（内含读 0x500A flush） |
| 搬移顺序不对（插入从低往高） | 中间态乱序，打流时漏判 | 3.5 的覆盖顺序（插入高→低、删除低→高）+ 板级并发验证 |
| 电平敏感写被重复采样 | 触发类寄存器双执行 | 写译码保持幂等语义（照抄模式 0 的 `*_r` 1 拍脉冲结构） |
| 48bit 比较被综合成多拍 | 时序违例 | 保持单拍组合比较；若 WNS 紧张再看报告（125MHz 余量大） |
| `wl_status` 忘了接 | Web 无法核对当前模式 | 3.4 顺手修复项 |

### 5.3 明确不做（本期范围外）

- MODE 2 布谷鸟哈希（>64 条目时再立项）；
- 0x0C~0x0F 命中/丢弃 64bit 计数寄存器（可作为模式 1 完成后的练习）；
- 仿真 BFM 级的系统级白名单用例（板级验证已覆盖）。

---

## 附录

### A. 寄存器速查（C 视角）

```c
#define WL_SUBBUS_ADDR 0x5000
// 0x00 INDEX(|bit31 删除)  0x01 MAC_H  0x02 MAC_L  0x03 WR  0x04 DEL
// 0x05 CLEAR  0x06 RD_H  0x07 RD_L  0x08 RD_VALID  0x09 FREE  0x0A MAX  0x0B USED
// 写后必读 0x0A flush；wl_ctrl@0x300(bit0=en,bit1=defpass)；wl_status@0x301
```

### B. 关键文件索引

| 文件 | 角色 |
|------|------|
| `rtl/mac_whitelist_seq.v` | 模式 0 参考答案（315 行） |
| `rtl/mac_whitelist_bin.v` | 模式 1 待新建 |
| `rtl/mac_whitelist_top.v` | LOOKUP_MODE 分发（60~66 行 placeholder 待替换） |
| `rtl/cpu_channel_tri.v` | 查找调用方 + 过滤门控（174~248、306~307 行） |
| `rtl/reg_webserver.v` | SubBus 0x5000 译码（1197~1207）+ wl_ctrl 0x300 |
| `rtl/webserver_wrapper.v` | 例化与 CDC（1138~1158、970~985） |
| `c/whitelist.c` / `inc/whitelist.h` | C 驱动（模式 1 改造点） |
| `c/inc/lcpu_general.h` | 寄存器结构体 / FLASH_MEM_BASE |
| `doc/MAC_Whitelist_Design_Plan.md` | 设计文档 V4（本指南的上游需求） |

### C. 二分 vs 顺序：何时值得

| | 模式 0 顺序 | 模式 1 二分 |
|---|-----------|------------|
| 最坏周期 | 18 拍（144ns） | 10 拍（80ns） |
| 16 条目是否必要 | 必要性低（144ns≪672ns） | 收益主要是学习+余量 |
| 何时必须换 | 条目数 >64 时顺序查找逼近帧间隔 | 64 条=162ns、128 条=322ns 仍可行；>512 条应上 MODE 2 哈希 |

> 结论：16 条目下两模式都线速安全；做模式 1 的价值在于**掌握"软件维护有序结构 + 硬件二分查找"这一经典软硬协同范式**——它是后续防火墙 L3/L4 规则表（TCAM 替代品、更多条目、复合键）的直接基础。

---
*文档结束。实施时按章推进，每步验证标准不通过不进下一步。*
