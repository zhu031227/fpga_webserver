# jr.tcl — 读单个 LCPU 寄存器
# 用法: vivado -mode batch -nolog -nojournal -source scripts/jtag/jr.tcl -tclargs <地址如0x301>
open_hw_manager
connect_hw_server
open_hw_target [lindex [get_hw_targets] 0]
refresh_hw_device
proc jread { address } {
    set address [format "%08x" $address]
    create_hw_axi_txn read_txn [get_hw_axis hw_axi_1] -address $address -type read
    run_hw_axi read_txn
    set v [lindex [report_hw_axi_txn read_txn] 1]
    delete_hw_axi_txn read_txn
    return [expr 0x[string trim $v]]
}
set a [lindex $argv 0]
puts "REG_RESULT: addr=$a val=[format 0x%08x [jread $a]]"
close_hw_target
disconnect_hw_server
