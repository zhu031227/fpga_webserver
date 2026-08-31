open_hw_manager
connect_hw_server
open_hw_target [lindex [get_hw_targets] 0]
refresh_hw_device
proc jread { address } {
    set address [format "%08x" $address]
    create_hw_axi_txn r [get_hw_axis hw_axi_1] -address $address -type read
    run_hw_axi r
    set v [lindex [report_hw_axi_txn r] 1]
    delete_hw_axi_txn r
    return [expr 0x[string trim $v]]
}
proc jwrite { address data } {
    set address [format "%08x" $address]
    set data [format "%08x" $data]
    create_hw_axi_txn w [get_hw_axis hw_axi_1] -address $address -data $data -type write
    run_hw_axi w
    delete_hw_axi_txn w
}
# 实验：写 0x06（WC 触发锁存）→ 读 0x07/0x08 → 等 2s → 再读，看走不走
jwrite 0x06 0x00000001
set a [jread 0x07]
set ah [jread 0x08]
after 2000
set b [jread 0x07]
set bh [jread 0x08]
puts "RESULT: 锁存后低32位 [format 0x%08x $a] -> [format 0x%08x $b] (delta [expr {$b-$a}])  高32位 [format 0x%08x $ah] -> [format 0x%08x $bh]"
if {$b > $a} { puts ">>> 0x06 写=锁存触发，0x07 锁存后自由计数 → jcpu v2 可用（清一次+读两次）" } else { puts ">>> 0x07 仍不走——WC 语义不是锁存触发，需另找活性判据" }
close_hw_target
disconnect_hw_server
