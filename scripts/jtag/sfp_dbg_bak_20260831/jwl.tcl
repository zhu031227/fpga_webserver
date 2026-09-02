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
for {set i 0} {$i < 12} {incr i} {
    set a [expr 0x300 + $i*4]
    puts [format "0x%03x: 0x%08x" $a [jread $a]]
}
close_hw_target [get_hw_targets]
disconnect_hw_server
