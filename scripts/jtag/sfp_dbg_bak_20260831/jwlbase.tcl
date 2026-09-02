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
puts "--- 探测 base 0x5000:"
jwrite 0x5000 1   ;# INDEX=1
puts "  RD_MAC_H=[format 0x%08x [jread 0x5006]] RD_MAC_L=[format 0x%08x [jread 0x5007]] VALID=[format 0x%08x [jread 0x5008]] FREE=[format 0x%08x [jread 0x5009]]"
puts "--- 探测 base 0x1500:"
jwrite 0x1500 1   ;# INDEX=1
puts "  RD_MAC_H=[format 0x%08x [jread 0x1506]] RD_MAC_L=[format 0x%08x [jread 0x1507]] VALID=[format 0x%08x [jread 0x1508]] FREE=[format 0x%08x [jread 0x1509]]"
close_hw_target [get_hw_targets]
disconnect_hw_server
