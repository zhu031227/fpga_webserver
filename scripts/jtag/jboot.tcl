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
puts "boot_stage(0x12)=[format 0x%08x [jread 0x12]]  (0x12=加载OK 0x13=加载失败走默认)"
close_hw_target [get_hw_targets]
disconnect_hw_server
