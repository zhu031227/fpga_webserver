# ============================================================================
# flash_web_vivado.tcl — 通过 Vivado JTAG-AXI 把 Web 页面固化到 SPI Flash
# ============================================================================
# 前置条件：
#   1. .bit 已烧到 FPGA
#   2. 页面打包已生成：cd c_build && make pages
#      （产物 tcl/html_flash_initial.tcl，含 TOC + 3 页面内容）
#
# 用法（任意目录均可）：
#   vivado -mode batch -source scripts/flash_web_vivado.tcl
#
# 原理：
#   经 LCPU 总线驱动 lcpu_sflash（SubBus 0x4000）对 MX25L12845 执行
#   Sector Erase(0x20) + Page Program(0x02)，把 TOC 和页面写入 0x420000；
#   jread 轮询 RDSR 忙标志。写完后 RISC-V 重新从 Flash 读页面即可生效。
#
# 注意：脚本会先复位 RISC-V（jwrite 0xF 0x0）、结束再释放（0xF 0x1），
#       固化期间 WebServer 会短暂无响应，属正常现象。
# ============================================================================

open_hw_manager
connect_hw_server
open_hw_target [lindex [get_hw_targets] 0]
refresh_hw_device

# jwrite：单笔 32bit AXI 写
proc jwrite { address data } {
    set address [format "%08x" $address]
    set data [format "%08x" $data]
    create_hw_axi_txn write_txn [get_hw_axis hw_axi_1] -address $address -data $data -type write
    run_hw_axi write_txn
    delete_hw_axi_txn write_txn
}

# jread：单笔 32bit AXI 读，返回十进制数值
proc jread { address } {
    set address [format "%08x" $address]
    create_hw_axi_txn read_txn [get_hw_axis hw_axi_1] -address $address -type read
    run_hw_axi read_txn
    set read_value [lindex [report_hw_axi_txn read_txn] 1]
    delete_hw_axi_txn read_txn
    set read_value [string trim $read_value]
    return [expr 0x$read_value]
}

set repo_root [file dirname [file normalize "[info script]/.."]]
set pages_tcl [file join $repo_root tcl html_flash_initial.tcl]
if { ![file exists $pages_tcl] } {
    puts "ERROR: 未找到 $pages_tcl —— 请先 cd c_build && make pages 生成页面打包"
    return -code error "html_flash_initial.tcl missing"
}

puts "=== 开始固化网页到 Flash: $pages_tcl ==="
source $pages_tcl
puts "=== 网页固化完成 ==="
