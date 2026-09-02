# P2/P0 取证实验日志 2026-08-31
基础设施: tcpdump(wlp.pcap2, -U) + jpoll(jpoll.log, 2s) + ping_canary(ping_canary.log, 3s) + UART(uart.log)
事件时间轴:
- 13:22:48 固件重载完成(救活挂死板)
- 13:23:10 验活 ping 3/3 + curl / 200 @20ms
- 13:31:26.87 GET / SYN×6 无应答 → ARP 亦死(主循环冻结形态)
- 13:31:55.97 自愈: ARP 4ms 回包, diag 6ms 200
- 13:31:55-13:32:12 diag/status 200 OK
- 13:33 新 tcpdump(-U) 启动, jpoll 启动中

## EXP-PAGE 开始 13:41:38
13:41:38.859864208 GET_/#1 -> 200 0.018738s 1077B
13:41:46.894849278 GET_/#2 -> 200 0.019660s 1077B
13:41:54.932524445 GET_/#3 -> 200 0.018409s 1077B
13:42:02.970163923 GET_/#4 -> 200 0.019172s 1077B
13:42:11.8959422 GET_/#5 -> 200 0.019480s 1077B
13:42:19.47609999 GET_/#6 -> 200 0.023766s 1077B
13:42:27.90491033 GET_/#7 -> 200 0.018542s 1077B
13:42:35.126842349 GET_/#8 -> 200 0.018929s 1077B
13:42:43.165213699 GET_/#9 -> 200 0.023104s 1077B
13:42:51.206720247 GET_/#10 -> 200 0.025256s 1077B
## EXP-PAGE 结束 13:42:59
## EXP-DENSITY int=8s 开始 13:44:29
## EXP-DENSITY int=8s 结束 13:47:09
## EXP-DENSITY int=2s 开始 13:47:21
## EXP-DENSITY int=2s 结束 13:47:52
## EXP-DENSITY int=0.5s 开始 13:48:04
## EXP-DENSITY int=0.5s 结束 13:48:12
## EXP-DENSITY int=0.1s 开始 13:48:24
## EXP-DENSITY int=0.1s 结束 13:48:27

## P2 取证中期结论 (14:20)
实锤机制(全部有 pcap/JTAG/代码三重证据):
1. 固件时钟冻结: 0x07 是锁存器, 全固件无人写 0x06 触发 → local_time 恒0(历史)/阶梯(jpoll era)
   → ISN 恒0(pcap: SYN-ACK seq 0), 全部 TCP 定时器死, TIME_WAIT/idle 永不过期
   → 僵尸槽(LAST_ACK)永不清理 → 16槽耗尽 → SYN 静默黑洞 → 历史P2"空响应"+"板子报废"
2. 定时常数 20.6× 标定错误: 常数按 50MHz, 实测计数器 ~1.03GHz(4.17s 回卷, latch_delta 负值抓获)
   → IDLE 40s→1.94s, TIMEWAIT 2s→97ms, SYN_RETRY 3s→146ms
3. 僵尸槽: FIN|ACK 从未上线(14:10:43 pcap: 只回裸ACK) + LAST_ACK 要求 final ACK 精确匹配
   → PC 端口复用(1.2s 内!)后 SYN 被僵尸吞掉(0.1s档#11 完整抓获)
4. TX 侧死亡窗口(10-30s): 黑洞窗口 tx_good 冻结+0, ICMP 回包消失, SYN-ACK 发不出
   → 13:31 ARP 全死窗口同源(ARP 回复=TX)。RX 一直活(rx_good 持续计数)
   → 待判: TX-only vs CPU 冻结(P0) → jpoll2 LED 探针(0x30) 2s 粒度裁决
5. 金丝雀 v1 乌龙: ping -q + 重定向 = 缓冲到退出才落盘, 之前"全绿"判读作废 → 已换逐包版
仪器现状: all.pcap(双向+广播, -B4096 immediate), jpoll2(LED探针), canary2(逐包), UART口=ILA传输(非固件)

## 修复后验证 14:25:12
## 验证结束 14:29:04

## 修复进展 (15:00)
- P2 固件修复已验证: 密度2s/0.5s/0.1s 全过, 25连接压力 25/25 (旧固件必死)
- P3 迁移已验证: 页面 GET 走 sflash 路径, 1077B 逐字节一致, 21-26ms 有界延迟, MAGIC 自校准字节序正确
- wl_status RTL 折入 v0009: mac_whitelist_seq 输出 wl_used_cnt(cfg域popcount) → top 聚合 {used_cnt,LOOKUP_MODE} → wrapper 接 wl_status 线 → reg_webserver 0x301 mux(原有)
- ILA 核6 折入 v0009: u_ila_cpu_tx @wrapper, 125MHz, 10探针43bit, 触发=cpu_wr_full
- v0009 bit 构建中 (14:51 起)

## 终审 (16:10)
- 真空期签名(两变体): 上行变体=单播请求不达板卡MAC(first_word只见广播); 下行变体=板卡正常push但回包不到PC
- PC tx_failed 真空期零增量 = PC 成功交帧给 AP → 帧死在 AP 内部
- 1/s ping 300/300 全绿 vs 5/s canary 持续真空 → AP 疑似按持续速率触发的安全引擎, ~90s 冷却
- 密度倒挂同解: 持续后台流保持热点, 慢节奏测试撞窗; 短爆发打完就收躲过触发延迟
- 板卡/RTL/固件三方清白; P2 三真 bug 已修; P3/wl_status 已交付
- 详见 doc/P0取证报告与移交_20260831.md (队友接手: 有线验证 20 分钟可裁决)
