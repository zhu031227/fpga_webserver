# ============================================================================
# program_bit_vivado.tcl — 通过 Vivado Hardware Manager 烧录 bitstream（批处理）
# ============================================================================
# 用法（仓库根目录执行）：
#   vivado -mode batch -source scripts/program_bit_vivado.tcl -tclargs <bit路径>
#
# 例：
#   vivado -mode batch -source scripts/program_bit_vivado.tcl -tclargs \
#       webserver_xilinx_xc7a35tfgg484_v0008_20260830_181347/webserver_xilinx_xc7a35tfgg484_v0008_20260830_181347.bit
#
# 注意：本板（ACX750，Digilent HS2 克隆）openFPGALoader 会误读 IDCODE，
#       统一走 Vivado Hardware Manager 烧录。bit 为 SRAM 易失加载，断电即失。
# ============================================================================

if { $argc < 1 } {
    puts "ERROR: 缺少 bit 文件参数。用法: -tclargs <bit路径>"
    return -code error "missing bit file argument"
}
set bit [lindex $argv 0]
if { ![file exists $bit] } {
    puts "ERROR: 找不到 bit 文件: $bit"
    return -code error "bit file not found"
}

open_hw_manager
connect_hw_server
open_hw_target [lindex [get_hw_targets] 0]

set dev [lindex [get_hw_devices] 0]
puts "=== 目标器件: $dev ==="
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "=== 烧录完成: $bit ==="

close_hw_target
disconnect_hw_server
