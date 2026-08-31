#!/bin/bash
# 看门狗: 每3秒探测 .88 和 .90, 记录时间戳/存活/应答MAC
LOG=/tmp/sfp_dbg/watchdog.log
echo "=== watchdog start $(date +%H:%M:%S) ===" >> $LOG
END=$((SECONDS + 900))
while [ $SECONDS -lt $END ]; do
    T=$(date +%H:%M:%S)
    P88=$(ping -c 1 -W 1 -I wlp4s0 192.168.1.88 2>/dev/null | grep -c "64 bytes")
    M88=$(ip neigh show 192.168.1.88 2>/dev/null | grep -oE "lladdr [0-9a-f:]+" | head -1)
    P90=$(ping -c 1 -W 1 -I wlp4s0 192.168.1.90 2>/dev/null | grep -c "64 bytes")
    M90=$(ip neigh show 192.168.1.90 2>/dev/null | grep -oE "lladdr [0-9a-f:]+" | head -1)
    echo "$T .88=$([ $P88 -gt 0 ] && echo ALIVE || echo dead) ${M88:-} | .90=$([ $P90 -gt 0 ] && echo ALIVE || echo dead) ${M90:-}" >> $LOG
    sleep 3
done
echo "=== watchdog end $(date +%H:%M:%S) ===" >> $LOG
