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
set t1 [jread 0x102]; set r1 [jread 0x100]
after 8000
set t2 [jread 0x102]; set r2 [jread 0x100]
puts "8s窗口: e0_rx +[expr $r2-$r1]  e0_tx(0x102) +[expr $t2-$t1]"
close_hw_target [get_hw_targets]
disconnect_hw_server
