# FPGA WebServer 设计思路与实现方法（基于本工程）

## 1. 目标与定位

本文档面向“如何在 FPGA 上实现可用 WebServer”这一问题，总结本工程在 `WebServer/C` 的核心实现思路，重点覆盖：

- 软核 CPU + 硬件以太网收发 FIFO 的协同模式
- 轻量协议栈（ARP/IP/ICMP/TCP/HTTP）的最小闭环
- 在资源受限场景下实现网页交互与寄存器读写
- 从 C 代码到 FPGA 工程初始化文件的构建与落地流程

该实现强调“可跑通、可维护、可扩展”，适合做 FPGA 网络控制类项目的参考模板。

---

## 2. 系统总体架构

### 2.1 分层视角

系统可以分成三层：

1. **硬件层（FPGA RTL）**
   - 以太网 MAC / 包收发硬件
   - 面向 CPU 的包 FIFO 与寄存器映射窗口
   - 指令 RAM（由 C 固件初始化）

2. **固件层（`WebServer/C`）**
   - 在软核 CPU 上运行的网络协议处理逻辑
   - 主循环轮询收包，按协议逐层处理并回包

3. **页面与应用层（`http.c` + `tcp.c`）**
   - 内嵌网页字符串（GET 返回）
   - POST 解析后执行寄存器读写并反馈结果

### 2.2 控制流入口

- 主入口在 `main.c`，最终进入 `designApp()`。
- `designApp()` 中完成：
  - 初始化 HTTP 响应模板到共享 RAM
  - 心跳 LED
  - 收包后按 ARP/IP/TCP/ICMP 路径分发

核心调度链路：

`designApp -> eth_proc -> (arp_reply | ip_proc -> (icmp_reply | tcp_packet_handler))`

---

## 3. 硬件接口模型（关键）

### 3.1 内存映射寄存器抽象

`inc/lcpu_general.h` 定义了 `lcpu_baseaddr` 及收发 FIFO、调试 RAM 的寄存器布局，并通过宏做了统一访问抽象。

常用宏分组：

- **收包通道**：`LCPU_RD_SET_ADDR`、`LCPU_RD_DATA8`、`LCPU_RD_PKT_LEN`
- **发包通道**：`LCPU_WR_BYTE`、`LCPU_WR_PUSH_PACKET`
- **共享 RAM**：`LCPU_DBG_READ`、`LCPU_DBG_WRITE`
- **普通寄存器**：`LCPU_REG32_READ/WRITE`

这层抽象的价值：

- 屏蔽底层寄存器细节，降低协议代码耦合
- 便于移植到不同软核或地址布局
- 统一访问风格，减少维护错误

### 3.2 数据通路特点

- RX 方向：通过 `rd_pkt_fifo` 按字节读取收到的数据包。
- TX 方向：通过 `wr_pkt_fifo` 按字节写入回包，再 `wpkt_push` 触发发送。
- `dbg_ram_0` 既用于临时协议数据，也用于页面内容/参数缓存。

---

## 4. 协议处理策略（逐层）

### 4.1 二层：Ethernet + ARP

- `eth_proc()` 先识别 EtherType：ARP 或 IP。
- 对 IP 包先校验目的 MAC 是否为本机，再构造回包 Ethernet 头。
- `arp_reply()` 在 ARP Request 时构造 ARP Reply 并直接回发。

实现特点：

- 纯字节级处理，逻辑清晰，硬件接口友好。
- 不依赖复杂库，适合资源受限环境。

### 4.2 三层：IP

`ip_proc()` 完成：

- 目的 IP 匹配（过滤非本机包）
- 源 IP 提取（后续回包使用）
- 协议号识别（ICMP/UDP/TCP）

`ip_header_update()` 负责回包时更新：

- Total Length
- 源/目的 IP
- Header Checksum

### 4.3 四层：ICMP

`icmp_reply()` 支持 ICMP Echo Reply（Ping 回应）：

- 更新 IP 头
- 修改 ICMP Type/Code
- 重算 ICMP 校验和
- 回发整包

这确保了网络连通性诊断（Ping）可用。

### 4.4 四层：TCP（核心复杂度）

`tcp.c` 实现了轻量连接管理：

- 固定连接槽（`MAX_CONNECTIONS`）
- 状态机（`CLOSED/SYN_RECEIVED/ESTABLISHED/...`）
- 三次握手关键路径（SYN -> SYN+ACK -> ACK）
- ACK/FIN/RST 基础处理

关键设计点：

1. **并行数组替代结构体池**
   - `connection_states`、`connection_seq_nums` 等
   - 在该代码风格下更直观，也便于静态资源控制

2. **共享 TCP 头构造**
   - 使用统一函数写入 `dbg_ram_0[512..531]`
   - 降低重复代码与字段不一致风险

3. **Checksum 统一内核**
   - `tcp_checksum_common()` 抽象了 RAM/指针两种来源
   - 对外保留两个接口，兼顾兼容性与复用

### 4.5 七层：HTTP

- GET：返回 `main_page`（内嵌 HTML/JS）
- POST：提取关键字段并触发寄存器访问逻辑，返回 `post_response`

实现策略：

- 不做完整 HTTP 解析器，只匹配方法关键字（`GET`/`POST`）
- 页面内容静态内嵌，避免文件系统依赖
- 通过 JavaScript `fetch('/submit', {method:'POST', ...})` 完成交互

---

## 5. 应用功能：网页控制 FPGA 寄存器

`tcp.c` 中通过 `read_and_write_pairs()` + `reg_access()` 将 POST 数据映射为寄存器操作：

- 从 TCP payload 提取地址/数据/模式相关 ASCII 字段
- 转换为数值后调用 `write_lcpu_register()`/`read_lcpu_register()`
- 将结果回填到响应内容缓冲区

这给出了一种典型“Web 控制面”实现模式：

> 浏览器页面 -> HTTP POST -> 软核解析 -> 片上寄存器读写 -> HTTP 返回结果

---

## 6. 构建与部署方法（可复用）

构建脚本：`Tools/Compile_local.bat`

主要步骤：

1. 编译 `C/*.c` 为目标文件
2. 链接生成 `firmware.elf`
3. `objcopy` 得到 `firmware.bin`
4. 强制检查 16KB 容量上限并补零
5. 生成：
   - `RTL/InstructRAM.v`（Verilog 参数初始化）
   - `RTL/InstructRAM.hex`（Quartus 初始化）
6. 自动同步到 `PAR/InstructRAM.hex`
7. 可选 `-quartus_run` 触发全流程 FPGA 编译

该脚本保证了“固件-RTL-工程”联动的一致性。

---

## 7. 资源与约束思路

### 7.1 容量约束

- 固件大小约束为 16KB（脚本硬检查）
- 若超限直接失败，避免静默截断导致不可预期行为

### 7.2 运行时缓冲约束

- `HTTP_RESP_SIZE` 受共享 RAM 使用限制
- 页面/响应设计需控制长度，且 `Content-Length` 必须精确

### 7.3 连接与并发策略

- 固定连接槽（当前配置 `MAX_CONNECTIONS=8`）
- 简化状态机策略优先保证稳定，而非完整 TCP 特性

---

## 8. 这个方案适合什么场景

适合：

- FPGA 控制类项目（寄存器配置、状态查询）
- 需要“本地网页 + 轻量协议栈”的嵌入式场景
- 对可解释性、可控资源、可裁剪性要求高的系统

不适合：

- 需要高并发、高吞吐、完整 HTTP/TLS 特性的生产 Web 服务
- 需要复杂动态页面与完整应用框架的场景

---

## 9. 可扩展建议

1. **协议层**
   - 增加 UDP 服务（`udp.c` 目前预留）
   - 完善 TCP 重传/窗口管理

2. **应用层**
   - 增加 JSON 字段完整校验
   - 将页面模板与业务逻辑解耦

3. **工程层**
   - 增加单元/仿真测试用例（协议字段回归）
   - 增加自动化检查（固件大小、关键常量一致性）

---

## 10. 复用这套 FPGA WebServer 方法的最小步骤

1. 先定义硬件侧“包 FIFO + 寄存器窗口”接口。
2. 在软核固件中建立统一寄存器访问宏层。
3. 先打通 ARP + ICMP（确保链路可达）。
4. 再接入 TCP 三次握手与最小 HTTP GET。
5. 最后加入 POST 到寄存器映射，实现业务闭环。
6. 用脚本固化“编译 -> RAM 初始化 -> 工程同步”的流程。

做到以上 6 步，就可以形成一个可运行、可演示、可二次开发的 FPGA WebServer 基线平台。

---

## 11. 代码定位（便于阅读）

- 启动与入口：`C/main.c`
- 主调度：`C/designApp.c`
- 硬件接口与宏：`C/inc/lcpu_general.h`
- 协议模块：`C/eth.c`, `C/arp.c`, `C/ip.c`, `C/icmp.c`, `C/tcp.c`
- 页面模板：`C/http.c`
- 构建脚本：`Tools/Compile_local.bat`

---

## 12. 总结

本工程展示了一个非常实用的 FPGA WebServer 实现路径：

- 通过“软核 C 协议栈 + 硬件包收发接口”实现网络闭环；
- 以最小功能集打通网页控制 FPGA 寄存器；
- 通过脚本化构建确保从源码到 FPGA 工程的一致落地。

对希望在 FPGA 项目中快速加入 Web 控制面的团队，这是一条投入小、见效快、易持续演进的方案。