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
proc spi_wait { t } { set n 0; while {$n < $t} { if {[jread 0x4004]==1} {return 0}; after 10; incr n 10 }; return -1 }
proc spi_tx { hi lo len } { jwrite 0x4000 $hi; jwrite 0x4001 $lo; jwrite 0x4002 $len; jwrite 0x4005 1; spi_wait 500 }
proc rdw { a } { spi_tx [expr {(0x03<<24)|$a}] 0 64; return [jread 0x4003] }
puts "=== A扇区 0xC20000:"
puts "  MAGIC raw=[format 0x%08x [rdw 0xC20000]]"
puts "  VER   raw=[format 0x%08x [rdw 0xC20004]]"
puts "  CSUM  raw=[format 0x%08x [rdw 0xC20008]]"
puts "  SEQ   raw=[format 0x%08x [rdw 0xC2000C]]"
puts "  IP    raw=[format 0x%08x [rdw 0xC20018]]"
puts "  WLCTRLraw=[format 0x%08x [rdw 0xC20020]]"
puts "  WL0H  raw=[format 0x%08x [rdw 0xC20028]]"
puts "=== B扇区 0xC21000:"
puts "  MAGIC raw=[format 0x%08x [rdw 0xC21000]]"
puts "=== 板态: boot(0x12)=[format 0x%08x [jread 0x12]] wl_ctrl(0x300)=[format 0x%08x [jread 0x300]]"
close_hw_target [get_hw_targets]
disconnect_hw_server
