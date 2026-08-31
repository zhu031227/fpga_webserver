# jlatch.tcl — LCPU 时钟域活性判据（jcpu v2，修正版）
# 原理：0x06=WC 锁存触发（写一次把硬件自由计数器拍照进 0x07/0x08 RO 锁存器）。
#       拍两次照比 delta：>0 = 时钟域在走（活）；=0 = 域停钟/复位（硬件级死亡）。
# 注意：delta>0 只证明时钟域活着，不证明主循环没卡死（软件假死需看 HTTP/LED）。
# 用法：vivado -mode batch -source scripts/jtag/jlatch.tcl
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
jwrite 0x06 0x00000001
set a [jread 0x07]
after 2000
jwrite 0x06 0x00000001
set b [jread 0x07]
puts "RESULT: local_time [format 0x%08x $a] -> [format 0x%08x $b] (delta [expr {$b-$a}])"
if {$b > $a} { puts ">>> 时钟域在走（活）" } else { puts ">>> 两次锁存相同 — 时钟域冻结（硬件级死亡信号）" }
close_hw_target
disconnect_hw_server
