# FPGA WebServer — Dual-Platform RISC-V Web Server on FPGA

Lightweight FPGA WebServer based on **PicoRV32** RISC-V processor with bare-metal TCP/IP stack.

**Target devices:**
- **Xilinx XC7A35T-FGG484** (Artix-7), RGMII interface, Vivado
- **Altera EP4CE10F17C6** (Cyclone IV E), GMII interface, Quartus II 13.1

## System Architecture

```
┌──────────────────────────────────────────────────────────────┐
│           webserver_top (platform-specific)                   │
│                                                              │
│  ┌──────────┐   ┌──────────────────────────────────────┐    │
│  │  PLL_50M  │──▶│        webserver_wrapper             │    │
│  │  clk_50m  │   │  ┌──────────┐  ┌──────────────┐    │    │
│  │  clk_125m │   │  │ LCPU/JTAG│  │  riscv32_top │    │    │
│  │  clk_200m │   │  │  master  │  │  (PicoRV32)  │    │    │
│  └──────────┘   │  └────┬─────┘  └──────┬───────┘    │    │
│                 │       │               │            │    │
│  ┌──────────┐   │  ┌────▼───────┐ ┌─────▼────────┐  │    │
│  │ rgmii2gmii│◀─▶│  │ lcpu_merge │ │ reg_webserver │  │    │
│  │ (Xilinx) │   │  │ (Arbiter)  │ │ (RegFile+RAM)│  │    │
│  └──────────┘   │  └─────┬──────┘ └──────┬────────┘  │    │
│                 │        │               │            │    │
│  ┌──────────┐   │  ┌─────▼───────────────▼──────┐    │    │
│  │  MDIO    │◀──│  │       cpu_channel            │    │    │
│  └──────────┘   │  │   (Packet FIFO + DMA)       │    │    │
│                 │  └──────────────┬──────────────┘    │    │
│                 │                 │                    │    │
│  ┌──────────┐   │  ┌──────────────▼──────────────┐    │    │
│  │  LED x4  │◀──│  │         gmii2mac             │    │    │
│  └──────────┘   │  │    (Ethernet MAC wrapper)    │    │    │
│                 │  └──────────────────────────────┘    │    │
└──────────────────────────────────────────────────────────┘
```

### PHY Interface

| Platform | PHY | Bridge | Notes |
|----------|-----|--------|-------|
| Xilinx Artix-7 | RGMII (4-bit DDR) | rgmii2gmii → internal GMII | ACX750 dev board |
| Altera Cyclone IV E | GMII (8-bit SDR) | Direct GMII | |

### Memory Map

| Address Range | Peripheral |
|---------------|-----------|
| `0x00000000` | Version Time (RO) |
| `0x0001` | Ethernet Reset (RW) |
| `0x0004-0x0005` | Local Time (RO, 64-bit) |
| `0x0010-0x0011` | Debug RW registers |
| `0x0020-0x0021` | Debug RO registers |
| `0x0030` | LED output (RW, [3:0]) |
| `0x0100-0x0106` | Eth0 statistics counters |
| `0x1000-0x1FFF` | Eth0 MDIO sub-bus |
| `0x6000-0x600F` | CPU read packet FIFO |
| `0x6100-0x610F` | CPU write packet FIFO |
| `0x7000-0x7FFF` | Debug RAM (4KB) |
| `0x00010000-0x0001FFFF` | Instruction RAM (64KB) |
| `0x80000000-0xFFFFFFFF` | External bus (C code `LCPU_REGS` base) |

### Protocol Stack (C Firmware)

- **Link Layer**: Ethernet (MAC filtering)
- **Network Layer**: ARP (request/reply), IP (header parsing/checksum)
- **Transport Layer**: ICMP (ping reply), TCP (SYN/SYN-ACK/ACK/FIN/RST state machine)
- **Application Layer**: HTTP (GET/POST, register read/write via web UI)

## Project Structure

```
fpga_webserver/
├── rtl/                         # RTL source
│   ├── xilinx_xc7a35tfgg484_webserver_top.v
│   ├── altera_ep4ce10f17c6_webserver_top.v
│   ├── webserver_wrapper.v      # Platform-independent core
│   ├── reg_webserver.v          # Register file & address decoder
│   ├── cpu_channel.v            # CPU-MAC data channel
│   └── define.sv
├── c/                           # RISC-V firmware (C)
│   ├── main.c, designApp.c
│   ├── eth.c, arp.c, ip.c, icmp.c, tcp.c, http.c, comlib.c
│   └── inc/                     # Headers
├── c_build/                     # C firmware build
│   ├── Makefile, linker.ld
│   └── bin_to_*.py
├── sim/                         # Simulation
│   ├── Makefile                 # SIM=icarus|verilator
│   ├── tb_webserver.sv
│   └── vendor_stubs, pll_bypass, lcpu_bfm
├── build_xilinx_xc7a35tfgg484/  # Xilinx build config
├── build_altera_ep4ce10f17c6/   # Altera build config
├── ip_vendor/                   # Vendor-specific IP (PLL)
├── tcl/                         # JTAG loading scripts (auto-generated)
└── doc/                         # Documentation
```

## 环境准备（新机器一次性配置）

工程内**无任何绝对路径**，clone 后在任意目录均可构建。需要先装好：

### 1) 工具链

```bash
# RISC-V 交叉编译器 + picolibc（Ubuntu/Debian）
sudo apt install gcc-riscv64-unknown-elf picolibc-riscv64-unknown-elf

# 仿真（可选）
sudo apt install verilator iverilog gtkwave

# 烧录（可选，也可用 Vivado Hardware Manager）
sudo apt install openfpgaloader
```

FPGA 综合工具：Vivado 2024.1（Xilinx）/ Quartus II 13.1（Altera），确保 `vivado`/`quartus` 在 PATH 中，或设 `QUARTUS_ROOT` 环境变量。

### 2) GitHub SSH 权限（必须）

`build_fpga.sh` 构建时会自动从 GitHub 克隆 5 个依赖仓库（`fpga_cpu`/`ip_lcpu`/`ip_riscv`/`ip_common`/`fpga_ila`，均为 `git@github.com:HuanghmBuck/*`）。因此每台机器需要：

1. 生成 SSH key：`ssh-keygen -t ed25519`
2. 公钥添加到 GitHub 账号：https://github.com/settings/keys
3. 账号需有 `HuanghmBuck` 组织上述 5 个仓库的协作者权限
4. 验证：`ssh -T git@github.com` 返回认证成功即 OK

### 3) 克隆即跑

```bash
git clone git@github.com:zhu031227/fpga_webserver.git
cd fpga_webserver
```

之后按 Quick Start 三步走即可，无需修改任何路径。

## Quick Start

### 1. Build RISC-V Firmware

```bash
cd c_build
make          # Compile → bin → pads → tcl/verilog/hex
```

Outputs:
- `out/firmware.elf` — ELF executable
- `out/firmware_pads.bin` — Padded binary (16 KB)
- `../rtl/InstructRAM.v` — Verilog RAM init
- `../tcl/InstructRAM.tcl` — JTAG load script

### 2. Simulation

```bash
cd sim
make sim SIM=icarus     # Icarus Verilog (default)
make sim SIM=verilator  # Verilator
make wave               # GTKWave viewer
```

### 3. FPGA Build

**Xilinx Artix-7 (Vivado):**
```bash
cd build_xilinx_xc7a35tfgg484
./build_fpga.sh 0001
```

**Altera Cyclone IV E (Quartus II):**
```bash
cd build_altera_ep4ce10f17c6
./build_fpga.sh 0001
```

## External Dependencies

Build scripts automatically clone these from local cache or GitHub:
- `ip_lcpu` — JTAG/UART LCPU master
- `ip_riscv` — PicoRV32 RISC-V core
- `ip_common` — Shared infrastructure (Ethernet MAC, packet FIFOs, bus bridges, etc.)

## Design Parameters

| Parameter | Xilinx | Altera |
|-----------|--------|--------|
| Device | XC7A35T-FGG484-2 | EP4CE10F17C6 |
| Clock Input | 50 MHz | 50 MHz |
| System Clocks | 50 / 125 / 200 MHz | 50 / 125 / 200 MHz |
| CPU | PicoRV32 (RV32IC) | PicoRV32 (RV32IC) |
| Instruction RAM | 12288 × 32-bit (48 KB) | 12288 × 32-bit (48 KB) |
| PHY Interface | RGMII | GMII |
| Web Server Port | TCP/80 | TCP/80 |
| Default IP | 192.168.1.88 | 192.168.1.88 |

## MAC 白名单（MAC Whitelist）

### 功能概述

MAC 白名单是一个硬件加速的 MAC 地址过滤模块，用于控制以太网数据包的接入权限。支持三种工作模式：

| 控制位 | 模式 | 行为 |
|--------|------|------|
| `enable=0` | 关闭 | 不检查 MAC，所有包放行 |
| `enable=1, default_pass=0` | 白名单模式 | 仅白名单中的 MAC 可通过 |
| `enable=1, default_pass=1` | 黑名单模式 | 白名单中的 MAC 被拒绝 |

### 硬件架构

```
┌──────────────────────────────────────────────────────────────────┐
│                     mac_whitelist_top                             │
│                                                                    │
│  ┌──────────────┐     ┌──────────────────────────────────────┐   │
│  │  LCPU Bus    │     │        mac_whitelist_seq              │   │
│  │  (SubBus)    │────▶│  ┌────────────┐  ┌────────────────┐  │   │
│  │  cfg_rlwh    │     │  │ Register   │  │  Lookup FSM    │  │   │
│  │  cfg_addr    │     │  │ File       │  │  (clk domain)  │  │   │
│  │  cfg_wdata   │     │  │ (cfg_clk)  │  │                │  │   │
│  │  cfg_rdata   │◀────│  │            │  │                │  │   │
│  └──────────────┘     │  ├────────────┤  │                │  │   │
│                       │  │ cfg_idx    │  │                │  │   │
│                       │  │ cfg_mac    │  │                │  │   │
│                       │  │ valid_bits │  │                │  │   │
│                       │  ├────────────┤  │                │  │   │
│                       │  │ Main BRAM  │  │                │  │   │
│                       │  │ (dual clk) │──▶ 16×49-bit     │  │   │
│                       │  │ PortA:wr   │  │ lookup engine  │  │   │
│                       │  │ PortB:rd   │  │                │  │   │
│                       │  ├────────────┤  │                │  │   │
│                       │  │ Shadow RF  │  │                │  │   │
│                       │  │ 16×49-bit  │──▶ CPU read-back  │  │   │
│                       │  └────────────┘  └────────────────┘  │   │
│                       └──────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

### 模块功能

#### `mac_whitelist_top.v` — 顶层封装
- 纯 RAMIF 透传，无状态机。`cfg_rlwh/addr/wdata/rdata` 直通 `mac_whitelist_seq`
- 支持通过 `LOOKUP_MODE` 参数切换不同查找引擎（当前使用 MODE 0 顺序查找）

#### `mac_whitelist_seq.v` — 核心引擎
内部包含以下子模块：

| 子模块 | 说明 |
|--------|------|
| **Main BRAM** | 双时钟简单双端口 RAM（Port A=cfg_clk 写，Port B=clk 读）。存储 16 条 × 49-bit（48-bit MAC + 1-bit valid） |
| **Shadow Register File** | 16×49-bit 寄存器阵列，组合逻辑读取（零延迟），供 CPU 通过 SubBus 回读 BRAM 内容 |
| **Config Registers** | `cfg_idx`（当前选中条目索引）、`cfg_mac`（暂存的 48-bit MAC 地址），电平敏感写入，无需边沿检测 |
| **valid_bits** | 16-bit 寄存器，每个 bit 标识对应条目是否有效，由 generate 电路生成优先编码器和 popcount |
| **Clear Sequencer** | 简单计数器，逐条目清零 BRAM 和寄存器文件，无需状态机 |
| **Lookup FSM** | 125MHz 时钟域，顺序扫描 16 个条目与输入 MAC 比对（1 IDLE + 16 CMP + 1 DONE = 18 周期 = 144ns） |

### 寄存器映射（SubBus 基地址 0x5000）

| 偏移 | 名称 | 类型 | 位宽 | 说明 |
|------|------|------|------|------|
| `0x00` | `INDEX` | RW | [3:0] | 选择当前操作的条目索引（0-15） |
| `0x01` | `MAC_H` | RW | [31:0] | MAC 地址高 32 位 [47:16] |
| `0x02` | `MAC_L` | RW | [15:0] | MAC 地址低 16 位 [15:0] |
| `0x03` | `WR` | WC | — | 写触发：将 `{1'b1, cfg_mac}` 写入 `BRAM[cfg_idx]` 和寄存器文件，置 valid=1 |
| `0x04` | `DEL` | WC | — | 删除触发：将 `49'b0` 写入 `BRAM[cfg_idx]` 和寄存器文件，置 valid=0 |
| `0x05` | `CLEAR` | WC | — | 全部清零：启动 Clear Sequencer，逐条清零所有条目 |
| `0x06` | `RD_MAC_H` | RO | [31:0] | 回读 `shadow_rf[cfg_idx]` 的 MAC[47:16] |
| `0x07` | `RD_MAC_L` | RO | [15:0] | 回读 `shadow_rf[cfg_idx]` 的 MAC[15:0] |
| `0x08` | `RD_VALID` | RO | [0] | 回读 `shadow_rf[cfg_idx]` 的 valid 位 |
| `0x09` | `FREE_IDX` | RO | [3:0] | 首个空闲条目索引（优先编码器，满时返回全 1） |
| `0x0A` | `MAX_ENTRIES` | RO | [3:0] | 最大条目数（固定 16） |
| `0x0B` | `USED_CNT` | RO | [7:0] | 已用条目数（popcount 电路） |

### 数据通路（LCPU → SubBus → RAMIF → RTL）

```
LCPU C 代码                        RTL 硬件
═══════════                        ════════

subbus_write(base, offset, data)
    │
    ▼
LCPU_REG32_WRITE(addr, data)       riscv_reg.v
    │                               地址 ≥ 0x80000000 → SubBus 转发
    ▼                               SUBBUS_ReqAddr = address[30:0]
reg_webserver.v
    │                               addr ∈ [0x5000, 0x5FFF]
    ▼                               → SUBBUS_mac_whitelist_Req = req
ramintf (AddrBits=12)
    │                               Ram_Addr   = address[11:0]
    │                               Ram_RlWh   = !rhwl (SubBus写时=1)
    │                               Ram_WrData = wdata
    ▼
mac_whitelist_seq
    │                               cfg_rlwh=1 → 电平敏感写译码
    │                               cfg_rlwh=0 → 组合逻辑读 mux
    ▼
case(cfg_addr[3:0])
  4'h0: cfg_idx  <= cfg_wdata[3:0]
  4'h1: cfg_mac[47:16] <= cfg_wdata
  4'h2: cfg_mac[15:0]  <= cfg_wdata
  4'h3: BRAM[cfg_idx] <= {1'b1, cfg_mac}     ← 添加条目
  4'h4: BRAM[cfg_idx] <= 49'b0               ← 删除条目
  4'h5: 启动 Clear Sequencer                  ← 全部清零
```

### 操作时序（软件侧）

**添加 MAC（whitelist_add）：**
```
1. subbus_write(0x5000, 0x00, index)    → 选中条目
2. subbus_write(0x5000, 0x01, mac_h)    → 写入 MAC 高 32 位
3. subbus_write(0x5000, 0x02, mac_l)    → 写入 MAC 低 16 位
4. subbus_write(0x5000, 0x03, 1)        → 触发 WR，写入 BRAM
每次 subbus_write 内部包含一次 flush read（读 0x500A）等待 SubBus 完成
```

**删除 MAC（whitelist_delete）：**
```
1. subbus_write(0x5000, 0x00, index)    → 选中条目
2. subbus_write(0x5000, 0x04, 1)        → 触发 DEL，清零 BRAM[cfg_idx]
```

**回读 MAC（whitelist_hw_read_entry）：**
```
1. subbus_write(0x5000, 0x00, index)    → 设置 cfg_idx
2. subbus_read (0x5000, 0x06)           → 读取 MAC[47:16]（组合逻辑，零延迟）
3. subbus_read (0x5000, 0x07)           → 读取 MAC[15:0]
4. subbus_read (0x5000, 0x08)           → 读取 valid 位
```

**全部清零（whitelist_clear_all）：**
```
1. subbus_write(0x5000, 0x05, 1)        → 启动 Clear Sequencer
   RTL 自动逐周期写入 49'b0 到所有条目（16 个 cfg_clk 周期完成）
```

### 软件架构（C 固件）

```
whitelist.c / whitelist.h
    │
    ├── whitelist_init()        初始化
    ├── whitelist_enable()      启用/禁用（LCPU 寄存器 wl_ctrl）
    ├── whitelist_add()         添加 MAC（软件缓存 + HW 写入）
    ├── whitelist_delete()      删除 MAC（INDEX + DEL 两步操作）
    ├── whitelist_clear_all()   全部清零（CLEAR 命令）
    ├── whitelist_hw_read_entry()   HW BRAM 回读（绕过软件缓存）
    ├── whitelist_hw_get_used_count()  读取 HW 已用条目数
    ├── whitelist_hw_get_free_index()  读取 HW 空闲索引
    └── whitelist_hw_diag()     硬件诊断（原始寄存器读写测试）

tcp.c (HTTP API)
    │
    ├── GET  /api/wl/status     → 返回启用状态 + 已用/最大条目数
    ├── GET  /api/wl/list       → 返回所有有效条目 (idx+MAC)
    ├── GET  /api/wl/diag       → 返回硬件诊断 JSON
    ├── POST /api/wl/add        → 添加 MAC
    ├── POST /api/wl/delete     → 删除 MAC
    ├── POST /api/wl/clear      → 全部清零
    └── POST /api/wl/toggle     → 启用/禁用切换

http.c (HTML/JS 前端)
    │
    └── /wlconfig 页面          白名单管理界面
        ├── 表格：序号 / MAC / 状态 / 操作
        ├── 添加：输入 MAC 地址 → 添加按钮
        ├── 删除：每条目的删除按钮（传 HW 真实索引 e.idx）
        ├── 清空全部、启用/禁用按钮
        └── 实时状态显示（已用条目数 / 最大条目数）
```

### 关键设计决策

| 决策 | 说明 |
|------|------|
| **Shadow Register File 替代 Shadow BRAM** | BRAM 有读延迟，ramintf 在 3 周期采样窗口内无法正确捕获数据。改用寄存器阵列实现组合逻辑读（零延迟），确保 SubBus 回读正确 |
| **电平敏感写入** | `cfg_rlwh` 直接驱动写译码，无边沿检测或 `wr_done` 信号。ramintf 持续拉高 `cfg_rlwh` 3 个周期（对应 SubBus 写事务），写入自动完成，简单可靠 |
| **generate 电路替代 for 循环** | Vivado 无法综合包含 `i = ENTRY_NUM` 退出条件的 for 循环。改用 generate 级联优先编码器（free_idx）和加法器链（used_cnt） |
| **DEL 寄存器（0x04）** | 先写 INDEX 选中条目，再写 DEL 触发删除。两步操作解耦索引选择和删除动作，避免单步操作中的复杂条件判断 |
| **Clear Sequencer 为简单计数器** | 不使用状态机。CLEAR 命令启动计数器，逐周期自增，写入 49'b0 到每个地址，完成后自动停 |

通过 TCL 脚本（`tcl/InstructRAM.tcl`）将固件写入 FPGA 片内 Instruction RAM。子模块的 RAMIF 接口与顶层无缝集成，整个硬件白名单作为 reg_webserver SubBus 地址空间的一个子设备。

## License

Internal project.
