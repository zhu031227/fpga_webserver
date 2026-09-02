#!/bin/bash
# EXP-PAGE: GET / ×10 @ 8s 间隔 — 页面读(800次停等窗读/次)故障率与延迟分布
# 伴随: tcpdump(-U) + jpoll + ping_canary 均在后台
LOG=/tmp/p2_forensics/explog.md
echo "" >> $LOG
echo "## EXP-PAGE 开始 $(date +%H:%M:%S)" >> $LOG
for i in $(seq 1 10); do
  ts=$(date +%H:%M:%S.%3N)
  out=$(curl -s -m 15 --interface wlp4s0 http://192.168.1.128/ \
        -o /tmp/p2_forensics/page_$i.body -w "%{http_code} %{time_total}s %{size_download}B")
  echo "$ts GET_/#$i -> $out" >> $LOG
  echo "$ts GET_/#$i -> $out"
  sleep 8
done
echo "## EXP-PAGE 结束 $(date +%H:%M:%S)" >> $LOG
