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
set base 0x90c20000
puts "MAGIC    = [format 0x%08x [jread [expr $base+0x00]]]"
puts "VERSION  = [format 0x%08x [jread [expr $base+0x04]]]"
puts "CSUM     = [format 0x%08x [jread [expr $base+0x08]]]"
puts "MAC_H    = [format 0x%08x [jread [expr $base+0x0c]]]"
puts "MAC_L    = [format 0x%08x [jread [expr $base+0x10]]]"
puts "IP       = [format 0x%08x [jread [expr $base+0x14]]]"
puts "NETMASK  = [format 0x%08x [jread [expr $base+0x18]]]"
puts "GATEWAY  = [format 0x%08x [jread [expr $base+0x1c]]]"
puts "WL_CTRL  = [format 0x%08x [jread [expr $base+0x20]]]"
puts "WL_MASK  = [format 0x%08x [jread [expr $base+0x24]]]"
puts "WL0_H    = [format 0x%08x [jread [expr $base+0x28]]]"
puts "WL0_L    = [format 0x%08x [jread [expr $base+0x2c]]]"
puts "WL1_H    = [format 0x%08x [jread [expr $base+0x30]]]"
puts "WL1_L    = [format 0x%08x [jread [expr $base+0x34]]]"
close_hw_target [get_hw_targets]
disconnect_hw_server
