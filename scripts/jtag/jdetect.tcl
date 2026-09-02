# ============================================================================
# jdetect.tcl — JTAG 器件探测（区分板卡"挂死"与"掉电"）
# 用法（仓库根目录）: vivado -mode batch -nolog -nojournal -source scripts/jtag/jdetect.tcl
# 输出判据: DETECT_RESULT: OK（有器件，可走 Quick Start B 重烧）
#           DETECT_RESULT: NO_DEVICE / NO_CABLE_TARGET（大概率掉电，需人工上电）
# ============================================================================
open_hw_manager
connect_hw_server
set targets [get_hw_targets -quiet]
if { [llength $targets] == 0 } {
    puts "DETECT_RESULT: NO_CABLE_TARGET"
    exit 1
}
set opened 0
foreach t $targets {
    puts "HW_TARGET: $t"
    catch { refresh_hw_target $t }
    if { [catch { open_hw_target $t } err] } {
        puts "OPEN_TARGET_FAIL: $err"
        continue
    }
    foreach d [get_hw_devices -quiet] {
        puts "DETECT_RESULT: DEVICE=$d PART=[get_property PART $d]"
        set opened 1
    }
    catch { close_hw_target $t }
}
if { !$opened } {
    puts "DETECT_RESULT: NO_DEVICE"
} else {
    puts "DETECT_RESULT: OK"
}
