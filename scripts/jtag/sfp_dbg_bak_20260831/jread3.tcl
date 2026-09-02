# eth1/eth2 全量统计读数（配合后台流量使用）
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
proc snap {} {
    return [list \
        e0_rx      [jread 0x100] \
        e1_rxok    [jread 0x110] e1_rxcrc [jread 0x111] \
        e1_txok    [jread 0x112] e1_txerr [jread 0x113] \
        e1_full    [jread 0x114] e1_empty [jread 0x115] e1_dataline [jread 0x116] \
        e2_rxok    [jread 0x118] e2_rxcrc [jread 0x119] \
        e2_txok    [jread 0x11A] e2_txerr [jread 0x11B] \
        e2_full    [jread 0x11C] e2_empty [jread 0x11D] e2_dataline [jread 0x11E] \
        drop       [jread 0x21] \
        sv         [jread 0x22] chain [jread 0x23]]
}
set s1 [snap]
puts "T0:  $s1"
after 12000
set s2 [snap]
puts "T12: $s2"
foreach {k1 v1} $s1 {k2 v2} $s2 {
    if {$k1 eq $k2 && $v2 != $v1} {
        puts "DELTA $k1 = +[expr {$v2 - $v1}]"
    }
}
puts "（无 DELTA 行 = 全部无变化）"
close_hw_target [get_hw_targets]
disconnect_hw_server
