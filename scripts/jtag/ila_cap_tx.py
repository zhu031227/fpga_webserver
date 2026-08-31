#!/usr/bin/env python3
"""core6 u_ila_cpu_tx(50M CPU域) 抓取: 默认 push 触发 → 验证 ILA 链路与 CPU 侧 TX 行为.

用法: python3 scripts/jtag/ila_cap_tx.py <fpga_ila_host目录> <signals.json> [等待秒] [触发模式]
  触发模式 push(默认)=probe1==1 包push;  full=probe0==1 FIFO满(楔点标志)
探针布局 (v0010 signals.json core 6, 50MHz cpu_clk 域):
  bit0      cpu_wr_full          TX FIFO 写侧满
  bit1      cpu_wr_wpkt_push_ind 包push脉冲
  bit2      cpu_wr_wen_ind       写使能
  bit3      cpu_rd_empty         RX FIFO 空
  bit4      cpu_rd_rpkt_pop_ind  CPU收包pop
  bit5..17  cpu_wr_wpkt_len      push包长(13b)
  bit18..29 cpu_wr_waddr         TX FIFO 写指针(12b)
"""
import json, subprocess, sys, time

FPGA_ILA_HOST = sys.argv[1]
SIGNALS_JSON = sys.argv[2]
WAIT_S = float(sys.argv[3]) if len(sys.argv) > 3 else 60.0
TRIG = sys.argv[4] if len(sys.argv) > 4 else "push"
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
print(f"core{CORE} '{info['name']}' width={total_w} depth={depth} 触发={TRIG}")

tr = T.SerialTransport(PORT, 921600, timeout=0.05)
dev = D.Device(tr, timeout=1.0)
print("ping:", hex(dev.ping()))

trig_val, trig_mask = (1 << 1, 1 << 1) if TRIG == "push" else (1 << 0, 1 << 0)
dev.set_trigger(CORE, value=trig_val, mask=trig_mask, total_width=total_w)
dev.set_trig_pos(CORE, depth // 2)
dev.set_capture_len(CORE, depth)
dev.arm(CORE)
print(f"armed, 后台打流 ping -i 0.15, 等待最长 {WAIT_S}s ...")
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
RXE, RXPOP = 1 << 3, 1 << 4
LENM = 0x1FFF << 5
WADDRM = 0xFFF << 18

full = [bool(s & FULL) for s in samples]
push = [bool(s & PUSH) for s in samples]
rxpop = [bool(s & RXPOP) for s in samples]
lengths = [(s & LENM) >> 5 for s in samples]
waddr = [(s & WADDRM) >> 18 for s in samples]
trig_i = depth // 2

n_push = sum(push)
print(f"\n样本 {len(samples)} (触发点 idx={trig_i})  push脉冲样本 {n_push}")
pushes_idx = [i for i, v in enumerate(push) if v]
if pushes_idx:
    a, b = pushes_idx[0], pushes_idx[-1]
    print(f"push 活动区间 idx {a}~{b} (跨 {(b-a)*20}ns@50MHz)")
    print(f"包长样本: {[lengths[i] for i in pushes_idx[:12]]}")
    print(f"waddr 走向: {waddr[a]:03x} -> {waddr[b]:03x}")
    wen_cnt = sum(1 for s in samples if s & WEN)
    print(f"wen=1 样本 {wen_cnt}  full=1 样本 {sum(full)}  rx_pop 样本 {sum(rxpop)}")
    print("\n>>> 判读: push 后 waddr 前进 + full 保持 0 = 写路径健康(与 JTAG 取证一致);")
    print(">>>         push 密集而 full=1 = FIFO 顶死(写被掩)。")
print("done")
