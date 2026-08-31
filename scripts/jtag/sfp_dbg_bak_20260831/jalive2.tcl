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
puts "wl_ctrl(0x300)=[format 0x%08x [jread 0x300]] e0_rx(0x100)=[jread 0x100] e0_0x102=[jread 0x102] e0_0x103=[jread 0x103] cfg_ip(0x204)=[format 0x%08x [jread 0x204]]"
close_hw_target [get_hw_targets]
disconnect_hw_server
