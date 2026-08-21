# SPI Flash 地址划分说明

> 适用项目：`fpga_webserver`（ACX750 板，Xilinx XC7A35T-FGG484）
> Flash 型号：**MX25L12845**（Macronix 旺宏），128Mbit = **16MB**，SPI Mode 0（CPOL=0/CPHA=0）
> 本文说明 Flash 的分区规划：**每个区域存什么、谁在操作、怎么操作**。

---

## 1. Flash 型号与特性

| 项目 | 参数 |
|------|------|
| 型号 | MX25L12845 |
| 容量 | 128Mbit = **16MB**（地址范围 `0x000000 ~ 0xFFFFFF`） |
| 接口 | SPI（/ Dual / Quad） |
| 模式 | SPI Mode 0（CPOL=0, CPHA=0） |
| 页大小 | 256 字节 |
| 扇区大小 | 4KB / 32KB / 64KB |
| 块大小 | 64KB |
| 擦写寿命 | 典型 100,000 次/扇区 |
| JEDEC ID | `C2 20 18`（MFR / Type / Capacity） |

**Flash 引脚（ACX750_CB_PIN.xdc）**：CS=`T19`、MOSI=DQ0=`P22`、MISO=DQ1=`R22`、WP#=DQ2=`P21`、HOLD#=DQ3=`R21`（RTL 里误命名为 `flash_rst_n`，实为 HOLD#，恒 1）。
**SCK 特殊**：接在 **CCLK 专用脚 L12** 上，配置完成后由 `STARTUPE2` 的 `USRCCLKO` 驱动（`xilinx_xc7a35tfgg484_webserver_top.v`）。

---

## 2. Flash 分区总览

```
┌──────────────────────────────────────────────┐  0x000000
│  FPGA Bitstream                               │
│  4MB（SPI x4 配置数据，预留/自举）            │
├──────────────────────────────────────────────┤  0x400000
│  RISC-V Firmware（指令固件）                  │
│  分配 128KB，实际占用 ~24KB（0x5D70 字节）    │
├──────────────────────────────────────────────┤  0x420000
│  Web 页面内容（HTML/CSS/JS）                  │
│  8MB（规划中，当前 HTML 内嵌在固件里）        │
├──────────────────────────────────────────────┤  0xC20000
│  本机配置 + MAC 白名单                        │
│  4KB（1 个 4KB 扇区，独立擦除）               │
├──────────────────────────────────────────────┤  0xC21000
│  预留空间（日志 / 固件备份 / 扩展）           │
│  ~3.87MB                                       │
└──────────────────────────────────────────────┘  0x1000000 (16MB)
```

| 分区 | Flash 地址 | 分配大小 | 实际使用 | 状态 | 内容 |
|------|-----------|---------|---------|------|------|
| FPGA Bitstream | `0x000000` | 4MB | 0（当前未用） | ⏳ 预留 | Vivado SPI x4 配置数据（自举） |
| Firmware | `0x400000` | 128KB | `0x5D70` 字节（5980 字） | ✅ **已实现** | RISC-V 可执行固件 |
| Web 页面 | `0x420000` | 8MB | 3 页 + TOC（~16KB） | ✅ **已实现** | HTML 页面（flash_mem_reader 内存映射读） |
| 本机+白名单配置 | `0xC20000` | 4KB | 1 个扇区 | ✅ **已实现** | 本机 IP/MAC + 白名单表 + CRC |
| 预留 | `0xC21000` | ~3.87MB | 0 | ⏳ 预留 | 日志 / 固件备份 / 扩展 |

> **两处勘误（相对设计文档 V4）**：
> 1. 设计文档写 Firmware「128KB」，实际固件只有 `0x5D70` 字节（23920 字节 = 5980 字），写入时只擦 6 个 4KB 扇区（`0x400000~0x405FFF`，24KB）。128KB 是给未来固件增长预留的。
> 2. 设计文档写「预留 ~7.8MB」，实际 `0x1000000 - 0xC21000 = 0x3DF000 ≈ 3.87MB`（文档笔误）。

---

## 3. 各分区详细说明

### 3.1 FPGA Bitstream —— `0x000000 ~ 0x3FFFFF`（4MB）

| 项 | 说明 |
|----|------|
| 保存什么 | FPGA 配置数据（Vivado 生成 SPI x4 `.bin`/`.mcs`） |
| 谁来操作 | **PC（Vivado）**；自举时由 FPGA 内部配置逻辑读 |
| 如何操作 | 当前开发流程用 **JTAG 直接配置**（Vivado "Program Device" 下载 `.bit`），**不经过 Flash**。此分区是给「上电自举（Master SPI）」预留的，目前 Flash 该区域未使用 |

> 说明：Flash 的 SCK 接在 CCLK（配置专用脚），其余引脚在 bank14 普通 I/O，硬件上当前按「用户数据 Flash」方式使用（见 3.2~3.4），未走 FPGA 自举。若要启用自举，需用 Vivado `write_cfgmem` 生成 `.mcs` 并烧入 `0x000000`。

### 3.2 RISC-V Firmware —— `0x400000 ~ 0x405D6F`（实际 `0x5D70` 字节）

| 项 | 说明 |
|----|------|
| 保存什么 | RISC-V（PicoRV32）可执行固件，即 WebServer + MAC 白名单程序的机器码 |
| 谁来操作 | **写**：PC（JTAG）经 `lcpu_sflash`；**读**：`spi_bootloader` 硬件模块 |
| 首字 | `0x400000` = `0x40D0006F`（RISC-V 复位向量） |

**① 写入 Flash（擦除 + 编程）**

- 脚本：`tcl/Instruct_flash_initial.tcl`（自包含，固件字内嵌，无需 `.bin` 文件）
- 前置（Vivado Tcl Console）：`source ip_lcpu/tcl/jtag_slib.tcl ; jopen`
- 流程：
  1. 复位 RISC-V：`jwrite 0xF 0x0`
  2. 擦除 6 个 4KB 扇区：`0x400000`、`0x401000`、`0x402000`、`0x403000`、`0x404000`、`0x405000`（命令 `0x20` Sector Erase）
  3. 逐字编程 5980 个字（命令 `0x02` Page Program，每字先 `0x06` WREN）
- 固件在 Flash 里的写入路径：`PC(JTAG) → LCPU → lcpu_sflash → SPI Flash`

**② 从 Flash 加载到指令 RAM（上电/运行）**

- 脚本：`tcl/Instruct_load2fpga.tcl`
- 流程：
  1. 复位 RISC-V：`jwrite 0xF 0x0`
  2. 配置 bootloader：`jwrite 0x312 0x400000`（源地址）、`jwrite 0x313 0x5D70`（长度）
  3. 触发：`jwrite 0x310 0x1`
  4. 轮询 `jread 0x311` 直到 bit1=1（done）
  5. 释放复位：`jwrite 0xF 0x1`，固件从指令 RAM 地址 0 开始运行
- 加载路径：`PC(JTAG) 触发 → spi_bootloader(硬件) → 0x03 Read 读 Flash → 写入指令 RAM`

**③ 单字读回验证**

- 脚本：`tcl/Instruct_flash_read.tcl`（读 `0x400000` 的一个字，命令 `0x03`）

### 3.3 Web 页面内容 —— `0x420000 ~ 0xC1FFFF`（8MB）

| 项 | 说明 |
|----|------|
| 保存什么 | HTML 页面（当前 3 页：`/`、`/wlconfig`、`/localconfig`），TOC + 内容 |
| 谁来操作 | **读**：RISC-V 固件经硬件 `flash_mem_reader` 内存映射读（`0x90000000` 段）；**写**：PC(JTAG) 经 `lcpu_sflash` |
| 如何操作 | 已实现（方案 B，见 `doc/HTTP页面Flash固化设计方案.md`）。TOC 存 `0x420000`（第 0 扇区），每页各占一个 4KB 扇区 |

> 布局：`0x420000` TOC（magic "WEBP" + 版本 + 计数 + N×16B 条目，条目含 route_id/content_type/offset/length）；
> `0x421000`/`0x422000`/`0x423000` 为 3 页内容。打包工具 `c_build/pages_to_flash_tcl.py` 生成
> `tcl/html_flash_initial.tcl` 烧写，只擦用到的 4 个扇区。

### 3.4 本机配置 + MAC 白名单 —— `0xC20000 ~ 0xC20FFF`（4KB）

| 项 | 说明 |
|----|------|
| 保存什么 | 本机 IP/MAC 配置 + MAC 白名单表 + 控制参数（+ CRC 校验） |
| 谁来操作 | **RISC-V 固件**（`c/local_config.c`、`c/whitelist.c`），经 `lcpu_sflash` 读写 |
| 如何操作 | 由 **Web UI 按钮触发**（如「保存到Flash」「从Flash重新加载」） |

- `c/local_config.c`：`#define FLASH_CONFIG_BASE 0x00C20000`，提供 `local_config_save_to_flash()` / `local_config_load_from_flash()`
- `c/whitelist.c`：提供 `whitelist_save_to_flash()` / `whitelist_load_from_flash()`
- 读写路径：`RISC-V CPU → SubBus → lcpu_sflash → SPI Flash`

> **扇区独占**：本机 IP/MAC 和白名单合并存同一 4KB 扇区，擦除时一起操作，简化 Flash 管理。

### 3.5 预留空间 —— `0xC21000 ~ 0xFFFFFF`（~3.87MB）

| 项 | 说明 |
|----|------|
| 保存什么 | 规划中：日志 / 固件备份 / 功能扩展 |
| 谁来操作 | 暂无 |

---

## 4. 操作入口汇总

### 4.1 寄存器地址（JTAG `jwrite`/`jread`）

**lcpu_sflash SubBus**（基址 `0x4000`，映射到 `lcpu_sflash`）：

| 偏移 | 方向 | 作用 |
|------|------|------|
| `0x4000` | 写 | SPI 高 4 字节（命令 + 地址） |
| `0x4001` | 写 | SPI 低 4 字节（数据） |
| `0x4002` | 写 | 通道长度（总 bit 数） |
| `0x4003` | 读 | SPI 读回字（`spi_word_get`） |
| `0x4004` | 读 | SPI 空闲标志（`spi_idle`，1=空闲） |
| `0x4005` | 写 | 操作启动（`op_start`，写任意值） |

**bootloader 寄存器**（`reg_webserver`）：

| 偏移 | 方向 | 作用 |
|------|------|------|
| `0xF` | 写 | `riscv_reset_l`（0=复位，1=释放） |
| `0x310` | 写 | bootloader 触发（`bootloader_trigger_ind`） |
| `0x311` | 读 | bootloader 状态（bit0=busy, bit1=done, bit2=error） |
| `0x312` | 写 | bootloader 源 Flash 地址（`0x400000`） |
| `0x313` | 写 | bootloader 长度（`0x5D70` 字节） |

### 4.2 TCL 脚本

| 脚本 | 作用 |
|------|------|
| `tcl/Instruct_flash_initial.tcl` | 把 RISC-V 固件写入 Flash `0x400000`（擦 + 写 5980 字） |
| `tcl/Instruct_load2fpga.tcl` | 触发 bootloader，把固件从 Flash 搬到指令 RAM |
| `tcl/Instruct_flash_read.tcl` | 读回 Flash `0x400000` 的一个字（验证） |
| `tcl/InstructRAM.tcl` | 直接经 JTAG 把固件写进 FPGA 片内指令 RAM（不经过 Flash） |

### 4.3 SPI 命令速查（lcpu_sflash / spi_ctrl 使用）

| 命令 | 字节 | 用途 |
|------|------|------|
| `0x03` | Read Data | 读 Flash 数据 |
| `0x02` | Page Program | 写 Flash（每字 4 字节） |
| `0x20` | Sector Erase | 擦 4KB 扇区 |
| `0x06` | Write Enable（WREN） | 写/擦前使能 |
| `0x05` | Read Status Register（RDSR） | 读忙标志 WIP(bit0) |
| `0x9F` | Read JEDEC ID | 读芯片 ID（`C2 20 18`） |

---

## 5. 关键事实备忘

1. **固件源地址 `0x400000`、长度 `0x5D70`（23920 字节 = 5980 字）**，首字 `0x40D0006F`。
2. 固件写入前必须**先复位 RISC-V**（`jwrite 0xF 0x0`），写完/加载完再释放（`jwrite 0xF 0x1`），防止 CPU 在搬运期间执行到半截指令。
3. Flash 引脚 mux：`bootloader_status[0]`（busy）为 1 时，Flash 引脚切到 bootloader 路径；否则切到 `lcpu_sflash` 路径。**bootloader 卡在 busy 时会堵死 lcpu_sflash 的读**，此时测 Flash 读前要先重下 bitstream。
4. Flash 上电/复位后的**第一次读可能返回全 `F`**（MISO 未驱动）。bootloader 每次启动前会先发一笔 JEDEC ID 读（`0x9F`）唤醒 Flash，结果丢弃，再正式读固件。
5. `0xC20000` 的配置扇区独占一个 4KB 扇区，擦除时本机配置和白名单一起操作。
