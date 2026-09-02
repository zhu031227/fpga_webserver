# ============================================================================
# jpoll.tcl — 常驻 JTAG 取证监控器（P2/P0 实验伴随工具）
# 单次 Vivado 会话内循环轮询，避免每条命令 30-60s 的启动开销。
# 用法（仓库根目录）:
#   vivado -mode batch -nolog -nojournal -source scripts/jtag/jpoll.tcl > /tmp/jpoll.log 2>&1 &
# 输出格式:
#   POLL <HH:MM:SS> latch_delta=<d>     每2s：>0=时钟域活, =0=硬件级死亡
#   CNT  <HH:MM:SS> <计数器快照>        每10s：全套取证计数器
#   JTAG_ERR ...                        JTAG/总线读失败（本身也是信号：桥死）
# 注意: 本脚本自带 jwrite/jread, 每次循环约 4 笔 JTAG-AXI 事务, 对总线扰动极小。
# ============================================================================
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
proc hx { v } { return [format 0x%08x $v] }

puts "POLL_START [clock format [clock seconds] -format %H:%M:%S]"
set i 0
while {1} {
    set ts [clock format [clock seconds] -format %H:%M:%S]
    if {[catch {
        jwrite 0x06 1
        set v1 [jread 0x07]
        set led1 [jread 0x30]
        after 1100
        jwrite 0x06 1
        set v2 [jread 0x07]
        set led2 [jread 0x30]
        set d [expr {$v2 - $v1}]
        # 1.1s 窗内自比: LED 每秒必变且翻转点在 1.1s 偏移下必错开, 相同=真停摆
        set verdict [expr {$led1 == $led2 ? "CPU_STALL" : "cpu_alive"}]
        puts "POLL $ts latch_delta=$d led=[format 0x%02x $led1]->[format 0x%02x $led2] $verdict"
    } err]} {
        puts "POLL $ts JTAG_ERR: $err"
    }
    if { $i % 5 == 0 } {
        if {[catch {
            set ro20  [jread 0x20]    ;# debug_ro_0   eth0 RX包丢弃(RX FIFO溢出)
            set ro21  [jread 0x21]    ;# debug_ro_1   桥口白名单丢包
            set c100  [jread 0x100]   ;# eth0 rx good
            set c101  [jread 0x101]   ;# rx FCS 坏帧
            set c102  [jread 0x102]   ;# eth0 tx good
            set c103  [jread 0x103]   ;# tx error
            set c104  [jread 0x104]   ;# rx 异步FIFO满事件
            set boot  [jread 0x12]    ;# 引导阶段号
            set wlc   [jread 0x300]   ;# wl_ctrl
            set wls   [jread 0x301]   ;# wl_status (当前恒0)
            puts "CNT $ts rx_drop=[hx $ro20] bridge_drop=[hx $ro21] rx_good=[hx $c100] crc_err=[hx $c101] tx_good=[hx $c102] tx_err=[hx $c103] afifo_full=[hx $c104] boot=[hx $boot] wl_ctrl=[hx $wlc] wl_status=[hx $wls]"
        } err2]} {
            puts "CNT $ts JTAG_ERR: $err2"
        }
    }
    incr i
    after 1700
}
