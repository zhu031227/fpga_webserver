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
puts "eth0_rx=[jread 0x100] eth1_drop=[jread 0x21] eth1_rx_ok=[jread 0x110] eth1_rx_crc=[jread 0x111] eth2_rx_ok=[jread 0x118] eth2_rx_crc=[jread 0x119]"
close_hw_target [get_hw_targets]
disconnect_hw_server
