# FPGA WebServer 三网口 MAC 白名单 — 板级验证测试步骤书

> 文档编号：ED003R01  
> 日期：2026-07-07  
> 硬件平台：ACX750 (XC7A35T-FGG484-2)  
> 依赖：fpga_webserver 工程 + 1000BASE-X IP

---

## 1. 测试拓扑

```
┌─────────────────┐         ┌──────────────────┐         ┌─────────────────┐
│   测试 PC #1    │         │   ACX750 FPGA    │         │   上级路由器    │
│  (管理终端)      │         │                  │         │  (或测试 PC #2) │
│                 │         │                  │         │                 │
│  IP: 192.168.   │ 网线    │ eth0 (RGMII)     │ 光纤    │                 │
│  1.100/24       │◄───────►│ 管理口           │         │                 │
│                 │         │                  │  SFP2 ◄─┼───────────────►│
│  MAC: 任意      │         │ eth1 (SFP1)      │ 光纤    │                 │
│                 │         │ LAN 口 ◄─────────┼───────► │                 │
│                 │         │                  │         │  (WAN 侧)      │
│                 │         │  MAC 白名单过滤   │         │                 │
└─────────────────┘         └──────────────────┘         └─────────────────┘
       ┌─────────────────────────────────────────────────────┐
       │             被测设备 (DUT) — 用户 PC #3             │
       │                                                     │
       │  网口 ──光纤──► eth1 (SFP1, LAN 口)                 │
       │  IP: 任意 (桥接透明)                                │
       │  MAC: 需加入白名单才能上网                          │
       └─────────────────────────────────────────────────────┘
```

**物理连接：**

| 端口 | 接口类型 | 连接对象 | 线缆 |
|------|---------|---------|------|
| eth0 | RGMII (RJ45) | 测试 PC #1（管理终端） | 标准网线 |
| eth1 (SFP1) | 1000BASE-X (SFP) | 被测设备（用户 PC #3） | 单模/多模光纤 + SFP 模块 |
| eth2 (SFP2) | 1000BASE-X (SFP) | 上级路由器 / 测试 PC #2 | 单模/多模光纤 + SFP 模块 |
| UART | 3.3V TTL | 测试 PC #1（串口终端） | USB-TTL 模块 |
| JTAG | 6-pin | 测试 PC #1（Vivado） | Xilinx Platform Cable |

---

## 2. 准备工作

### 2.1 硬件准备

- [ ] ACX750 开发板 ×1
- [ ] 12V DC 电源适配器 ×1
- [ ] Xilinx Platform Cable (JTAG) ×1
- [ ] USB-TTL 串口模块 (3.3V) ×1
- [ ] SFP 光模块 ×2（1000BASE-SX 或 1000BASE-LX，与光纤匹配）
- [ ] 单模/多模光纤跳线 ×2
- [ ] RJ45 网线 ×1
- [ ] 测试用 PC ×2~3

### 2.2 软件准备

- [ ] Vivado 2024.1（已安装，含 XC7A35T 器件支持）
- [ ] RISC-V 工具链 (`riscv64-unknown-elf-gcc`)
- [ ] 串口终端软件 (minicom / PuTTY / Tera Term，115200-8-N-1)
- [ ] Vivado Hardware Manager（JTAG 下载）
- [ ] Wireshark（抓包分析）
- [ ] Python 3（TCL 脚本执行、辅助测试）

### 2.3 FPGA 镜像编译

```bash
# 1. 编译 FPGA bitstream
cd ~/work/fpga_webserver/build_xilinx_xc7a35tfgg484
vivado -mode batch -source build_fpga.sh

# 2. 编译 RISC-V 固件
cd ~/work/fpga_webserver/c_build
make PLATFORM=xilinx

# 3. 确认输出文件存在
ls -l webserver_xilinx_xc7a35tfgg484_*/webserver_*.bit
ls -l c_build/out/firmware_pads.bin
ls -l tcl/webserver_riscv_instruct_*.tcl
```

---

## 3. FPGA 下载与初始化

### 3.1 JTAG 下载 Bitstream

```tcl
# 在 Vivado Tcl Console 中执行：
open_hw
connect_hw_server
open_hw_target
set_property PROGRAM.FILE {webserver_*.bit} [get_hw_devices xc7a35t_0]
program_hw_devices [get_hw_devices xc7a35t_0]
```

**预期结果：** Vivado 提示 "Programmed successfully"。LED[0] 开始闪烁（heartbeat）。

### 3.2 JTAG 加载 RISC-V 固件

```bash
# 在 Vivado Tcl Console 中：
source tcl/webserver_riscv_instruct_YYYYMMDD_HHmmss.tcl
```

**预期结果：** 脚本执行完成无错误。LED 闪烁模式可能变化。

### 3.3 串口终端确认

```bash
minicom -D /dev/ttyUSB0 -b 115200
```

**预期结果：** 串口无异常输出（正常运行时无日志）。如有 `printf` 调试输出则为异常。

---

## 4. 测试用例

### 测试 1：eth0 管理口基础通信

| 项目 | 内容 |
|------|------|
| **目的** | 验证 eth0 RGMII 管理口正常工作 |
| **前置** | 测试 PC #1 网线连接 eth0，IP 设为 192.168.1.100/24 |

**步骤：**

```bash
# 1. ARP Ping（触发 ARP 请求/应答）
ping -c 3 192.168.1.88

# 2. 验证 ARP 表学到 MAC
arp -a | grep 192.168.1.88
```

**预期结果：**
- `ping` 收到 ARP 应答（或 ICMP echo reply，取决于固件是否支持 ICMP）
- `arp -a` 显示 `192.168.1.88` 对应 MAC `00:00:01:02:04:06`（默认）

```
# Wireshark 抓包验证：
# ARP Request:  who has 192.168.1.88? → ARP Reply: 00:00:01:02:04:06
```

---

### 测试 2：eth0 Web 管理页面

| 项目 | 内容 |
|------|------|
| **目的** | 验证 WebServer 主页可访问 |
| **前置** | 测试 1 通过 |

**步骤：**

```bash
# 浏览器打开
http://192.168.1.88/
```

**预期结果：**
- 页面显示 "RiscV@FPGA 嵌入式网关" 标题
- 显示两个按钮："本机配置" 和 "白名单配置"
- 底部显示系统信息（FPGA 型号、接口、版本号等）

```
# Wireshark 验证 TCP 三次握手 + HTTP GET → 200 OK + HTML 内容
```

---

### 测试 3：本机配置页面

| 项目 | 内容 |
|------|------|
| **目的** | 验证本机 IP/MAC 配置页读写 |
| **前置** | 测试 2 通过 |

**步骤：**

```bash
# 浏览器打开
http://192.168.1.88/localconfig
```

1. 页面应显示当前配置：默认 MAC `00:00:01:02:04:06`，IP `192.168.1.88`
2. **读取测试：** 确认显示值与默认值一致 ✓
3. **写入测试：** 修改 IP 为 `192.168.1.99`，点击 "保存配置"
4. 用新 IP 重新访问：`http://192.168.1.99/localconfig`，确认修改生效

**预期结果：**
- 页面正确加载当前配置
- 修改 IP 后用新 IP 可访问，旧 IP 不可访问
- "从 Flash 重新加载" 按钮恢复默认配置

```
# Wireshark 验证：
# GET /localconfig → HTTP 200 + HTML
# POST /api/local/save → JSON {"code":0,"msg":"ok"}
```

---

### 测试 4：白名单配置页面

| 项目 | 内容 |
|------|------|
| **目的** | 验证白名单 CRUD 操作 |
| **前置** | 测试 2 通过 |

**步骤：**

```bash
# 浏览器打开
http://192.168.1.88/wlconfig
```

1. 页面应显示白名单状态（初始：禁用，0/16 条目）
2. **添加 MAC：** 输入 `AA:BB:CC:DD:EE:FF`，点击 "添加"
3. 列表应刷新，显示条目 #0: `AA:BB:CC:DD:EE:FF`，状态 "有效"
4. **再添加 2 条：** `11:22:33:44:55:66`、`00:11:22:33:44:55`
5. 条目数应显示 3/16
6. **删除测试：** 点击条目 #1 的 "删除"，应减少为 2 条
7. **清空测试：** 点击 "清空全部" → confirm，条目数应变为 0/16

**预期结果：** 所有 CRUD 操作正常，计数正确更新。

```
# 通过 TCL 直接读寄存器验证（SubBus 0x1500）：
# TCL: lcpu_reg_read 0x150A  → 应返回 0x00000010 (16 entries max)
# TCL: lcpu_reg_read 0x150B  → 应返回当前条目数
```

---

### 测试 5：白名单过滤 — 默认全断策略

| 项目 | 内容 |
|------|------|
| **目的** | 验证白名单关闭时 LAN→WAN 方向阻断所有流量 |
| **前置** | SFP1 接被测 PC #3，SFP2 接路由器/PC #2；白名单为空，**禁用状态** |

**步骤：**

```bash
# 在被测 PC #3 上执行（eth1/SFP1 侧）
ping -c 10 <WAN侧IP>      # 例如 ping 192.168.1.1

# 观察 WAN 侧 PC #2 抓包
```

**预期结果：**
- PC #3 的 ping **全部超时**（白名单禁用 + default_pass=0 = 全断）
- WAN 侧抓包无来自 PC #3 的 ICMP 报文
- Web 页面统计：`wl_rx_drop_cnt` 应递增

---

### 测试 6：白名单过滤 — 添加 MAC 后放行

| 项目 | 内容 |
|------|------|
| **目的** | 验证白名单启用后，已注册 MAC 可通过 |
| **前置** | 测试 5 通过 |

**步骤：**

```bash
# 1. 在管理 PC 上打开 http://192.168.1.88/wlconfig
# 2. 添加 PC #3 的源 MAC（如 AA:BB:CC:DD:EE:FF）
# 3. 点击 "启用白名单"（wl_ctrl[0]=1）
```

```bash
# 4. 在 PC #3 上再次执行
ping -c 10 <WAN侧IP>
```

**预期结果：**
- ping **全部成功**（PC #3 的 MAC 在白名单中）
- WAN 侧抓包可见 ICMP request 和 reply（WAN→LAN 回程透传）
- Web 页面统计：`wl_rx_pass_cnt` 递增，`wl_rx_drop_cnt` 不再增长

---

### 测试 7：白名单过滤 — 未注册 MAC 被拦截

| 项目 | 内容 |
|------|------|
| **目的** | 验证未注册 MAC 的流量被丢弃 |
| **前置** | 测试 6 通过（白名单启用，仅有 PC #3 MAC） |

**步骤：**

```bash
# 1. 换一台 PC #4（MAC 不在白名单）接入 SFP1
# 2. 执行 ping <WAN侧IP>
```

**预期结果：**
- PC #4 的 ping **全部超时**
- WAN 侧无 PC #4 的报文
- Web 页面 `wl_rx_drop_cnt` 递增

---

### 测试 8：回程透传 (WAN→LAN)

| 项目 | 内容 |
|------|------|
| **目的** | 验证 eth2→eth1 方向无条件透传 |
| **前置** | 任意状态 |

**步骤：**

```bash
# 方法 1：从 WAN 侧 PC #2 ping LAN 侧 PC #3
# （PC #3 的网关需指向 WAN 侧路由器，或使用 Proxy ARP）

# 方法 2：在 WAN 侧 PC #2 上
arping -I ethX <PC#3 IP>    # 发 ARP 请求到 LAN 侧
```

**预期结果：**
- WAN→LAN 方向报文无阻塞通过（不检查白名单）
- eth2 收到的非本地 MAC 报文全部转发到 eth1

```
# Wireshark 同时抓 SFP1 和 SFP2 两侧验证：
# eth2 收到的帧 → eth1 TX 发出（原样，不修改 MAC/IP/TTL）
```

---

### 测试 9：二层透明性验证

| 项目 | 内容 |
|------|------|
| **目的** | 验证桥接不修改报文（无 NAT，无 TTL 递减） |

**步骤：**

```bash
# 1. PC #3 ping WAN 侧，Wireshark 同时在 eth1 和 eth2 抓包
# 2. 对比 SrcMAC / DstMAC / IP TTL / IP checksum
```

**预期结果：**
- eth1 收到的帧和 eth2 发出的帧 **完全一致**（除 FCS 重算）
- SrcMAC / DstMAC **不变**
- IP TTL **不递减**
- IP checksum **不变**（因为没有修改 IP 头）

---

### 测试 10：SPI Flash 持久化

| 项目 | 内容 |
|------|------|
| **目的** | 验证配置和白名单断电不丢失 |

**步骤：**

```bash
# 1. 添加几条白名单 MAC 并保存
#    http://192.168.1.88/wlconfig → 添加 3 条 → "保存到 Flash"
# 2. 修改本机配置 → "保存配置"
# 3. 记录当前配置
# 4. FPGA 断电，等待 10 秒
# 5. 重新上电，加载固件
# 6. 访问 http://192.168.1.88/wlconfig，检查白名单是否恢复
# 7. 访问 http://192.168.1.88/localconfig，检查本机配置是否恢复
```

**预期结果：**

> **注意：** Flash 持久化功能需要固件支持 Flash 读写（`local_config.c` 和 `whitelist.c` 中的 `_save_to_flash()` / `_load_from_flash()` 函数）。当前 C 代码中这些函数为 **占位实现**（stub），仅写寄存器不操作 Flash。

- [ ] **Flash 读/写功能未实现时：** 断电重启后恢复默认值（`local_mac_h=0x00000102`, IP=`192.168.1.88`，白名单为空）
- [ ] **Flash 读/写功能实现后：** 断电重启后配置完全恢复

---

### 测试 11：统计计数器验证

| 项目 | 内容 |
|------|------|
| **目的** | 验证 eth0/eth1/eth2 统计计数器正确累加 |

**步骤：**

```bash
# 通过 TCL JTAG 读取统计寄存器（或 Web API）
# eth0 统计：0x100-0x106
# eth1 统计：0x110-0x116
# eth2 统计：0x118-0x11E
# 白名单丢弃：wl_ctrl 相关

# 读取示例（Vivado TCL）：
lcpu_reg_read 0x100    # eth0 rx_correct_pkt_cnt
lcpu_reg_read 0x110    # eth1 rx_correct_pkt_cnt
lcpu_reg_read 0x118    # eth2 rx_correct_pkt_cnt
```

**预期结果：**
- eth0 `rx_correct_pkt_cnt` 随 Web 访问递增
- eth1 `rx_correct_pkt_cnt` 随 LAN 侧流量递增
- eth2 `rx_correct_pkt_cnt` 随 WAN 侧回程流量递增
- 各端口 `rx_crc_err_pkt_cnt` 应为 0（正常光纤连接下）

---

### 测试 12：千兆吞吐量

| 项目 | 内容 |
|------|------|
| **目的** | 验证千兆线速转发能力 |

**步骤：**

```bash
# PC #3 (LAN侧) 和 PC #2 (WAN侧) 安装 iperf3

# WAN 侧 PC #2 作为 server：
iperf3 -s

# LAN 侧 PC #3 作为 client（MAC 已在白名单中）：
iperf3 -c <WAN侧IP> -t 30 -P 4
```

**预期结果：**
- 吞吐量接近 1Gbps 线速（减去以太网开销，约 940 Mbps TCP payload）
- 无丢包或极少丢包
- `eth1_rx_drop_cnt` 不增长（白名单匹配）

---

## 5. JTAG 调试命令参考

```tcl
# === 寄存器读写 ===
# 读本地 MAC 高 16 位
lcpu_reg_read 0x202

# 读白名单控制寄存器
lcpu_reg_read 0x300

# 写白名单 SubBus：读 max entries
lcpu_reg_read 0x150A    # 应返回 0x10 (16)

# 写白名单 SubBus：添加 MAC AA:BB:CC:DD:EE:FF
lcpu_reg_write 0x1500 0x00000000   # index=0
lcpu_reg_write 0x1501 0xAABBCCDD   # MAC[47:16]
lcpu_reg_write 0x1502 0x0000EEFF   # MAC[15:0]
lcpu_reg_write 0x1503 0x00000001   # WR pulse

# 写白名单 SubBus：读回验证
lcpu_reg_read 0x1506    # MAC[47:16] = 0xAABBCCDD
lcpu_reg_read 0x1507    # MAC[15:0]  = 0x0000EEFF
lcpu_reg_read 0x1508    # valid = 1

# === GPIO / LED ===
# LED[3:0] 控制
lcpu_reg_write 0x30 0x0000000A     # LED pattern

# === Flash 操作 (SubBus 0x1400) ===
# 读 Flash JEDEC ID
lcpu_reg_write 0x1400 0x0000009F   # 命令高字: 0x9F (Read ID)
lcpu_reg_write 0x1401 0x00000000   # 命令低字
lcpu_reg_write 0x1402 0x00000018   # 长度: 24 bits
lcpu_reg_write 0x1405 0x00000001   # start
lcpu_reg_read  0x1403              # 读返回数据
```

---

## 6. 调试流程

### 6.1 Link 不通

```
现象：SFP 端口无 link（LED 不亮 / status_vector 异常）
排查：
  1. 检查 SFP 模块是否插紧，光纤是否正确（TX→RX 交叉）
  2. JTAG 读 status_vector：lcpu_reg_read (地址取决于映射)
     bit[0] = link status
  3. 检查 gtrefclk 125MHz 是否正常（量时钟引脚）
  4. 检查 GTPE2_CHANNEL LOC 约束是否正确（X0Y0, X0Y1）
  5. Vivado 看 MMCM locked 信号
```

### 6.2 白名单不生效

```
现象：白名单启用后 MAC 仍在被拦截（或全部放行）
排查：
  1. JTAG 读 wl_ctrl (0x300)：bit[0]=1 启用，bit[1]=0 全断
  2. TCL 直接读 SubBus 0x1500 验证 BRAM 内容
  3. 检查 wl_ctrl CDC 同步是否正常（cdc_bus_sync 锁定？）
  4. 用 ILA 抓 gmii1_rx_dv + wl_lookup_req + wl_lookup_match 时序
```

### 6.3 Web 页面无响应

```
现象：浏览器访问 192.168.1.88 超时
排查：
  1. ping 192.168.1.88 是否通（ARP 层）
  2. 串口是否有异常输出
  3. Wireshark 抓 eth0：是否收到 HTTP GET？是否发出 TCP SYN+ACK？
  4. JTAG 读 eth0 统计寄存器，确认 RX 计数增长
  5. 检查 PHY 是否 link up（MDIO 读 RTL8211 寄存器）
```

---

## 7. 测试结果记录表

| 编号 | 测试项 | 结果 | 备注 |
|------|--------|------|------|
| 1 | eth0 ARP/ICMP | ☐ 通过 ☐ 失败 | |
| 2 | Web 主页访问 | ☐ 通过 ☐ 失败 | |
| 3 | 本机配置页 | ☐ 通过 ☐ 失败 | |
| 4 | 白名单 CRUD | ☐ 通过 ☐ 失败 | |
| 5 | 默认全断策略 | ☐ 通过 ☐ 失败 | |
| 6 | 白名单放行 | ☐ 通过 ☐ 失败 | |
| 7 | 未注册 MAC 拦截 | ☐ 通过 ☐ 失败 | |
| 8 | 回程透传 | ☐ 通过 ☐ 失败 | |
| 9 | 二层透明性 | ☐ 通过 ☐ 失败 | |
| 10 | Flash 持久化 | ☐ 通过 ☐ 失败 | |
| 11 | 统计计数器 | ☐ 通过 ☐ 失败 | |
| 12 | 千兆吞吐量 | ☐ 通过 ☐ 失败 | |

---

*文档结束*
