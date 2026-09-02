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
puts "bootloader_status(0x311)=[format 0x%08x [jread 0x311]]  (bit0=busy/mux_select, bit1=done, bit2=error)"
puts "wl_ctrl(0x300)=[format 0x%08x [jread 0x300]] cfg_ip(0x204)=[format 0x%08x [jread 0x204]]"
close_hw_target [get_hw_targets]
disconnect_hw_server
