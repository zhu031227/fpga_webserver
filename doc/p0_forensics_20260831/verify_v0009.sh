#!/bin/bash
# v0009 上板验证: bit 烧录 → 固件重载 → wl_status 0x301 接线证明 → 冒烟
set -e
R=/home/haitaoz/work/FPGA_Prj/fpga_webserver-wldev-v2
BIT=$(ls -d $R/webserver_xilinx_xc7a35tfgg484_v0009_*/webserver_xilinx_xc7a35tfgg484_v0009_*.bit 2>/dev/null | head -1)
[ -z "$BIT" ] && { echo "找不到 v0009 bit"; exit 1; }
echo "BIT=$BIT"

echo "=== [1] 烧录 v0009 bit ==="
cd $R && vivado -mode batch -nolog -nojournal -source scripts/program_bit_vivado.tcl -tclargs "$BIT" 2>&1 | tail -2

echo "=== [2] 重载固件 ==="
vivado -mode batch -nolog -nojournal -source scripts/load_firmware_vivado.tcl 2>&1 | tail -1
sleep 8

echo "=== [3] 冒烟: status + 页面 ==="
curl -s -m 5 --interface wlp4s0 http://192.168.1.128/api/wl/status -w " | %{http_code} %{time_total}s\n"
curl -s -m 10 --interface wlp4s0 http://192.168.1.128/ -o /dev/null -w "page: %{http_code} %{time_total}s %{size_download}B\n"

echo "=== [4] wl_status 0x301 接线证明 ==="
echo "-- 空表读 0x301 (期望 0x00000000: mode=0 used=0) --"
vivado -mode batch -nolog -nojournal -source scripts/jtag/jr.tcl -tclargs 0x301 2>&1 | grep -E "READ|0x" | tail -2
echo "-- POST 加一条 (AA:BB:CC:DD:EE:01) --"
curl -s -m 5 --interface wlp4s0 -X POST http://192.168.1.128/api/wl/add -d '{"mac":"AA:BB:CC:DD:EE:01"}' -w " | %{http_code}\n"
sleep 2
echo "-- 重读 0x301 (期望 0x000001xx: used_cnt=1) --"
vivado -mode batch -nolog -nojournal -source scripts/jtag/jr.tcl -tclargs 0x301 2>&1 | grep -E "READ|0x" | tail -2
echo "-- 删除该条 --"
curl -s -m 5 --interface wlp4s0 -X POST http://192.168.1.128/api/wl/delete -d '{"mac":"AA:BB:CC:DD:EE:01"}' -w " | %{http_code}\n"
sleep 2
echo "-- 终读 0x301 (期望回到 0x00000000) --"
vivado -mode batch -nolog -nojournal -source scripts/jtag/jr.tcl -tclargs 0x301 2>&1 | grep -E "READ|0x" | tail -2
echo "=== 验证完 ==="
