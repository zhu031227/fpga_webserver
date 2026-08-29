# FPGA WebServer MAC 白名单上网控制 — 设计方案 V4

> 文档编号：ED002R04  
> 日期：2026-07-07  
> 基于：fpga_webserver 现有架构  
> 平台：Xilinx XC7A35T-FGG484-2（仅限 Xilinx 平台实现双 1000BASE-X）

---

## 1. 需求概述

在现有 fpga_webserver 基础上，扩展为**三网口千兆 MAC 白名单二层透明网桥**：

```
                        ┌────────────── FPGA (XC7A35T) ──────────────┐
                        │                                            │
   eth0 (RGMII, 1G)     │  ┌──────────┐    ┌───────────────┐        │
   管理/配置口 ◄─────────┼──┤ gmii2mac │    │  CPU 协议栈    │        │
   (独立管理网段)        │  │  eth0    │───►│  (WebServer)  │        │
                        │  └──────────┘    └───────────────┘        │
                        │                                            │
   eth1 (1000BASE-X,1G) │  ┌──────────────┐    ┌──────────────┐     │
   LAN 口 ◄─────────────┼──┤ 1000BASE-X IP├───►│ MAC 白名单   │     │
   (接用户PC)           │  │ → GMII 桥    │    │ (顺序查找)   │     │
                        │  └──────────────┘    └──────┬───────┘     │
                        │                             │ pass?       │
                        │                    ┌────────┤             │
   eth2 (1000BASE-X,1G) │  ┌──────────────┐  │ no→丢弃 │             │
   WAN 口 ◄─────────────┼──┤ 1000BASE-X IP│  ▼ yes    │             │
   (接上级路由器)       │  │ → GMII 桥    │◄──────────┘             │
                        │  └──────────────┘                         │
                        │                                            │
                        │  ┌──────────────────────────────────┐     │
                        │  │     SPI Flash (MX25L12845,16MB)   │     │
                        │  │  ┌──────────┐  ┌──────────────┐   │     │
                        │  │  │ Web 页面  │  │ 本机+白名单   │   │     │
                        │  │  │ (HTML)   │  │ (IP/MAC/WL)  │   │     │
                        │  │  └──────────┘  └──────────────┘   │     │
                        │  └──────────────────────────────────┘     │
                        └────────────────────────────────────────────┘
```

**三个千兆网络接口：**

| 接口 | 物理层 | 速率 | 方向 | 功能 |
|------|--------|------|------|------|
| **eth0** | RGMII | 1Gbps | 管理口 | FPGA WebServer 管理页面，不参与数据转发 |
| **eth1** | 1000BASE-X → GMII | 1Gbps | LAN 口 | 连接用户电脑，出方向 MAC 白名单过滤 |
| **eth2** | 1000BASE-X → GMII | 1Gbps | WAN 口 | 连接上级路由器，回程流量透传 |

**核心功能：**
1. **二层透明桥接**：eth1↔eth2 做纯二层桥接，不修改报文（无NAT、无TTL递减）
2. **千兆线速**：所有三个接口均为 1Gbps，内部 GMII 8-bit @125MHz
3. **MAC 白名单过滤**：eth1→eth2 方向，源 MAC 不在白名单的报文硬件丢弃
4. **eth2→eth1 回程透传**：不检查白名单，直接转发
5. **Flash 持久化**：Web 页面、MAC 白名单、本机 IP/MAC 配置存储在 SPI Flash (MX25L12845, 16MB)，断电不丢失
6. **默认"全断"**：白名单为空或关闭时，LAN→WAN 方向阻断所有流量
7. **本机可配置**：Web 页面支持修改本机 IP/MAC 地址，修改后通过新地址访问管理页面

---

## 2. MAC 白名单查找引擎（BLOCK RAM + 顺序查找）

### 2.1 设计思路

使用 **Block RAM** 存储 MAC 表项，**状态机逐条顺序比较**，而非全并行比较器：

```
时钟周期:  0     1     2     3    ...    N-1    N
状态:     IDLE  CMP0  CMP1  CMP2  ...  CMP15  DONE
          ──────┬─────────────────────────────┬─────►
          收到查找请求                        输出 match
          读BRAM addr=0                      回到 IDLE
```

**为什么用顺序查找而非并行：**
- Block RAM 每周期只能读一个地址，天然适合顺序访问
- 节省 LUT 资源（N 个 48-bit 并行比较器 → 1 个比较器复用 N 次）
- 16 条目 × 8ns(125MHz) = 128ns 最大延迟，千兆最小帧（64B = 672ns preamble+IFG）完全可覆盖
- 后续扩展条目数只需改 BRAM 深度，不影响时序

### 2.2 三种查找模式预留

```
┌─────────────────────────────────────────────────────┐
│                  mac_whitelist_top                   │
│  parameter LOOKUP_MODE = 0/1/2                      │
│                                                     │
│  ┌──────────────┐ ┌──────────────┐ ┌─────────────┐  │
│  │ MODE 0:      │ │ MODE 1:      │ │ MODE 2:     │  │
│  │ BRAM顺序查找  │ │ BRAM二分查找  │ │ BRAM+Hash   │  │
│  │ (本次实现)    │ │ (预留骨架)    │ │ (预留骨架)   │  │
│  │ 16 clk/查找  │ │ 5 clk/查找   │ │ 2-3 clk/查找│  │
│  └──────────────┘ └──────────────┘ └─────────────┘  │
│                                                     │
│  对外查找接口 (所有模式不变)                          │
│  表项控制接口 (各模式可不同)                          │
└─────────────────────────────────────────────────────┘
```

### 2.3 统一查找接口（不可变）

```verilog
module mac_whitelist #(
    parameter int LOOKUP_MODE = 0,     // 0=顺序, 1=二分, 2=Hash
    parameter int ENTRY_NUM   = 16,    // 白名单容量
    parameter int ADDR_WIDTH  = 4      // $clog2(ENTRY_NUM)
) (
    input                       clk,           // 125MHz
    input                       reset_l,

    // === 查找端口（125MHz，所有模式共用，接口不可变） ===
    input                       lookup_req,      // 查找请求（脉冲）
    input  [47:0]               lookup_mac,      // 目标 MAC 地址
    output                      lookup_match,    // 1=命中（在 lookup_done 时有效）
    output                      lookup_done,     // 查找完成（脉冲，N 周期后）
    output                      lookup_busy,     // 1=正在查找中

    // === LCPU 总线配置端口（50MHz cfg_clk，标准 LCPU bus 接口） ===
    input                       cfg_clk,         // 50MHz CPU 时钟
    input                       cfg_reset_l,
    input                       cfg_req,         // LCPU bus req
    input                       cfg_rhwl,        // 0=write, 1=read
    input  [31:0]               cfg_wdata,       // 写数据
    input  [15:0]               cfg_address,     // 寄存器地址
    output [31:0]               cfg_rdata,       // 读数据
    output                      cfg_ack,         // 操作应答

    // === 全局控制 ===
    input                       whitelist_en,    // 白名单总开关
    input                       default_pass     // 关闭时的策略: 0=全断, 1=全放
);
```

**LCPU 总线配置地址空间：**

| 地址 | 名称 | 类型 | 描述 |
|------|------|------|------|
| 0x00 | `WL_ENTRY_INDEX` | RW | 操作目标条目索引 [3:0] |
| 0x01 | `WL_ENTRY_MAC_H` | RW | MAC[47:16] |
| 0x02 | `WL_ENTRY_MAC_L` | RW | MAC[15:0] |
| 0x03 | `WL_ENTRY_WR` | WC | 写脉冲: 写入 index+MAC |
| 0x04 | `WL_ENTRY_DEL` | WC | 删脉冲: 删除 index |
| 0x05 | `WL_ENTRY_CLEAR` | WC | 清空全部 |
| 0x06 | `WL_ENTRY_RD_MAC_H` | RO | 读回 MAC[47:16] |
| 0x07 | `WL_ENTRY_RD_MAC_L` | RO | 读回 MAC[15:0] |
| 0x08 | `WL_ENTRY_RD_VALID` | RO | 读回有效位 [0] |
| 0x09 | `WL_ENTRY_FREE_IDX` | RO | 空闲索引 [7:0], FF=表满 |
| 0x0A | `WL_MAX_ENTRIES` | RO | 最大条目数 |
| 0x0B | `WL_USED_CNT` | RO | 已用条目数 |
| 0x0C | `WL_MATCH_CNT_L` | RO | 命中计数[31:0] |
| 0x0D | `WL_MATCH_CNT_H` | RO | 命中计数[63:32] |
| 0x0E | `WL_DROP_CNT_L` | RO | 丢弃计数[31:0] |
| 0x0F | `WL_DROP_CNT_H` | RO | 丢弃计数[63:32] |

> **说明**：`mac_whitelist` 作为一个独立模块，自带 LCPU 总线从机接口。在 `webserver_wrapper` 中通过 `reg_webserver` 的 SubBus 机制接入（类似 `lcpu_mdio` 的方式），CPU 通过 SubBus 地址空间直接读写白名单寄存器。**白名单控制寄存器不再放入 reg_webserver.xls**，而是作为 mac_whitelist 模块内部寄存器，通过 SubBus 访问。

### 2.4 模式 0：BRAM 顺序查找（本次实现）

```verilog
module mac_whitelist_seq #(
    parameter int ENTRY_NUM  = 16,
    parameter int ADDR_WIDTH = 4
) (
    input                       clk,             // 125MHz
    input                       reset_l,

    // 查找端口（不变）
    input                       lookup_req,
    input  [47:0]               lookup_mac,
    output reg                  lookup_match,
    output reg                  lookup_done,
    output                      lookup_busy,

    // LCPU 总线配置端口（50MHz）
    input                       cfg_clk,
    input                       cfg_reset_l,
    input                       cfg_req,
    input                       cfg_rhwl,
    input  [31:0]               cfg_wdata,
    input  [15:0]               cfg_address,
    output [31:0]               cfg_rdata,
    output                      cfg_ack,

    // 全局控制
    input                       whitelist_en,
    input                       default_pass
);
```

**LCPU 总线配置实现要点：**
- 模块内部维护一个简单的寄存器读写状态机（类似 reg_webserver 的模式）
- `cfg_req` + `cfg_address` 选择目标寄存器
- `cfg_rhwl=0` 时写寄存器，`cfg_rhwl=1` 时读寄存器
- 写 MAC 条目流程：写 MAC_H → 写 MAC_L → 写 INDEX → 触发 WR 脉冲
- BRAM 写端口使用 cfg_clk 域，读端口使用 clk(125MHz) 域（真双口 BRAM）

**内部实现要点：**

```verilog
// 状态机
localparam S_IDLE    = 2'd0;
localparam S_COMPARE = 2'd1;
localparam S_DONE    = 2'd2;

reg [1:0]               state;
reg [ADDR_WIDTH-1:0]    cmp_index;       // 当前比较的条目索引
reg                     match_found;     // 已找到匹配

// Block RAM: 简单双口 RAM
//   Port A: 125MHz 读端口（查找用）
//   Port B: cfg_clk 写端口（CPU 配置用）
reg [47:0] mac_bram [0:ENTRY_NUM-1];  // 综合为 BRAM
reg        valid_bram [0:ENTRY_NUM-1]; // 综合为 BRAM（或打包在 mac_bram 中 bit[48]）

// BRAM 读地址
wire [ADDR_WIDTH-1:0] bram_rd_addr;
assign bram_rd_addr = (state == S_COMPARE) ? cmp_index : {ADDR_WIDTH{1'b0}};

// BRAM 读数据
wire [47:0] bram_rd_mac;
wire        bram_rd_valid;
assign bram_rd_mac   = mac_bram[bram_rd_addr];
assign bram_rd_valid = valid_bram[bram_rd_addr];

// 状态转移
always @(posedge clk or negedge reset_l) begin
    if (!reset_l) begin
        state        <= S_IDLE;
        cmp_index    <= 0;
        match_found  <= 0;
        lookup_match <= 0;
        lookup_done  <= 0;
    end else begin
        lookup_done <= 0;
        case (state)
            S_IDLE: begin
                if (lookup_req) begin
                    state       <= S_COMPARE;
                    cmp_index   <= 0;
                    match_found <= 0;
                end
            end
            S_COMPARE: begin
                // 本周期比较 bram_rd_mac vs lookup_mac（BRAM 读延迟1周期后数据有效）
                if (cmp_index > 0 && bram_rd_valid && (bram_rd_mac == lookup_mac))
                    match_found <= 1;

                if (cmp_index == ENTRY_NUM - 1) begin
                    state <= S_DONE;
                end else begin
                    cmp_index <= cmp_index + 1;
                end
            end
            S_DONE: begin
                // 注意：最后一个条目的比较结果在下个周期才有效
                // 所以 S_COMPARE 最后一条比较在进入 S_DONE 时锁存
                if (whitelist_en)
                    lookup_match <= match_found;
                else
                    lookup_match <= default_pass;
                lookup_done <= 1;
                state       <= S_IDLE;
            end
        endcase
    end
end

assign lookup_busy = (state != S_IDLE);
```

**关键时序分析：**
- BRAM 读延迟：1 个时钟周期
- IDLE → 发读地址 addr=0
- CMP 0: 数据 addr=0 有效，比较；同时发读地址 addr=1
- CMP 1: 数据 addr=1 有效，比较；同时发读地址 addr=2
- ...
- CMP 14: 数据 addr=14 有效；发读地址 addr=15
- CMP 15: 数据 addr=15 有效，比较
- DONE: 输出结果

- 总延迟：IDLE(1) + CMP0~CMP15(16) + DONE(1) = **18 个时钟周期**
- 18 × 8ns(125MHz) = 144ns
- 千兆最小帧间隔（64B + 20B preamble+IFG = 84B = 672ns）远大于 144ns
- **结论：顺序查找不会成为瓶颈**

### 2.5 模式 1：二分法查找（预留骨架）

- 要求 BRAM 中 MAC 按升序排列
- 查找 log₂16 = 4 次 BRAM 读 + 状态机开销 ≈ 8 周期
- CPU 写入时需维护排序

### 2.6 模式 2：布谷鸟哈希（预留骨架）

- 两个 Hash 函数，每 MAC 只有 2 个候选位置
- 查找 2 周期，但写入可能触发 cuckoo eviction
- 适合 >64 条目场景

### 2.7 BRAM 资源（模式 0，16 条目）

- 49 bit × 16 = 784 bit → 1 个 BRAM36 (36Kbit) 绰绰有余
- 或映射为分布式 RAM（16 深度的寄存器 + LUT RAM）

---

## 3. 二层透明桥接（L2 Transparent Bridge）

### 3.1 桥接原理

```
eth1 (LAN)                           eth2 (WAN)
  │                                     │
  │  收到的帧                            │
  │  ┌─────────────────────────┐        │
  │  │ DstMAC | SrcMAC | Type  │        │
  │  │ ...payload...           │──── ──►│ 原样转发
  │  │ ...CRC                  │        │
  │  └─────────────────────────┘        │
  │                                     │
  │  不修改 MAC / IP / TTL / Checksum  │
  │  纯二层透传                          │
```

**桥接规则（简化后）：**

| 方向 | 条件 | 动作 |
|------|------|------|
| eth0 RX | 任意 | 送 CPU 协议栈（管理报文，独立管理网段） |
| eth1 → eth2 | 源 MAC 在白名单中 | 转发到 eth2 TX（纯硬件） |
| eth1 → eth2 | 源 MAC 不在白名单 | **丢弃**，累加 drop_cnt |
| eth1 → eth2 | 白名单关闭 | 默认策略决定（全断/全放） |
| eth2 → eth1 | 任意 | **直接透传**到 eth1 TX（纯硬件，不查白名单） |
| CPU → eth0 | 管理应答 | 发送到 eth0 TX |

### 3.2 硬件桥接数据通路（简化版）

> **2026-07-07 简化**：eth1/eth2 为纯硬件 L2 桥接，不送报文到 CPU。
> 管理功能全部通过 eth0（独立管理网段）完成。

```
eth1 RX (LAN)
  │
  ├─[ram2pktfifo_int]──► 缓冲前 14 字节（提取 SrcMAC）
  │                           │
  │                     ┌─────┴──────┐
  │                     │ 白名单查找  │
  │                     │ lookup_req │──► mac_whitelist
  │                     └─────┬──────┘
  │                           │
  │              ┌────────────┴───────────┐
  │              │ match?                  │
  │           yes│                         │no
  │              ▼                         ▼
  │     eth2 TX 转发              丢弃 + drop_cnt++
  │    (纯硬件，不经CPU)

eth2 RX (WAN)
  │
  └─[ram2pktfifo_int]──► eth1 TX 转发（无条件透传，纯硬件）

eth0 RX (Management)
  │
  └─[ram2pktfifo_int]──► CPU RX FIFO（全部报文，管理口独立网段）
```

### 3.3 转发实现要点

- 硬件桥接需要**包缓存**：收完 eth1 的完整帧（CRC 校验通过）后再转发到 eth2
- 利用现有的 `package_fifo_v2` 做跨时钟域缓存（但这里 eth1/eth2 同频 125MHz，可优化）
- 转发路径：`ram2pktfifo_int(pkt) → package_fifo → pktfifo2ram_int → mac_tx`
- 简化版（同频）：直接在 `ram2pktfifo_int` 的写端口和 `pktfifo2ram_int` 的读端口之间做直通，中间插入白名单判断

---

## 4. SPI Flash 持久化

### 4.1 Flash 型号与特性

| 项目 | 参数 |
|------|------|
| 型号 | **MX25L12845** (Macronix 旺宏) |
| 容量 | 128Mbit = **16MB** |
| 接口 | SPI / Dual SPI / Quad SPI (QPI) |
| 模式 | SPI Mode 0 (CPOL=0, CPHA=0) |
| 页大小 | 256 Bytes |
| 扇区大小 | 4KB / 32KB / 64KB |
| 块大小 | 64KB |
| 擦写寿命 | 典型 100,000 次/扇区 |
| 供电 | 2.7V - 3.6V |
| JEDEC ID | C2h (MFR) + 20h (Type) + 18h (Capacity) |

### 4.2 现有 Flash 基础设施

项目已有完整的 SPI Flash 操作模块（位于 `~/work/ip_common/rtl/`）：

| 模块 | 功能 | 兼容性 |
|------|------|--------|
| `lcpu_sflash.v` | LCPU 总线 → SPI Flash 控制器 | ✅ 标准 SPI 命令集，兼容 MX25L12845 |
| `spi_ctrl.v` | SPI Master 控制器（CPOL=0, CPHA=0） | ✅ SPI Mode 0 匹配 |
| `qspi_ctrl.v` | Quad SPI 控制器 | ✅ 预留 Quad 模式加速 |
| `w25q32_bfm.sv` | W25Q32 仿真模型 | 需替换为 MX25L12845 BFM |

> **注意**：需要新建 `mx25l12845_bfm.sv` 仿真模型（或以 W25Q32 BFM 为模板，修改 JEDEC ID、容量参数适配 MX25L12845 的 16MB 空间）。

### 4.3 Flash 分区规划（MX25L12845, 16MB）

```
┌──────────────────────────────────────────────┐  0x000000
│  FPGA Bitstream                               │
│  ~4MB (XC7A35T SPI x4 配置数据)              │
├──────────────────────────────────────────────┤  0x400000
│  RISC-V Firmware (InstructRAM BIN)           │
│  ~128KB                                       │
├──────────────────────────────────────────────┤  0x420000
│  Web 页面内容 (HTML/CSS/JS)                  │
│  ~8MB (多页面 + Logo/图片/扩展预留)           │
├──────────────────────────────────────────────┤  0xC20000
│  本机配置 + 白名单配置                        │
│  ~4KB (本机IP/MAC + 白名单表 + CRC校验)      │
│  注：占用 1 个 4KB 扇区，独立擦除            │
├──────────────────────────────────────────────┤  0xC21000
│  预留空间                                     │
│  ~7.8MB                                       │
└──────────────────────────────────────────────┘  0x1000000 (16MB)
```

**Flash 扇区分配说明：**

| 分区 | Flash 地址 | 大小 | 说明 |
|------|-----------|------|------|
| FPGA Bitstream | 0x000000 | 4MB | Vivado 生成 SPI x4 配置数据 |
| Firmware | 0x400000 | 128KB | RISC-V 可执行固件 |
| Web 页面 | 0x420000 | 8MB | HTML/CSS/JS/Logo 页面文件 |
| 本机+白名单配置 | 0xC20000 | 4KB | 本机 IP/MAC + MAC 白名单表 + 控制参数 |
| 预留 | 0xC21000 | ~7.8MB | 日志 / 固件备份 / 扩展 |

> **配置扇区独占 4KB**：本机 IP/MAC 和白名单配置合并存储在同一个 4KB 扇区，擦除时一起操作，简化 Flash 管理。

### 4.4 Flash 访问架构

```
                    ┌──────────────────┐
   JTAG (PC)  ◄────►│  LCPU (JTAG主)   │──► lcpu_sflash ──► SPI Flash
                    │  写BIN到Flash     │    (SubBus, 0x1400)
                    └──────────────────┘

                    ┌──────────────────┐
   RISC-V CPU ◄────►│ Flash Read IF    │──► SPI Flash
                    │ (内存映射读)      │    (Read Only)
                    │ 0x9000_0000      │
                    └──────────────────┘
```

**LCPU 写入路径：**
- PC 端通过 JTAG 发 TCL 命令 → LCPU Master
- LCPU 操作 `reg_webserver` 中映射的 `lcpu_sflash` SubBus（新增地址空间 0x1400-0x14FF）
- 实现 Flash Erase → Page Program 流程
- 写入 Web BIN 文件和白名单配置

**RISC-V 读取路径：**
- 新增轻量级 Flash Read 模块，映射到 RISC-V 内存空间 0x90000000
- RISC-V 可以像读普通内存一样读取 Flash 内容
- 启动时从 Flash 加载白名单，运行时根据需要读取 Web 页面发送给客户端

### 4.5 配置数据 Flash 存储格式

**Flash 地址: 0xC20000 (MX25L12845)，占用 1 个 4KB 扇区**

```
Offset  Size    Field
─────────────────────────────────────
0x00    4B      本机配置 Magic: 0x4C434647 ("LCFG")
0x04    2B      Version: 0x0001
0x06    2B      CRC16 (覆盖本机配置区域)

0x08    6B      本机 MAC 地址 (eth0 管理口)
0x0E    4B      本机 IP 地址 (eth0)
0x12    4B      本机子网掩码
0x14    4B      本机网关地址

0x18    4B      eth1 (LAN口) MAC 地址
0x1C    4B      eth2 (WAN口) MAC 地址
0x20    28B     Reserved (本机配置区共 64B)

─────────────────────────────────────
0x40    4B      白名单 Magic: 0x574C4442 ("WLDB")
0x44    2B      Version: 0x0001
0x46    2B      CRC16 (覆盖白名单区域)

0x48    1B      whitelist_enable
0x49    1B      default_pass
0x4A    2B      entry_count
0x4C    4B      Reserved

0x50    16×7B   白名单条目（每条: 6B MAC + 1B valid）
        = 112B
─────────────────────────────────────
        0xC0    (192 bytes total, 扇区剩余空间填 0xFF)
```

**保存操作流程：**
1. 修改本机配置或白名单后触发保存
2. 将当前所有配置序列化到临时 buffer（192 bytes），计算两个 CRC16
3. Flash 操作：Write Enable → Sector Erase(0xC20000) → 等待 → Page Program(256B) → 等待
4. 校验：回读比对

### 4.6 Web 页面 Flash 存储

**Flash 基地址: 0x420000，容量: 8MB**

**写入流程：**
1. 开发者在 PC 上编写 HTML/CSS/JS 页面
2. 将所有页面文件打包为一个 `web_pages.bin` 文件
3. 通过 JTAG TCL 脚本，LCPU 将 `web_pages.bin` 写入 Flash 0x420000

**运行时访问：**
- `http.c` 收到 HTTP GET 请求后，根据 URL 路径计算 Flash 偏移 → 0x420000 + 页面偏移
- 通过 SubBus (lcpu_sflash) 从 Flash 读取 HTML 内容

**Web BIN 文件格式（写入到 Flash 0x420000）：**

```
Offset   Size    Field
0x0000   4B      Magic: 0x57454250 ("WEBP")
0x0004   2B      Version
0x0006   2B      Page Count (页面数量)
0x0008   N×16B   页面索引表 (每条: 4B name_hash + 4B offset + 4B length + 4B content_length)
...              Page 0: 主页 (index.html)
...              Page 1: 白名单配置页 (wlconfig.html)
...              Page 2: 本机配置页 (localconfig.html)
...              ...
```

> **固定偏移简化方案**：
> - `/` 主页：Flash 0x420000 + 0x0100，最大 16KB
> - `/wlconfig` 白名单配置：Flash 0x420000 + 0x4100，最大 16KB
> - `/localconfig` 本机配置：Flash 0x420000 + 0x8100，最大 16KB

---

## 5. 寄存器映射修改（reg_webserver.xls）

### 5.1 寄存器架构说明

```
reg_webserver (LCPU bus slave @ 50MHz)
├── [0x000-0x0FF]  系统寄存器 (现有，不变)
├── [0x100-0x1FF]  统计计数器 (扩展 eth1/eth2)
├── [0x200-0x2FF]  本机网络配置寄存器 (新增)
├── [0x300-0x3FF]  白名单全局控制寄存器 (精简)
├── [0x1000-0x1FFF] eth0 MDIO SubBus (现有)
├── [0x1200-0x12FF] eth1 MDIO SubBus (新增)
├── [0x1300-0x13FF] eth2 MDIO SubBus (新增)
├── [0x1400-0x14FF] SPI Flash SubBus (新增)
├── [0x1500-0x15FF] mac_whitelist SubBus (新增) ← 白名单内部寄存器
├── [0x6000-0x6FFF] CPU 读包 FIFO (现有)
└── [0x6100-0x61FF] CPU 写包 FIFO (现有)
```

> **设计原则**：白名单 BRAM 条目的读写操作通过 `mac_whitelist` 模块的 LCPU 总线接口完成（SubBus 0x1500）。`reg_webserver.xls` 中只保留少量全局控制/状态寄存器。这样 `mac_whitelist` 模块是自包含的，未来替换查找算法时只需换模块，不影响 reg_webserver。

### 5.2 本机网络配置寄存器（0x200-0x20F）

| RegName | RegType | AddrLow | BitLow | BitHigh | ResetVal | Notes |
|---------|---------|---------|--------|---------|----------|-------|
| local_mac_h | RW | 0x202 | d'0 | d'31 | 0x00000102 | 本机 MAC[47:16] (默认 00:00:01:02:04:06) |
| local_mac_l | RW | 0x203 | d'0 | d'15 | 0x0406 | 本机 MAC[15:0] |
| local_ip | RW | 0x204 | d'0 | d'31 | 0xC0A80158 | 本机 IP (默认 192.168.1.88) |
| local_netmask | RW | 0x205 | d'0 | d'31 | 0xFFFFFF00 | 子网掩码 (默认 255.255.255.0) |
| local_gateway | RW | 0x206 | d'0 | d'31 | 0xC0A80101 | 网关地址 (默认 192.168.1.1) |
| local_config_save | WC | 0x207 | d'0 | d'0 | 0x0 | 写脉冲: 保存本机配置到 Flash |
| local_config_load | WC | 0x208 | d'0 | d'0 | 0x0 | 写脉冲: 从 Flash 重新加载本机配置 |
| local_config_valid | RO | 0x209 | d'0 | d'0 | | Flash 中配置数据 CRC 校验通过标志 |

> **注意**：0x200(filter_data) 和 0x201(filter_offset) 保留不变（兼容现有代码），本机配置从 0x202 开始。

### 5.3 白名单全局控制寄存器（0x300-0x303）

| RegName | RegType | AddrLow | BitLow | BitHigh | ResetVal | Notes |
|---------|---------|---------|--------|---------|----------|-------|
| wl_ctrl | RW | 0x300 | d'0 | d'1 | 0x0 | [0]:enable, [1]:default_pass, 默认全断 |
| wl_status | RO | 0x301 | d'0 | d'15 | | [7:0]:lookup_mode, [15:8]:used_cnt |
| wl_lat_match_mac_h | RO | 0x302 | d'0 | d'31 | | 最近命中 MAC[47:16] |
| wl_lat_match_mac_l | RO | 0x303 | d'0 | d'15 | | 最近命中 MAC[15:0] |

### 5.4 MDIO 及 SubBus 扩展

| RegName | RegType | AddrLow | AddrHigh | Notes |
|---------|---------|---------|----------|-------|
| eth1_mdio | SubBus | 0x1200 | 0x12FF | eth1 LAN PHY MDIO |
| eth2_mdio | SubBus | 0x1300 | 0x13FF | eth2 WAN PHY MDIO |
| sflash | SubBus | 0x1400 | 0x14FF | SPI Flash 控制器 |
| mac_whitelist | SubBus | 0x1500 | 0x15FF | MAC 白名单模块 LCPU 总线 (内部寄存器见 2.3 节) |

### 5.5 eth1/eth2 统计计数器（0x110-0x11F）

| RegName | RegType | AddrLow | BitLow | BitHigh | ResetVal | Notes |
|---------|---------|---------|--------|---------|----------|-------|
| eth1_rx_correct_pkt_cnt | RO | 0x110 | d'0 | d'31 | | eth1 LAN |
| eth1_rx_crc_err_pkt_cnt | RO | 0x111 | d'0 | d'31 | | |
| eth1_tx_correct_pkt_cnt | RO | 0x112 | d'0 | d'31 | | |
| eth1_tx_error_pkt_cnt | RO | 0x113 | d'0 | d'31 | | |
| eth1_rx_afifo_full_cnt | RO | 0x114 | d'0 | d'31 | | |
| eth1_rx_afifo_empty_cnt | RO | 0x115 | d'0 | d'31 | | |
| eth1_rx_data_err_line | RO | 0x116 | d'0 | d'31 | | |
| eth2_rx_correct_pkt_cnt | RO | 0x118 | d'0 | d'31 | | eth2 WAN |
| eth2_rx_crc_err_pkt_cnt | RO | 0x119 | d'0 | d'31 | | |
| eth2_tx_correct_pkt_cnt | RO | 0x11A | d'0 | d'31 | | |
| eth2_tx_error_pkt_cnt | RO | 0x11B | d'0 | d'31 | | |
| eth2_rx_afifo_full_cnt | RO | 0x11C | d'0 | d'31 | | |
| eth2_rx_afifo_empty_cnt | RO | 0x11D | d'0 | d'31 | | |
| eth2_rx_data_err_line | RO | 0x11E | d'0 | d'31 | | |

### 5.6 生成命令

```bash
python3 ~/wwwroot/python/regGenAll.py \
    --RegFilePath "fpga_webserver/rtl/" \
    --ExcelFile "reg_webserver.xls"
```

---

## 6. RTL 修改方案

### 6.1 文件变更总览

```
fpga_webserver/rtl/
├── reg_webserver.xls                   # [修改] 新增寄存器条目
├── reg_webserver.v                     # [重新生成]
├── mac_whitelist_seq.v                 # [新增] 模式0: BRAM顺序查找引擎
├── mac_whitelist_bin.v                 # [新增] 模式1: 二分法骨架(预留)
├── mac_whitelist_hash.v                # [新增] 模式2: Hash骨架(预留)
├── mac_whitelist_top.v                 # [新增] 顶层封装
├── cpu_channel_tri.v                   # [新增] 三端口桥接通道（含L2桥接）
├── flash_mem_reader.v                  # [新增] RISC-V Flash 内存映射读接口
├── webserver_wrapper.v                 # [修改] 例化三网口+白名单+Flash
├── xilinx_xc7a35tfgg484_webserver_top.v # [修改] 添加1000BASE-X + eth1/eth2
```

### 6.2 mac_whitelist_seq.v — BRAM 顺序查找引擎

参见 2.4 节详细设计。

### 6.3 cpu_channel_tri.v — 三端口 L2 桥接通道（简化版）

> **简化**：eth1/eth2 为纯硬件 L2 桥接，不送报文到 CPU。管理全部通过 eth0。

```
端口:
  eth0 端口（管理口）
    mac0_rx_* → CPU (全部报文，独立管理网段)
    CPU → mac0_tx_* (管理应答)

  eth1 端口（LAN）
    mac1_rx_* → 提取 SrcMAC → 白名单查找 → eth2 TX (转发)
                                     ↘ 丢弃 (白名单拦截)

  eth2 端口（WAN）
    mac2_rx_* → eth1 TX (无条件透传)

  CPU 读端口（仅 eth0）    rd_pkt_fifo
  CPU 写端口（仅 eth0）    wr_pkt_fifo
```

### 6.4 flash_mem_reader.v — Flash 内存映射读接口

```verilog
// flash_mem_reader — RISC-V 直接读 SPI Flash 的桥接模块
//
// 将 SPI Flash 内容映射到 RISC-V 地址空间 (0x90000000 + offset)
// 实现: 接到 LCPU 总线，当 CPU 读 0x9000xxxx 地址时，
// 自动通过 lcpu_sflash 从 Flash 读取对应地址的数据
//
// 简化实现: 直接用 lcpu_sflash 的连续读模式
// CPU 读一个 word 时，发 Read 命令到 Flash，等待 SPI 返回数据

module flash_mem_reader (
    input           clk,          // 50MHz CPU clock
    input           reset_l,
    
    // LCPU bus slave (接 reg_webserver)
    input           op_req,
    input           wrl_rdh,      // 仅支持读 (wrl_rdh=1)
    input  [31:0]   address,      // Flash offset address
    output [31:0]   rddata,
    output          op_ack,
    
    // SPI Flash 接口
    output          flash_sclk,
    output          flash_mosi,
    input           flash_miso,
    output          flash_cs_n
);
```

> **初期简化方案**：不新增 `flash_mem_reader`，直接复用 `lcpu_sflash` SubBus 做 Flash 读。RISC-V 通过 `reg_webserver` 的 SubBus 地址空间 0x1400 读取 Flash。速度较慢但实现简单，Web 页面数据量不大时可以接受。后续再优化为内存映射方案。

### 6.5 webserver_wrapper.v 修改要点

```verilog
// 新增例化:
gmii2mac i_eth1 (...);   // eth1 LAN
gmii2mac i_eth2 (...);   // eth2 WAN
mac_whitelist_top #(.LOOKUP_MODE(0), .ENTRY_NUM(16)) u_mac_wl (...);
cpu_channel_tri u_cpu_channel_tri (...);
lcpu_mdio u_lcpu_mdio_eth1 (...);
lcpu_mdio u_lcpu_mdio_eth2 (...);
lcpu_sflash u_lcpu_sflash (...);  // Flash 控制器

// 新增 CDC 同步:
// eth1 统计计数器 (125MHz → 50MHz)
// eth2 统计计数器 (125MHz → 50MHz)
// 白名单查找完成信号 (125MHz → 50MHz)
```

### 6.6 xilinx_xc7a35tfgg484_webserver_top.v 修改要点

```verilog
// 新增 I/O:
// eth1 1000BASE-X 差分对 (txp/txn, rxp/rxn)
// eth2 1000BASE-X 差分对 (txp/txn, rxp/rxn)
// SPI Flash 引脚 (SCK, MOSI, MISO, CS, WP, RST)

// 新增 IP 例化:
// Xilinx Gigabit Ethernet PCS/PMA (1000BASE-X) ×2
//   配置: 1000BASE-X mode, GMII internal interface
//   时钟: 共享 125MHz refclk
```

---

## 7. C 代码修改方案

### 7.1 新增 local_config.c / local_config.h（本机配置管理）

```c
// local_config.h — 本机 IP/MAC 配置管理
#ifndef _LOCAL_CONFIG_H
#define _LOCAL_CONFIG_H

// Flash 配置区基地址 (MX25L12845)
#define FLASH_CONFIG_BASE   0x00C20000   // 本机+白名单配置扇区

// 本机配置结构体
typedef struct {
    uint8_t  mac[6];        // eth0 管理口 MAC
    uint32_t ip;            // eth0 IP 地址
    uint32_t netmask;       // 子网掩码
    uint32_t gateway;       // 网关地址
    uint8_t  mac_eth1[6];   // eth1 LAN 口 MAC
    uint8_t  mac_eth2[6];   // eth2 WAN 口 MAC
} local_config_t;

// 初始化和 Flash 加载
void local_config_init(void);             // 上电: 从 Flash 加载本机配置
void local_config_get(local_config_t *c);  // 获取当前配置
int  local_config_set(local_config_t *c);  // 更新配置（写寄存器+保存Flash）
int  local_config_save_to_flash(void);     // 手动保存
int  local_config_load_from_flash(void);   // 手动重新加载

#endif
```

### 7.2 whitelist.c / whitelist.h（白名单 API，通过 SubBus 0x1500 操作）

```c
// whitelist.h
#ifndef _WHITELIST_H
#define _WHITELIST_H

// mac_whitelist SubBus 基地址 → 通过 reg_webserver SubBus 0x1500 访问

// 白名单内部寄存器偏移（对应 mac_whitelist LCPU 地址空间）
#define WL_REG_ENTRY_INDEX      0x00
#define WL_REG_ENTRY_MAC_H      0x01
#define WL_REG_ENTRY_MAC_L      0x02
#define WL_REG_ENTRY_WR         0x03
#define WL_REG_ENTRY_DEL        0x04
#define WL_REG_ENTRY_CLEAR      0x05
#define WL_REG_ENTRY_RD_MAC_H   0x06
#define WL_REG_ENTRY_RD_MAC_L   0x07
#define WL_REG_ENTRY_RD_VALID   0x08
#define WL_REG_ENTRY_FREE_IDX   0x09
#define WL_REG_MAX_ENTRIES      0x0A
#define WL_REG_USED_CNT         0x0B

// 通过 SubBus 0x1500 读写 mac_whitelist 内部寄存器
// SubBus 读写函数（利用现有 lcpu_reg_write/lcpu_reg_read 模式）
#define WL_REG_WRITE(addr, data)  lcpu_subusb_write(0x1500, (addr), (data))
#define WL_REG_READ(addr)         lcpu_subusb_read(0x1500, (addr))

// 初始化和 Flash 加载
void whitelist_init(void);
int  whitelist_save_to_flash(void);
int  whitelist_load_from_flash(void);

// 全局控制
void whitelist_enable(uint8_t enable);
uint8_t whitelist_is_enabled(void);

// 条目操作（操作 mac_whitelist BRAM，成功后写 Flash）
int  whitelist_add(uint8_t mac[6]);
int  whitelist_delete(uint8_t index);
int  whitelist_get_entry(uint8_t index, uint8_t mac_out[6]);
void whitelist_clear_all(void);
uint16_t whitelist_get_max_entries(void);
uint16_t whitelist_get_used_count(void);

#endif
```

### 7.3 Flash 读写底层

```c
// 通过 lcpu_sflash SubBus (0x1400) 访问 MX25L12845 Flash
void flash_read(uint32_t flash_addr, uint8_t *buf, uint32_t len);
void flash_write_page(uint32_t flash_addr, uint8_t *buf, uint32_t len);
void flash_erase_sector_4k(uint32_t flash_addr);
void flash_erase_block_64k(uint32_t flash_addr);
```

### 7.4 http.c 修改 — 多页面 + API 路由

```c
// HTTP 路由表:
//   GET  /              → Flash 0x420100 → 主页 HTML
//   GET  /wlconfig      → Flash 0x424100 → 白名单配置页 HTML
//   GET  /localconfig   → Flash 0x428100 → 本机配置页 HTML

// Flash 页面偏移
#define WEB_BASE            0x00420000
#define WEB_HOME_OFFSET     0x0100     // 主页
#define WEB_HOME_MAXLEN      0x4000    // 16KB
#define WEB_WLCFG_OFFSET    0x4100     // 白名单配置页
#define WEB_WLCFG_MAXLEN     0x4000
#define WEB_LOCCFG_OFFSET   0x8100     // 本机配置页
#define WEB_LOCCFG_MAXLEN    0x4000

// API 路由:
//   白名单:
//     POST /api/wl/add     → JSON
//     POST /api/wl/delete   → JSON
//     POST /api/wl/clear    → JSON
//     POST /api/wl/toggle   → JSON
//     GET  /api/wl/status   → JSON
//     GET  /api/wl/list     → JSON
//     POST /api/wl/save     → JSON
//     POST /api/wl/reload   → JSON
//   本机配置:
//     GET  /api/local/status → JSON (当前IP/MAC/掩码/网关)
//     POST /api/local/save   → JSON (保存新IP/MAC配置)
```

### 7.5 完整 HTTP 路由表

| 方法 | 路径 | 响应来源 |
|------|------|----------|
| GET | `/` | Flash 读取 → 主页 HTML |
| GET | `/wlconfig` | Flash 读取 → 白名单配置页 HTML |
| GET | `/localconfig` | Flash 读取 → 本机配置页 HTML |
| POST | `/api/wl/add` | JSON: 添加 MAC → 写 mac_whitelist BRAM + Flash |
| POST | `/api/wl/delete` | JSON: 删除条目 |
| POST | `/api/wl/clear` | JSON: 清空全部 |
| POST | `/api/wl/toggle` | JSON: 开关白名单 |
| GET | `/api/wl/status` | JSON: 白名单状态 |
| GET | `/api/wl/list` | JSON: 条目列表 |
| POST | `/api/wl/save` | JSON: 手动保存到 Flash |
| POST | `/api/wl/reload` | JSON: 从 Flash 重新加载 |
| GET | `/api/local/status` | JSON: 本机 IP/MAC/掩码/网关 |
| POST | `/api/local/save` | JSON: 保存新本机配置 → 寄存器 + Flash |

### 7.6 designApp.c 修改

```c
void designApp() {
    lcpu_baseaddr->sw_build_date = BUILD_DATE;
    lcpu_baseaddr->sw_build_time = BUILD_TIME;
    tcp_connection_init();
    
    // 从 Flash 加载本机配置 (IP/MAC)
    local_config_init();
    // 从 Flash 加载白名单
    whitelist_init();

    while (1) {
        heart_beat_mod2();
        tcp_periodic_check();
        
        if (!LCPU_RD_EMPTY()) {
            LCPU_RD_START_PACKET();
            rec_pkt_len = LCPU_RD_PKT_LEN();
            if (LCPU_WR_TEST_ENABLE()) {
                cp_fifo_test(rec_pkt_len);
            } else {
                eth_proc_result = eth_proc();
                // ... 现有协议栈处理不变 ...
            }
        }
    }
}
```

### 7.7 lcpu_general.h 修改

在本机 IP/MAC 不再硬编码为宏，改为从寄存器中读取：

```c
// 旧: #define Local_IP_ADDR 0xC0A80158
// 新: 从 reg_webserver 0x204 读取
#define GET_LOCAL_IP()      (lcpu_baseaddr->local_ip)
#define GET_LOCAL_MAC_H()   (lcpu_baseaddr->local_mac_h)
#define GET_LOCAL_MAC_L()   (lcpu_baseaddr->local_mac_l)
```

> **注意**：IP 地址运行时可变后，eth_proc()/ip_proc()/arp_reply() 中原来使用 `Local_IP_ADDR` / `Local_MAC_HIGH` / `Local_MAC_LOW` 宏的地方需要改为从寄存器读取。但这在每包处理时读寄存器略有开销，可在 `local_config_init()` 时缓存到全局变量 `g_local_ip` / `g_local_mac_high` / `g_local_mac_low`。

---

## 8. HTML 页面规划

### 8.1 三个页面总览

```
主页 (/)
  ├── [本机配置] ──► /localconfig   (配置本机 IP/MAC)
  └── [白名单配置] ─► /wlconfig     (MAC 白名单管理)
  
两个配置页都有 [◀ 返回首页] 按钮
```

### 8.2 主页 `/` — 产品展示

```
┌──────────────────────────────────────────────────┐
│                                                  │
│         ╔══════════════════════════════╗          │
│         ║                              ║          │
│         ║   RiscV@FPGA 嵌入式网关      ║          │
│         ║   MAC 白名单上网控制系统      ║          │
│         ║                              ║          │
│         ║   基于 RISC-V 处理器         ║          │
│         ║   + FPGA 硬件加速            ║          │
│         ║   千兆线速 MAC 白名单过滤    ║          │
│         ║                              ║          │
│         ║   Layer-2 Transparent Bridge ║          │
│         ║   即插即用，安全可靠          ║          │
│         ║                              ║          │
│         ╚══════════════════════════════╝          │
│                                                  │
│         ┌────────────────────────────┐           │
│         │      [ 本机配置 ]          │           │
│         └────────────────────────────┘           │
│         ┌────────────────────────────┐           │
│         │      [ 白名单配置 ]         │           │
│         └────────────────────────────┘           │
│                                                  │
│  本机: 192.168.1.88  │  MAC: 00:00:01:02:04:06  │
│  系统: RISC-V RV32IC @ 50MHz                    │
│  接口: 1×RGMII + 2×1000BASE-X (全部千兆)        │
│  FPGA: Xilinx XC7A35T-FGG484-2                  │
│  版本: YYYY-MM-DD HH:MM:SS                       │
│  Copy Right @ Buck 2026                          │
└──────────────────────────────────────────────────┘
```

### 8.3 本机配置页 `/localconfig` — 配置本机 IP/MAC

```
┌──────────────────────────────────────────────────┐
│  本机网络配置                                     │
│                                                  │
│  ┌─ 当前配置 ──────────────────────────────┐     │
│  │                                          │     │
│  │  MAC 地址: [00:00:01:02:04:06]           │     │
│  │  IP 地址:  [192.168.1.88   ]             │     │
│  │  子网掩码: [255.255.255.0  ]             │     │
│  │  网关地址: [192.168.1.1    ]             │     │
│  │                                          │     │
│  │  LAN 口 MAC:  [00:00:01:02:04:07]        │     │
│  │  WAN 口 MAC:  [00:00:01:02:04:08]        │     │
│  │                                          │     │
│  │  [保存配置]  [从Flash重新加载]            │     │
│  └──────────────────────────────────────────┘     │
│                                                  │
│  ┌─ 提示 ──────────────────────────────────┐     │
│  │ ● 修改 IP 后需要用新 IP 重新访问本页面   │     │
│  │ ● 配置保存到 Flash，断电不丢失           │     │
│  │ ● MAC 地址格式: XX:XX:XX:XX:XX:XX       │     │
│  │ ● IP 地址格式: XXX.XXX.XXX.XXX          │     │
│  └──────────────────────────────────────────┘     │
│                                                  │
│  [◀ 返回首页]                                    │
└──────────────────────────────────────────────────┘
```

### 8.4 白名单配置页 `/wlconfig` — MAC 白名单管理

```
┌──────────────────────────────────────────────────┐
│  MAC 白名单配置                                   │
│                                                  │
│  ┌─ 状态栏 ─────────────────────────────────┐    │
│  │ 白名单: ●已启用 (关闭策略: 全断)          │    │
│  │ 条目: 3/16  拦截: 42  转发: 15238        │    │
│  │ 查找模式: BRAM顺序  最近命中: AA:BB:..:FF│    │
│  │                              [◀ 返回首页] │    │
│  └──────────────────────────────────────────┘    │
│                                                  │
│  ┌─ 控制 ──────────────────────────────────┐     │
│  │ [启用白名单] [禁用白名单]                 │     │
│  │ 关闭策略: ○全断(默认)  ○全放             │     │
│  └──────────────────────────────────────────┘     │
│                                                  │
│  ┌─ 添加 MAC ──────────────────────────────┐     │
│  │ [XX:XX:XX:XX:XX:XX________] [添加]       │     │
│  │ 格式: 6字节十六进制，冒号分隔             │     │
│  └──────────────────────────────────────────┘     │
│                                                  │
│  ┌─ 白名单列表 ────────────────────────────┐     │
│  │ #  │ MAC 地址          │ 状态  │ 操作   │     │
│  │ ───┼───────────────────┼───────┼─────── │     │
│  │ 0  │ 00:11:22:33:44:55 │ 有效  │ [删除] │     │
│  │ 1  │ AA:BB:CC:DD:EE:FF │ 有效  │ [删除] │     │
│  │ ...                      │              │     │
│  │              [清空全部]  [保存到Flash]   │     │
│  │              [从Flash重新加载]           │     │
│  └──────────────────────────────────────────┘     │
│                                                  │
│  [◀ 返回首页]                                    │
└──────────────────────────────────────────────────┘
```

### 8.5 HTML 实现注意事项

1. **Flash 存储**：HTML 内容写入 MX25L12845 Flash，RISC-V 运行时读取
2. **Content-Length**：每个页面单独记录长度，编译进 Flash Index Table
3. **输入验证**：JS 端正则验证 MAC `^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$` 和 IP 格式
4. **操作确认**：删除/清空 用 `confirm()` 弹窗确认
5. **中文字符**：`<meta charset='UTF-8'>`
6. **纯原生实现**：无外部 CSS/JS 库
7. **导航**：配置页统一使用 `<button onclick="location='/'">◀ 返回首页</button>`

---

## 9. 实现阶段划分

### 阶段 1：寄存器表 + RTL 核心模块

| 步骤 | 内容 | 产出 |
|------|------|------|
| 1.1 | 修改 `reg_webserver.xls`，添加全部新寄存器 | xls 文件 |
| 1.2 | 运行 `regGenAll.py` 生成 `reg_webserver.v` | reg_webserver.v |
| 1.3 | 新建 `mac_whitelist_seq.v` BRAM 顺序查找 | 可综合模块 |
| 1.4 | 新建 `mac_whitelist_top.v` + 二分/Hash 骨架 | 封装 + 预留 |
| 1.5 | 新建 `cpu_channel_tri.v` 三端口 L2 桥接 | 可综合模块 |
| 1.6 | 修改 `webserver_wrapper.v` 例化全部新模块 | 顶层 wrapper |
| 1.7 | 修改 `xilinx_xc7a35tfgg484_webserver_top.v` | 平台 top |
| 1.8 | Verilator 仿真验证（ARP/ICMP/白名单增删查/桥接） | 仿真通过 |

### 阶段 2：C 代码开发

| 步骤 | 内容 | 产出 |
|------|------|------|
| 2.1 | 新建 `whitelist.c/h`（SubBus 0x1500 操作 mac_whitelist + Flash 持久化） | API 实现 |
| 2.2 | 新建 `local_config.c/h`（本机 IP/MAC 管理 + Flash 持久化） | API 实现 |
| 2.3 | 更新 `lcpu_general.h` 寄存器结构体 + IP/MAC 改为从寄存器读取 | 头文件 |
| 2.4 | 重写 `http.c` 三页面路由 + 两类 API（白名单 + 本机配置） | HTTP 服务 |
| 2.5 | 更新 `designApp.c` 初始化流程（local_config + whitelist） | 主循环 |
| 2.6 | 编译固件，生成 BIN | firmware_pads.bin |

### 阶段 3：Flash 内容部署 + 板级验证

| 步骤 | 内容 |
|------|------|
| 3.1 | 制作 `web_pages.bin`（index.html + localconfig.html + wlconfig.html） |
| 3.2 | TCL 脚本将 firmware + web_pages 写入 MX25L12845 Flash |
| 3.3 | Xilinx Vivado 综合/布线（含 1000BASE-X IP） |
| 3.4 | 板级测试：eth0 Web 主页访问 |
| 3.5 | 板级测试：配置页 CRUD + Flash 持久化验证 |
| 3.6 | 板级测试：eth1→eth2 白名单过滤 + 全断默认策略 |
| 3.7 | 板级测试：eth2→eth1 回程透传 |
| 3.8 | 板级测试：千兆吞吐量（iperf3 打流） |
| 3.9 | 更新约束文件（pins.xdc, timing.xdc） |

---

## 10. 资源评估（XC7A35T）

| 资源 | 新增量 | 说明 |
|------|--------|------|
| LUT | ~2500-3500 | mac_whitelist_seq(300) + cpu_channel_tri(1200) + gmii2mac×2(300) + 1000BASE-X IP×2(~800) + flash_reader(100) |
| FF | ~1500-2000 | 状态机 + 统计计数器 + BRAM 输出寄存器 |
| Block RAM | +5-8 块 | 白名单 BRAM(1) + eth1 pkt FIFO(2) + eth2 pkt FIFO(2) + 桥接缓冲 |
| GT Transceiver | +2 | 每个 1000BASE-X 占用 1 个 GT（XC7A35T 共 4 个 GT） |
| MMCM | 0 | 复用现有 125MHz |
| IO | +12 pins | 1000BASE-X ×2 (8 diff) + SPI Flash (4) |

---

## 11. 关键技术风险

| 风险 | 影响 | 对策 |
|------|------|------|
| BRAM 顺序查找 18 周期延迟 | 千兆线速丢包 | 最小帧间隔 672ns > 144ns，足够；查表期间流水线缓存后续帧 |
| 三端口 GMII 时钟域 | 数据丢失 | 所有 GMII TX 使用统一 125MHz，RX 各自恢复时钟通过异步 FIFO 隔离 |
| MX25L12845 SPI 命令兼容性 | lcpu_sflash 原为 W25Q32 设计 | MX25L12845 使用相同标准 SPI 命令集（0x03/0x02/0x20/0xD8/0x9F），兼容。仿真需新建 mx25l12845_bfm.sv |
| Flash 写入寿命（擦除次数） | 频繁修改导致 Flash 损坏 | 白名单不是高频操作；加软件防抖；MX25L12845 典型 100,000 次擦除/扇区 |
| Flash 读取速度 vs TCP 发送 | Web 页面加载慢 | SPI 读 ~5MB/s，HTML 页面 < 10KB，读取 < 2ms；后续可升级为 Quad SPI 读 |
| Flash 读取速度 vs TCP 发送 | Web 页面加载慢 | SPI 读 ~5MB/s，HTML 页面 < 10KB，读取 < 2ms；后续可升级为 Quad SPI 读 |
| 1000BASE-X IP 配置复杂度 | 综合失败/功能异常 | 使用 Xilinx Example Design 做参考，逐步调试验证 |
| RGMII 千兆模式 IDELAY 校准 | 数据采样偏移 | 复用现有 RGMII 1Gbps 配置（现有设计已支持千兆） |

---

## 12. 文件变更清单

### 新增文件
```
fpga_webserver/rtl/mac_whitelist_seq.v         # BRAM 顺序查找 + LCPU总线接口
fpga_webserver/rtl/mac_whitelist_bin.v         # 二分法骨架 (预留)
fpga_webserver/rtl/mac_whitelist_hash.v        # Hash骨架 (预留)
fpga_webserver/rtl/mac_whitelist_top.v         # 顶层封装
fpga_webserver/rtl/cpu_channel_tri.v           # 三端口L2桥接
fpga_webserver/rtl/flash_mem_reader.v          # Flash 内存映射读 (可选)
fpga_webserver/c/whitelist.c                   # 白名单API (通过SubBus 0x1500)
fpga_webserver/c/inc/whitelist.h               # 白名单头文件
fpga_webserver/c/local_config.c                # 本机IP/MAC配置管理
fpga_webserver/c/inc/local_config.h            # 本机配置头文件
fpga_webserver/sim/bfm/mx25l12845_bfm.sv       # MX25L12845 Flash BFM (仿真)
fpga_webserver/c_build/web_pages/              # Web 页面源文件目录
fpga_webserver/c_build/web_pages/index.html     # 主页 (产品展示+两个按钮)
fpga_webserver/c_build/web_pages/localconfig.html # 本机配置页 (IP/MAC设置)
fpga_webserver/c_build/web_pages/wlconfig.html  # 白名单配置页
fpga_webserver/c_build/pack_web.py             # Web BIN 打包工具
```

### 修改文件
```
fpga_webserver/rtl/reg_webserver.xls           # 新增寄存器
fpga_webserver/rtl/reg_webserver.v             # 重新生成
fpga_webserver/rtl/webserver_wrapper.v         # 三网口+白名单+Flash
fpga_webserver/rtl/xilinx_xc7a35tfgg484_webserver_top.v  # 1000BASE-X + eth1/2
fpga_webserver/c/http.c                        # Flash读取HTML + API路由
fpga_webserver/c/designApp.c                   # whitelist_init()
fpga_webserver/c/inc/lcpu_general.h            # 新增寄存器字段
build_xilinx_xc7a35tfgg484/pins.xdc            # eth1/2 + SPI Flash 引脚
build_xilinx_xc7a35tfgg484/filelist.cfg        # 新增 RTL 文件
```

### 不受影响的文件
```
fpga_webserver/rtl/altera_ep4ce10f17c6_webserver_top.v  # Altera 不实现
fpga_webserver/c/arp.c / ip.c / tcp.c / icmp.c          # 协议栈不变
fpga_webserver/sim/tb_webserver.cpp/sv                  # 需更新但结构兼容
```

---

*文档结束*
