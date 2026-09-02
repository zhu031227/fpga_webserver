# ============================================================================
# load_firmware_vivado.tcl — 通过 Vivado JTAG-AXI 把固件加载到片内指令 RAM
# ============================================================================
# 前置条件：
#   1. .bit 已烧到 FPGA（openFPGALoader 或 Vivado Hardware Manager）
#   2. 固件已编译：cd c_build && make PLATFORM=xilinx
#
# 用法（任意目录均可，脚本自动定位仓库内的 tcl/InstructRAM.tcl）：
#   vivado -mode batch -source scripts/load_firmware_vivado.tcl
#
# 原理：
#   FPGA 内的 jtag_axi_0 (JTAG-to-AXI Master) 提供 hw_axi_1 通道，
#   本脚本定义 jwrite 过程（单笔 AXI 写 = 一次 LCPU 总线写），
#   然后逐条执行 tcl/InstructRAM.tcl：
#     jwrite 0xF 0x0      ← 复位 RISC-V
#     jwrite 0x8000+i ... ← 固件逐字写入指令 RAM
#     jwrite 0xF 0x1      ← 释放复位，CPU 从 0 开始执行
# ============================================================================

open_hw_manager
connect_hw_server
open_hw_target [lindex [get_hw_targets] 0]
refresh_hw_device

# jwrite：单笔 32bit AXI 写（对应 FPGA 内 LCPU 总线一次写事务）
proc jwrite { address data } {
    set address [format "%08x" $address]
    set data [format "%08x" $data]
    create_hw_axi_txn write_txn [get_hw_axis hw_axi_1] -address $address -data $data -type write
    run_hw_axi write_txn
    delete_hw_axi_txn write_txn
}

# 定位仓库内 tcl 目录（与脚本位置无关，clone 到任何路径都能用）
set repo_root [file dirname [file normalize "[info script]/.."]]
set fw_tcl [file join $repo_root tcl InstructRAM.tcl]
if { ![file exists $fw_tcl] } {
    puts "ERROR: 未找到 $fw_tcl —— 请先 cd c_build && make PLATFORM=xilinx 生成固件"
    return -code error "InstructRAM.tcl missing"
}

puts "=== 开始加载固件: $fw_tcl ==="
source $fw_tcl
puts "=== 固件加载完成，RISC-V 已从地址 0 开始运行 ==="
