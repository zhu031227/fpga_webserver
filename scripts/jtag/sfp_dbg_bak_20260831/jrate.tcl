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
set a [jread 0x100]; set b [jread 0x20]; set c [jread 0x118]; set d [jread 0x112]
puts "T0: e0_rx=$a cpu_drop=$b e2_rx=$c e1_tx=$d"
after 12000
set a2 [jread 0x100]; set b2 [jread 0x20]; set c2 [jread 0x118]; set d2 [jread 0x112]
puts "T12: e0_rx=$a2 cpu_drop=$b2 e2_rx=$c2 e1_tx=$d2"
puts "DELTA: e0_rx=[expr $a2-$a] cpu_drop=[expr $b2-$b] e2_rx=[expr $c2-$c] e1_tx=[expr $d2-$d]"
close_hw_target [get_hw_targets]
disconnect_hw_server
