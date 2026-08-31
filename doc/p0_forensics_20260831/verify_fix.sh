#!/bin/bash
# P2 修复后验证套件
LOG=/tmp/p2_forensics/explog.md
R=/tmp/p2_forensics
echo "" >> $LOG
echo "## 修复后验证 $(date +%H:%M:%S)" >> $LOG

echo "=== [1] 密度矩阵复测 ==="
for interval in 8 2 0.5 0.1; do
  fail=0
  for i in $(seq 1 15); do
    code=$(curl -s -m 8 --interface wlp4s0 http://192.168.1.128/api/wl/list -o /dev/null -w "%{http_code}")
    [ "$code" != "200" ] && { fail=$((fail+1)); echo "  FAIL int=$interval #$i code=$code"; }
    sleep $interval
  done
  echo "int=${interval}s: $((15-fail))/15 ok"
done

echo "=== [2] 25 连接压力(0.2s间隔) ==="
fail=0
for i in $(seq 1 25); do
  code=$(curl -s -m 5 --interface wlp4s0 http://192.168.1.128/api/wl/list -o /dev/null -w "%{http_code}")
  [ "$code" != "200" ] && { fail=$((fail+1)); echo "  FAIL #$i code=$code"; }
  sleep 0.2
done
echo "压力: $((25-fail))/25 ok"

echo "=== [3] 页面 GET ×5 ==="
fail=0
for i in $(seq 1 5); do
  out=$(curl -s -m 10 --interface wlp4s0 http://192.168.1.128/ -o /dev/null -w "%{http_code} %{time_total}s")
  code=${out%% *}
  [ "$code" != "200" ] && { fail=$((fail+1)); echo "  FAIL #$i $out"; }
  sleep 3
done
echo "页面: $((5-fail))/5 ok"
echo "## 验证结束 $(date +%H:%M:%S)" >> $LOG
