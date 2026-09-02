# 全量 IRAM 校验: 与 InstructRAM.tcl 比对, 输出所有 bit 翻转
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
set fh [open "/home/haitaoz/work/FPGA_Prj/fpga_webserver-wldev-v2/tcl/InstructRAM.tcl" r]
set n 0; set bad 0
while {[gets $fh line] >= 0} {
    if {![regexp {jwrite (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)} $line -> a d]} continue
    set addr [expr $a]; set exp [expr $d]
    set got [jread $addr]
    if {$got != $exp} {
        incr bad
        puts [format "MISMATCH @0x%04x  expect=0x%08x  got=0x%08x  xor=0x%08x" $addr $exp $got [expr $exp^$got]]
    }
    incr n
}
close $fh
puts "VERIFY DONE: $n words checked, $bad mismatches"
close_hw_target [get_hw_targets]
disconnect_hw_server
