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
puts "e1_rx(0x110)=[jread 0x110]  e1_tx(0x112)=[jread 0x112]  e2_rx(0x118)=[jread 0x118]  e2_tx(0x11A)=[jread 0x11A]  drop(0x21)=[jread 0x21]  wl_ctrl(0x300)=[jread 0x300]"
close_hw_target
disconnect_hw_server
