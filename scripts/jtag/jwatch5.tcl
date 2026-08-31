# jwatch5.tcl — RX FIFO 楔点观测器（P0 真空窗取证）
# 假说: 真空期 = CPU 读到的 rd_pkt_fifo.empty 陈旧(假空) → 不消费积压请求
# 铁证三件套(真空期): 0x100 rx_good 持续涨 + 0x6000 empty=1 + 0x6005 raddr 冻结
# 用法: vivado -mode batch -nolog -nojournal -source scripts/jtag/jwatch5.tcl > log 2>&1 &
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
proc hx { v } { return [format 0x%08x $v] }
puts "WATCH_START [clock format [clock seconds] -format %H:%M:%S]"
set prev_raddr -1
set prev_rx -1
set prev_twaddr -1
set prev_pcnt -1
set i 0
while {1} {
    set ts [clock format [clock seconds] -format %H:%M:%S]
    if {[catch {
        set dbg    [jread 0x13]
        set rx     [jread 0x100]
        set led    [jread 0x30]
        set fw     [jread 0x10]
        set pcnt   [jread 0x11]
        set rxn    [expr $dbg & 0xFFFF]
        set txn    [expr ($dbg >> 16) & 0xFFFF]
        set ev 0
        set tag ""
        if { $rxn != $prev_raddr } { set ev 1; append tag " rxn+" }
        if { $txn != $prev_twaddr } { set ev 1; append tag " txn+" }
        if { $pcnt != $prev_pcnt } { set ev 1; append tag " parse+" }
        if { $i % 8 == 0 } { set ev 1 }
        if { $ev } {
            puts "W $ts rx_cnt=$rxn tx_cnt=$txn parse=$pcnt first_word=[format %08x $fw] macrx=$rx led=[hx $led]$tag"
        }
        set prev_raddr $rxn
        set prev_twaddr $txn
        set prev_pcnt $pcnt
        set prev_rx $rx
    } err]} {
        puts "W $ts JTAG_ERR: $err"
    }
    incr i
    after 400
}
