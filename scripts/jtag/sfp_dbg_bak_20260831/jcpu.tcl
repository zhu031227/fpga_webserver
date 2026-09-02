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
set a [jread 0x07]; set b [jread 0x08]
after 6000
set a2 [jread 0x07]; set b2 [jread 0x08]
puts "local_time: 0x07=[format 0x%08x $a] -> [format 0x%08x $a2] (delta [expr {$a2-$a}])  0x08=[format 0x%08x $b] -> [format 0x%08x $b2]"
if {$a2 > $a} { puts ">>> CPU 在执行(时间计数器在走)" } else { puts ">>> 计数器冻结 — CPU 很可能没在跑" }
close_hw_target [get_hw_targets]
disconnect_hw_server
