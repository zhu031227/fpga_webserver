# GT 状态 + 计数器一站式读数（v0004+ 固件支持 0x22/0x23）
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
set cnt  [jread 0x21]
set sv   [jread 0x22]
set link [jread 0x23]
set e1   [jread 0x110]
set e2   [jread 0x118]
puts "eth1_drop\[0x21\] = $cnt"
puts "status_sv \[0x22\] = [format 0x%08x $sv]  (hi16=sfp2 lo16=sfp1)"
puts "link_chain\[0x23\] = [format 0x%08x $link]  (bit0=resetdone bit1=mmcm_locked bit2=cpll_lock bit3=refclklost)"
puts "eth1_rx_ok\[0x110\] = $e1"
puts "eth2_rx_ok\[0x118\] = $e2"
# 逐位解读 link_chain
puts "  → resetdone=[expr {$link & 1}] mmcm_locked=[expr {($link>>1)&1}] cpll_lock=[expr {($link>>2)&1}] refclklost=[expr {($link>>3)&1}]"
puts "  → sfp1_sv=[format 0x%04x [expr {$sv & 0xFFFF}]]  sfp2_sv=[format 0x%04x [expr {($sv>>16)&0xFFFF}]]  (sv bit0 = link_status)"
close_hw_target [get_hw_targets]
disconnect_hw_server
