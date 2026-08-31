#!/usr/bin/env python3
"""core6 u_ila_cpu_tx 抓取: TX FIFO 满触发 → 抓 TX 通路卡死现场.

用法: python3 scripts/jtag/ila_cap_tx.py <fpga_ila_host目录> <signals.json> [等待秒]
探针布局 (signals.json core 6):
  bit0     cpu_wr_full          TX FIFO 写侧满
  bit1     cpu_wr_wpkt_push_ind 包push脉冲
  bit2     cpu_wr_wen_ind       写使能
  bit3     cpu_rd_empty         RX FIFO 空
  bit4     cpu_rd_rpkt_pop_ind  CPU收包pop
  bit5     eth0_mac_tx_en       MAC 线上 TX 活动
  bit6     eth0_mac_tx_sop      包起始
  bit7..19 cpu_wr_wpkt_len      push包长
  bit20..27 recv_pkt_drop_cnt   RX丢包计数
  bit28..39 cpu_wr_waddr        TX FIFO 写指针
"""
import json, subprocess, sys, time

FPGA_ILA_HOST = sys.argv[1]
SIGNALS_JSON = sys.argv[2]
WAIT_S = float(sys.argv[3]) if len(sys.argv) > 3 else 150.0
PORT = "/dev/ttyACM0"
CORE = 6

sys.path.insert(0, FPGA_ILA_HOST)
from fpga_ila import transport as T
from fpga_ila import device as D
from fpga_ila import capture as C

sig = json.load(open(SIGNALS_JSON))
info = {c["core_id"]: c for c in sig["cores"]}[CORE]
total_w = sum(p["width"] for p in info["probes"])
depth = info["data_depth"]
print(f"core{CORE} '{info['name']}' width={total_w} depth={depth}")

tr = T.SerialTransport(PORT, 921600, timeout=0.05)
dev = D.Device(tr, timeout=1.0)
print("ping:", hex(dev.ping()))

# 触发: cpu_wr_full==1 (健康态几乎不会满; 满即楔点标志), 半窗预触发
dev.set_trigger(CORE, value=1, mask=1, total_width=total_w)
dev.set_trig_pos(CORE, depth // 2)
dev.set_capture_len(CORE, depth)
dev.arm(CORE)
print(f"armed, 触发条件 full==1, 后台打流 ping -i 0.15, 等待最长 {WAIT_S}s ...")
pinger = subprocess.Popen(["ping", "-i", "0.15", "-W", "1", "-c", str(int(WAIT_S / 0.15) + 10),
                           "192.168.1.128"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
t0 = time.time()
try:
    dev.wait_full(CORE, timeout=WAIT_S)
    print(f"触发命中! 耗时 {time.time()-t0:.1f}s")
except Exception as e:
    print(f"未触发: {e}")
    dev.disarm(CORE)
    pinger.terminate()
    tr.close()
    sys.exit(2)

cfg = dev.get_core_cfg(CORE)
raw = dev.read_buf(CORE, 0, depth)
samples = C.decode_samples(raw, total_w)
tr.close()

FULL, PUSH, WEN = 1 << 0, 1 << 1, 1 << 2
RXE, RXPOP, TXEN, TXSOP = 1 << 3, 1 << 4, 1 << 5, 1 << 6
LENM = 0x1FFF << 7
DROPM = 0xFF << 20
WADDRM = 0xFFF << 28

full = [bool(s & FULL) for s in samples]
txen = [bool(s & TXEN) for s in samples]
push = [bool(s & PUSH) for s in samples]
waddr = [(s & WADDRM) >> 28 for s in samples]
drop = [(s & DROPM) >> 20 for s in samples]
trig_i = depth // 2

n_full = sum(full)
first_full = next((i for i, v in enumerate(full) if v), -1)
print(f"\n样本 {len(samples)} (触发点 idx={trig_i})  full=1 样本 {n_full} ({100*n_full/len(samples):.1f}%)")
print(f"首个 full=1 @idx {first_full} ({(first_full-trig_i)} 样本于触发点{'前' if first_full<trig_i else '后'})")

# 触发点前后各 256 样本统计
for lo, hi, tag in [(max(0, trig_i-256), trig_i, "触发前"), (trig_i, min(len(samples), trig_i+256), "触发后")]:
    seg = range(lo, hi)
    print(f"[{tag}] full={sum(full[i] for i in seg)}/{hi-lo} tx_en={sum(txen[i] for i in seg)} "
          f"push={sum(push[i] for i in seg)} waddr {waddr[lo]:03x}->{waddr[hi-1]:03x} drop={drop[hi-1]}")

# full 拉高期间的分段: tx_en/push 活性
if n_full:
    runs = []
    s = None
    for i, v in enumerate(full + [False]):
        if v and s is None: s = i
        if not v and s is not None:
            runs.append((s, i)); s = None
    runs = [(a, b) for a, b in runs if b - a > 4][:8]
    print(f"\nfull 高电平段 (>4样本, 最多8段):")
    for a, b in runs:
        seg = range(a, b)
        print(f"  idx {a}-{b} ({b-a}样本): tx_en={sum(txen[i] for i in seg)} push={sum(push[i] for i in seg)} "
              f"waddr {waddr[a]:03x}->{waddr[b-1]:03x}")

print("\n>>> 判读: full=1 且 push 持续 = CPU在推但被掩(FIFO满丢包);")
print(">>>         full=1 且 tx_en=0 持续 = MAC 不排空(排空侧卡死);")
print(">>>         waddr 冻结 + push 持续 = 写被完全掩掉。")
print("done")
