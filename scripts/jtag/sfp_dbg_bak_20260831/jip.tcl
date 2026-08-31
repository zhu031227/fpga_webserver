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
proc jwrite { address data } {
    set address [format "%08x" $address]
    set data [format "%08x" $data]
    create_hw_axi_txn write_txn [get_hw_axis hw_axi_1] -address $address -data $data -type write
    run_hw_axi write_txn
    delete_hw_axi_txn write_txn
}
puts "改前 local_ip(0x204)=[format 0x%08x [jread 0x204]]"
jwrite 0x204 0xC0A80180   ;# 192.168.1.128
puts "改后 local_ip(0x204)=[format 0x%08x [jread 0x204]]"
close_hw_target [get_hw_targets]
disconnect_hw_server
