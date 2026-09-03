# 仅复位 RISC-V（不重载固件），CPU 从 0 重启 → 走 boot → 读 flash → 恢复白名单
open_hw_manager
connect_hw_server
open_hw_target [lindex [get_hw_targets] 0]
refresh_hw_device

proc jwrite { address data } {
    set address [format "%08x" $address]
    set data [format "%08x" $data]
    create_hw_axi_txn write_txn [get_hw_axis hw_axi_1] -address $address -data $data -type write
    run_hw_axi write_txn
    delete_hw_axi_txn write_txn
}

puts "=== 复位 RISC-V ==="
jwrite 0xF 0x0
after 200
jwrite 0xF 0x1
puts "=== 已释放复位，CPU 从 0 重启 ==="
