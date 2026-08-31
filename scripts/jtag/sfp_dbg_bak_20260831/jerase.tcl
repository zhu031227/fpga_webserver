# JTAG 直驱 SPI 控制器(SubBus 0x4000) 擦除 0xC20000 配置扇区
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
proc spi_wait_idle { timeout_ms } {
    set t 0
    while {$t < $timeout_ms} {
        if {[jread 0x4004] == 1} { return 0 }
        after 10; incr t 10
    }
    return -1
}
proc spi_tx { hi lo len } {
    jwrite 0x4000 $hi
    jwrite 0x4001 $lo
    jwrite 0x4002 $len
    jwrite 0x4005 1
    spi_wait_idle 500
}
puts "初始状态 idle=[jread 0x4004]"
spi_tx 0x06000000 0x00000000 8
puts "WREN 完成"
spi_tx 0x20C20000 0x00000000 32
puts "扇区擦除指令已发, 轮询 WIP..."
set t 0
while {$t < 30} {
    after 100; incr t 1
    spi_tx 0x05000000 0x00000000 16
    set st [jread 0x4003]
    if {([expr $st & 1]) == 0} { puts "WIP=0 擦除完成 (轮询$t次, RDSR=[format 0x%02x $st])"; break }
}
puts "回读验证: magic位=[format 0x%08x [jread 0x90c20000]] (全FF=擦除成功)"
close_hw_target [get_hw_targets]
disconnect_hw_server
