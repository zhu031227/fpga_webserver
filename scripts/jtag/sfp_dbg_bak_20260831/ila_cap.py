#!/usr/bin/env python3
"""gmii1/gmii2 ILA 抓取：dv 触发 → 生成 ARP 流量 → 读波形 → 解码帧字节."""
import json, subprocess, sys, time

FPGA_ILA_HOST = sys.argv[1]  # fpga_ila/host 目录
SIGNALS_JSON = sys.argv[2]   # webserver_signals.json
PORT = "/dev/ttyACM0"

sys.path.insert(0, FPGA_ILA_HOST)
from fpga_ila import transport as T
from fpga_ila import device as D
from fpga_ila import capture as C

sig = json.load(open(SIGNALS_JSON))
cores = {c["core_id"]: c for c in sig["cores"]}

tr = T.SerialTransport(PORT, 921600, timeout=0.05)
dev = D.Device(tr, timeout=1.0)

def cap_core(core_id, gen_traffic, label):
    info = cores.get(core_id)
    if info is None:
        print(f"[{label}] core{core_id} 不在 signals.json，跳过"); return
    total_w = sum(p["width"] for p in info["probes"])
    depth = info["data_depth"]
    print(f"\n===== [{label}] core{core_id} '{info['name']}' width={total_w} depth={depth} =====")
    try:
        ping_v = dev.ping()
        print(f"ping ok (echo={ping_v:#x})")
        # 触发: probe0(dv)==1
        dev.set_trigger(core_id, value=1, mask=1, total_width=total_w)
        dev.set_trig_pos(core_id, depth // 2)      # 半窗口预触发
        dev.set_capture_len(core_id, depth)
        dev.arm(core_id)
        print("armed，等待触发...")
        if gen_traffic:
            subprocess.Popen(["ping", "-I", "eno1", "-i", "0.25", "-W", "1",
                              "-c", "40", "169.254.92.1"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        t0 = time.time()
        try:
            dev.wait_full(core_id, timeout=25.0)
            print(f"触发命中! 耗时 {time.time()-t0:.1f}s")
        except Exception as e:
            print(f"25s 内未触发: {e}")
            dev.disarm(core_id)
            return
        cfg = dev.get_core_cfg(core_id)   # 硬件读回的真实核配置
        raw = dev.read_buf(core_id, 0, depth)
        samples = C.decode_samples(raw, total_w)
        dv_hi = sum(1 for s in samples if s & 1)
        print(f"样本总数={len(samples)}  dv=1 样本数={dv_hi} ({100*dv_hi/max(1,len(samples)):.1f}%)")
        # 重建 dv==1 期间的字节流
        stream = []
        for s in samples:
            if s & 1:
                stream.append((s >> 1) & 0xFF)
        print(f"dv=1 期间字节流前 96 字节:")
        for i in range(0, min(96, len(stream)), 16):
            print("  " + " ".join(f"{b:02x}" for b in stream[i:i+16]))
        if not dv_hi:
            print(">>> dv 全程为 0：MAC 视角从未见过任何数据有效脉冲")
    except Exception as e:
        print(f"异常: {type(e).__name__}: {e}")

cap_core(4, gen_traffic=True,  label="gmii1/SFP1")
time.sleep(1)
cap_core(5, gen_traffic=False, label="gmii2/SFP2(静默观察)")
tr.close()
print("\ndone")
