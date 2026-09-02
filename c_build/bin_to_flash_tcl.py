#!/usr/bin/env python3
"""
bin_to_flash_tcl.py — 生成两个自包含 TCL 脚本（固件字内嵌）：

  1. Instruct_flash_initial.tcl — 把 RISC-V 固件烧进 SPI Flash（erase + program）
  2. Instruct_load2fpga.tcl      — 触发 bootloader，把 flash 里的固件搬进 FPGA 指令 RAM

与 bin_to_tcl.py（直接 jwrite 写指令 RAM）不同，本脚本生成的脚本走
「写 SPI Flash → bootloader 回搬」流程，固件指令字直接内嵌在脚本里，
不依赖 firmware_pads.bin，可拷贝到任意调试电脑独立运行。

用法：
    python3 bin_to_flash_tcl.py <firmware_pads.bin> <out_dir> <flash_addr> <reset_addr>
示例：
    python3 bin_to_flash_tcl.py out/firmware_pads.bin ../tcl 0x400000 0xF

依赖（Vivado）：source ip_lcpu/tcl/jtag_slib.tcl ; jopen
"""

import sys
import pathlib

# ---------------------------------------------------------------------------
# Instruct_flash_initial.tcl 前导：常量 + SPI 工具函数（会原样写入生成的 .tcl）
# 注意：这里面的 \\[ERROR\\] 是 TCL 里转义的方括号字面量，务必原样保留。
# ---------------------------------------------------------------------------
FLASH_INIT_PREAMBLE = r'''# ============================================================================
# Instruct_flash_initial.tcl — RISC-V 固件写入 SPI Flash（erase + program）
# （自包含版：固件字内嵌，可拷贝到任意调试电脑独立运行，无需 firmware_pads.bin）
# ============================================================================
# 依赖（Vivado 里先执行）：source ip_lcpu/tcl/jtag_slib.tcl ; jopen
# 硬件地址（当前 reg_webserver.v 译码，注意 0x1400 是过时注释）：
#   sflash SubBus 0x4000~0x4FFF -> lcpu_sflash
#   riscv_reset_l 0xF
# ============================================================================

set SFLASH_BASE     0x4000
set RISCV_RST_ADDR  0xF

# 可移植延时（忙等，GUI/批处理均可用）
proc delay_ms {ms} {
    set end [expr {[clock milliseconds] + $ms}]
    while {[clock milliseconds] < $end} { }
}

# 等待上一次 SPI 事务完成（读 spi_idle，1=空闲）
proc spi_wait_idle {} {
    global SFLASH_BASE
    delay_ms 2
    set cnt 0
    while {1} {
        set st [jread [expr {$SFLASH_BASE + 0x4}]]
        if {$st == 1} { return 1 }
        incr cnt
        if {$cnt > 500000} { puts "  \[ERROR\] SPI timeout"; return 0 }
        delay_ms 1
    }
}

# 发送一次 SPI 事务：hi=高4字节 lo=低4字节 len=总bit数
# lcpu_sflash_core 内部做 64bit 位反转，线上是 MSB-first
proc spi_tx {hi lo len} {
    global SFLASH_BASE
    jwrite [expr {$SFLASH_BASE + 0x0}] $hi
    jwrite [expr {$SFLASH_BASE + 0x1}] $lo
    jwrite [expr {$SFLASH_BASE + 0x2}] $len
    jwrite [expr {$SFLASH_BASE + 0x5}] 0x1
    spi_wait_idle
}

# Write Enable (0x06)
proc flash_wren {} {
    spi_tx 0x06000000 0x0 8
}

# 轮询 flash 忙标志：读状态寄存器 RDSR(0x05)，直到 WIP(bit0) 清零
proc flash_wait_busy {} {
    global SFLASH_BASE
    set cnt 0
    while {1} {
        jwrite [expr {$SFLASH_BASE + 0x0}] 0x05000000
        jwrite [expr {$SFLASH_BASE + 0x1}] 0x0
        jwrite [expr {$SFLASH_BASE + 0x2}] 0x10
        jwrite [expr {$SFLASH_BASE + 0x5}] 0x1
        spi_wait_idle
        set st [jread [expr {$SFLASH_BASE + 0x3}]]
        if {[expr {$st & 0x1}] == 0} { return 1 }
        incr cnt
        if {$cnt > 200000} { puts "  \[ERROR\] flash busy timeout"; return 0 }
        delay_ms 1
    }
}

# Sector Erase (0x20 + 24bit 地址)，擦后轮询 WIP 直到完成
proc flash_sector_erase {addr} {
    set hi [expr {(0x20 << 24) | ($addr & 0xFFFFFF)}]
    flash_wren
    spi_tx $hi 0x0 32
    flash_wait_busy
}

# Page Program (0x02 + 24bit 地址 + 4 字节数据)，64bit 事务
# lcpu_sflash 一次最多 8 字节，故命令+地址占 4 字节、数据只能 4 字节/次
proc flash_program_word {addr word} {
    set hi [expr {(0x02 << 24) | ($addr & 0xFFFFFF)}]
    flash_wren
    spi_tx $hi $word 64
    flash_wait_busy
}
'''

# ---------------------------------------------------------------------------
# Instruct_load2fpga.tcl 前导：常量 + 延时（不需要 SPI 函数）
# ---------------------------------------------------------------------------
LOAD2FPGA_PREAMBLE = r'''# ============================================================================
# Instruct_load2fpga.tcl — 触发 bootloader，把 flash 固件搬进 FPGA 指令 RAM
# ============================================================================
# 依赖（Vivado 里先执行）：source ip_lcpu/tcl/jtag_slib.tcl ; jopen
# 硬件地址（当前 reg_webserver.v 译码）：
#   riscv_reset_l 0xF ; bootloader_trigger 0x310 ; status 0x311
#   bootloader_flash_addr 0x312 ; bootloader_length 0x313
# ============================================================================

set RISCV_RST_ADDR  0xF
set BL_TRIGGER      0x310
set BL_STATUS       0x311
set BL_FLASH_ADDR   0x312
set BL_LENGTH       0x313

# 可移植延时（忙等）
proc delay_ms {ms} {
    set end [expr {[clock milliseconds] + $ms}]
    while {[clock milliseconds] < $end} { }
}
'''

# ---------------------------------------------------------------------------
# Instruct_load2fpga.tcl 主流程：复位 → 触发 bootloader → 轮询 → 释放复位
#   __RST_ADDR__ / __FLASH_ADDR__ / __FW_BYTES__ 会被替换为实际值
# ---------------------------------------------------------------------------
LOAD2FPGA_MAIN = r'''

# ============ 主流程 ============

# 1. 复位 RISC-V（bootloader 写指令 RAM 期间保持复位）
jwrite 0x__RST_ADDR__ 0x0
delay_ms 10

# 2. 配置并触发 bootloader
jwrite 0x312 __FLASH_ADDR__
jwrite 0x313 __FW_BYTES__
jwrite 0x310 0x1

# 3. 轮询 bootloader 完成
set _cnt 0
while {1} {
    set _st [jread 0x311]
    if {[expr {$_st & 0x2}] != 0} { puts "  bootloader done"; break }
    if {[expr {$_st & 0x4}] != 0} { puts "  \[ERROR\] bootloader status=$_st"; break }
    incr _cnt
    if {$_cnt > 2000000} { puts "  \[ERROR\] bootloader timeout"; break }
    delay_ms 1
}

# 4. 释放 RISC-V 复位
jwrite 0x__RST_ADDR__ 0x1
puts "  RISC-V released, running firmware from instruction RAM addr 0"
'''


def bin_to_flash_tcl(bin_file: pathlib.Path, out_dir: pathlib.Path,
                     flash_addr: str, reset_addr: str) -> None:
    data = bin_file.read_bytes()

    # 补齐到 4 字节边界
    remainder = len(data) % 4
    if remainder:
        data += b'\x00' * (4 - remainder)

    # 找最后一个非零字（跳过尾部 0 填充），与 bin_to_tcl.py 一致
    last_nonzero = -1
    for i in range(len(data) // 4 - 1, -1, -1):
        chunk = data[i*4:i*4+4]
        if any(b != 0 for b in chunk):
            last_nonzero = i
            break
    if last_nonzero < 0:
        print("Warning: firmware binary is all zeros.")
        last_nonzero = 0

    flash_base = int(flash_addr, 16)
    rst_addr = int(reset_addr, 16)
    nwords = last_nonzero + 1
    fw_bytes = nwords * 4
    nsec = (fw_bytes + 4095) // 4096

    out_dir.mkdir(parents=True, exist_ok=True)

    # ---- 1. Instruct_flash_initial.tcl：写 flash ----
    flash_init = out_dir / "Instruct_flash_initial.tcl"
    with flash_init.open('w', encoding='utf-8') as f:
        f.write(FLASH_INIT_PREAMBLE)
        f.write('\n# ============ 主流程 ============\n')
        f.write('# 1. 复位 RISC-V（写 flash 期间保持复位）\n')
        f.write(f'jwrite 0x{rst_addr:X} 0x0\n\n')

        f.write(f'# 2. 擦除 {nsec} 个 4KB 扇区 @ 0x{flash_base:X}\n')
        for s in range(nsec):
            f.write(f'flash_sector_erase 0x{flash_base + s * 4096:X}\n')

        f.write(f'\n# 3. 编程 {nwords} 个字\n')
        for i in range(nwords):
            chunk = data[i*4:i*4+4]
            reversed_chunk = chunk[::-1]          # 小端 bin -> 指令字（与 bin_to_tcl.py 一致）
            hex_string = ''.join(f'{b:02X}' for b in reversed_chunk)
            f.write(f'flash_program_word 0x{flash_base + i * 4:X} 0x{hex_string}\n')

        f.write(f'\nputs "  flash initialized: {nwords} words @ 0x{flash_base:X}"\n')

    # ---- 2. Instruct_load2fpga.tcl：加载到 FPGA ----
    load2fpga = out_dir / "Instruct_load2fpga.tcl"
    main = (LOAD2FPGA_MAIN
            .replace('__RST_ADDR__', f'{rst_addr:X}')
            .replace('__FLASH_ADDR__', f'0x{flash_base:X}')
            .replace('__FW_BYTES__', f'0x{fw_bytes:X}'))
    with load2fpga.open('w', encoding='utf-8') as f:
        f.write(LOAD2FPGA_PREAMBLE)
        f.write(main)

    print(f"  Generated: {flash_init.name} ({nwords} words, {fw_bytes} bytes, {nsec} sectors)")
    print(f"  Generated: {load2fpga.name} (flash_addr 0x{flash_base:X}, {fw_bytes} bytes)")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("Usage: python3 bin_to_flash_tcl.py <input.bin> <out_dir> <flash_addr> <reset_addr>")
        sys.exit(1)

    input_bin = pathlib.Path(sys.argv[1])
    out_dir = pathlib.Path(sys.argv[2])
    flash_addr = sys.argv[3]
    reset_addr = sys.argv[4]

    if not input_bin.exists():
        print(f"Error: input file not found: {input_bin}")
        sys.exit(1)

    bin_to_flash_tcl(input_bin, out_dir, flash_addr, reset_addr)
