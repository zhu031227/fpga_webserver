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

## License

Internal project.
