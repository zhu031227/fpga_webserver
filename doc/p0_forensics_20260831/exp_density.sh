#!/bin/bash
# EXP-DENSITY: /api/wl/list 密度扫描 — 空响应率 vs 请求间隔
# 档位: 8s 2s 0.5s 0.1s × 15发；档间 12s 冷却
LOG=/tmp/p2_forensics/explog.md
RES=/tmp/p2_forensics/density_results.txt
> $RES
for interval in 8 2 0.5 0.1; do
  echo "## EXP-DENSITY int=${interval}s 开始 $(date +%H:%M:%S)" >> $LOG
  for i in $(seq 1 15); do
    ts=$(date +%H:%M:%S.%3N)
    out=$(curl -s -m 8 --interface wlp4s0 http://192.168.1.128/api/wl/list \
          -o /tmp/p2_forensics/d_${interval}_$i.json -w "%{http_code} %{time_total}s %{size_download}B")
    echo "$ts int=$interval #$i $out" >> $RES
    sleep $interval
  done
  echo "## EXP-DENSITY int=${interval}s 结束 $(date +%H:%M:%S)" >> $LOG
  sleep 12
done
echo "=== 汇总 ==="
awk '{split($4,a," "); print $3, a[1]}' $RES | sort | uniq -c
