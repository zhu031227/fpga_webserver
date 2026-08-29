# MAC 白名单查找引擎实现指南 · 模式 1 —— BRAM 二分查找（从零实现）

> 文档编号：ED003R02-B
> 日期：2026-08-29
> 适用工程：`fpga_webserver-whitelist_dev`（whitelist_dev 分支）
> 平台：Xilinx XC7A35T-FGG484-2（ACX750 开发板）
> 性质：**从零实现指南（作业指导书）**。模式 1 当前在工程中**不存在任何实现**（`mac_whitelist_top.v` 里是 placeholder），本文即完整设计稿与实施步骤。
> **前置条件**：《MAC白名单查找引擎实现指南_模式0_顺序查找.md》（ED003R02-A）已全部完成并上板（tag `mode0-verified`）。框架机制（数据通路/配置通路/存储结构/寄存器表）在模式 0 文档第 1 章详述，本文第 2 章做自包含要点回顾，细节回引模式 0 编号（如"模式0-§1.2"）。
> 本文可直接交给 AI 模型或工程师逐步执行；执行前必读 0.4 节「执行须知」。

---

## 修订记录

| 日期 | 版本 | 修改描述 | 作者 |
|------|------|---------|------|
| 2026-08-28 | R01（ED003R01-B） | 初稿 | Claude |
| 2026-08-29 | R02（ED003R02-B） | 重排为作业指导书格式：统一步骤六段模板、全局连续步骤编号（模式1-步骤N.M）、融入 Wavedrom 时序图；**修正 FSM 两处缺陷**：①读地址驱动改为 `mid` 直驱（原 `rd_addr_r` 在 S_ISSUE 拍装载整体晚 1 拍，S_CMP 比到旧数据，与 10 拍时序表矛盾）；②二分下一跳计算的中间运算扩 1 位（原 4bit 加法 `lo+mid-1` 最大 28 会回绕，mid 可能落到搜索区间外） | Claude |

## 目录

- 第 0 章 文档定位与差异总览（0.1 目标与改动范围 / 0.2 差异总览 / 0.3 整机位置 / 0.4 执行须知）
- 第 1 章 设计决策与软硬件契约（1.1 排序放软件 / 1.2 INV 契约 / 1.3 二分时序展开 / 1.4 四个细节坑 / 1.5 空表与单条）
- 第 2 章 框架机制要点回顾（自包含：2.1 配置通路 / 2.2 寄存器表 / 2.3 C 驱动 / 2.4 构建链）
- 第 3 章 从零改造十步（步骤 1 契约 ~ 步骤 10 上板）
- 第 4 章 常见错误与排查速查
- 第 5 章 验收清单与里程碑
- 第 6 章 仿真分层、上板门禁（Gate）与已知问题
- 附录 A 选型对比 / B 文件索引 / C 时序图来源索引

---

## 第 0 章 文档定位与差异总览

### 0.1 目标与改动范围

在模式 0 的完整框架上，**只替换查找算法核心**，把查找周期从 18 拍降到 10 拍，并引入"软件维护有序表 + 硬件二分查找"的软硬协同结构。

**改动范围一览**（先明确边界，防止扩散）：

| 文件 | 改动 |
|------|------|
| `rtl/mac_whitelist_bin.v` | **新建**（从 seq 复制，替换查找 FSM） |
| `rtl/mac_whitelist_top.v` | 加 `LOOKUP_MODE==1` 分支（替换 placeholder 的一半） |
| `rtl/webserver_wrapper.v` | 顺手修复 `wl_status` 未驱动 + 模式号填 1 |
| `c/whitelist.c` | add/delete 改为**有序搬移式**（改动集中在这一个文件） |
| `c/inc/whitelist.h` | 不变（函数签名全保留） |
| `c/tcp.c` / `c/http.c` / `c/flash_cfg.c` / `html/*` | **零改动** |
| `build_xilinx.../filelist.cfg` | 加一行 `../rtl/mac_whitelist_bin.v` |

### 0.2 与模式 0 的差异总览

| 维度 | 模式 0 | 模式 1 |
|------|--------|--------|
| 查找算法 | 线性扫 16 条，18 拍 | 二分 ≤4 迭代，**10 拍**（命中可提前退出） |
| 表的有序性 | 无要求 | **valid 条目占 [0, used-1] 连续区间，MAC 严格升序**（软硬件契约） |
| index 语义 | 物理槽位（任意位置） | **有序排名**（index = 第几小） |
| 增删条目 | 找 free slot 直接写 | **软件搬移保持有序**（模式1-步骤8） |
| 配置通路/寄存器表/shadow_rf/CLEAR 序列器 | — | **完全复用，RTL 零改动** |
| C 驱动接口签名 | — | **完全复用**（tcp.c 等上层无感知） |

### 0.3 白名单位置（简版，详见模式 0 文档 0.3 节）

```
eth1 RX ─► 提取SrcMAC ─► lookup_req ─► [mac_whitelist_top MODE=1 二分查BRAM] ─► match ─► 门控wpkt_push ─► eth2 TX
                                            ▲ cfg口(SubBus 0x5000, 50MHz)
                                     C固件 whitelist.c（有序影子表 + 搬移式增删）
```

### 0.4 执行须知（作业指导书使用规则，执行前必读）

1. **步骤编号体系**：全部步骤按「模式1-步骤N.M」全局连续编号，可被其他文档直接引用（如"见 模式1-步骤8.5"）。
2. **每步固定六段结构**：目的 / 前置条件 / 操作步骤 / 产出物 / 完成判据 / 常见错误。**判据不过，不得进入下一步**。
3. **执行顺序强约束**：步骤 1→10 顺序执行。**C 驱动改造（步骤 8）刻意排在仿真（步骤 5~7）之后**——先用 tb 把 RTL 验透，再动软件；上板（步骤 9）才需要改完的 C 固件。
4. **门禁规则**：第 6.2 节定义 G1~G5。**G1~G3 全绿之前，禁止执行 `build_fpga.sh`**。
5. **与模式 0 文档的关系**：本文是姐妹篇下半篇。复制起点、tb 模板、公共已知问题均指向模式 0 的具体步骤编号；模式 0 的 8 条公共已知问题（其 5.3 节）在本文 6.3 节只列索引，**执行前必须先读一遍**。
6. **图表规范**：时序图用 Wavedrom，结构图保留 ASCII/Mermaid；来源见附录 C。

---

## 第 1 章 设计决策与软硬件契约（动笔前必须吃透）

### 1.1 核心决策：排序维护放软件（已拍板）

二分查找要求表有序。**增删时的排序维护放在 C 固件，不放在 RTL**：

**理由**：
1. 增删是**低频配置操作**（人在网页上点，秒级间隔），逐包查找才是热路径——把复杂度从热路径挪到冷路径是软硬划分的第一原则；
2. 硬件自动搬移需要跨时钟域的读-改-写多周期序列状态机（最多搬 15 条 × 50MHz），RTL 复杂度和调试成本翻几倍，还引入新的正确性风险；
3. C 侧已有影子表 `sw_wl_mac[16][6]`，"保持有序"只是数组插入/删除 + 重写 HW，约 40 行代码；
4. 现有寄存器接口（INDEX/MAC_H/MAC_L/WR/DEL）**零改动**就够用。

**代价**：加/删一条最坏重写 16 条 × 每条 4 笔 SubBus 写（每笔约 1µs，含 flush）≈ 70µs——人手操作完全无感。

### 1.2 软件契约（模式 1 正确性的根基，必须写进 RTL 和 C 的注释）

```text
不变式 INV1：有效条目占据 index ∈ [0, used_cnt-1] 的连续区间，其后全部 invalid(49'b0)。
不变式 INV2：∀ i < j ≤ used_cnt-1：mac[i] < mac[j]（48bit 无符号严格升序，无重复）。
不变式 INV3：任意时刻 HW 表都满足 INV1+INV2 —— 包括 C 搬移的每笔写之间（模式1-步骤8.5 保序设计）。
```

**谁维护谁消费**：
- C 固件是唯一写入方，通过搬移式增删维护 INV1/INV2，通过保序覆盖顺序保证 INV3；
- RTL 查找 FSM **信任**这两条不变式（不做校验），这是简化二分逻辑的前提。

### 1.3 二分查找的硬件时序展开（与软件版的本质区别）

软件二分一次循环 = 一次数组访问（即时）。硬件里 BRAM 读有 **1 拍延迟**，且**下一跳 mid 依赖上一跳比较结果，无法流水**——每次迭代固定 2 拍：

```text
软件:                              硬件（125MHz，每拍 8ns）:
  lo=0, hi=used-1                    拍 0  IDLE→ISSUE   发地址 mid0=(0+used-1)/2
  while (lo<=hi):                    拍 1  CMP0         数据0有效：比较+算出mid1
      mid=(lo+hi)/2                  拍 2  ISSUE        发地址 mid1
      if mac[mid]==t: hit            拍 3  CMP1         比较+算出mid2
      elif mac[mid]<t: lo=mid+1      拍 4  ISSUE        ...
      else:            hi=mid-1      拍 5  CMP2         ...
                                     拍 6  ISSUE        （log2(16)=4 迭代）
                                     拍 7  CMP3         最后一次比较
                                     拍 8  DONE         锁存 match，拉 done 1拍
                                     —— req→done = 10 拍（模式 0 为 18 拍）
命中可提前退出：任一 CMP 命中直接转 DONE → 命中平均 ~8 拍
```

波形对照（图 1，miss 全程 4 迭代的情形）：

```wavedrom
{ "signal": [
    { "name": "clk(125M)",  "wave": "10P........" },
    { "name": "lookup_req", "wave": "10........." },
    { "name": "bram_rd_addr(=mid)", "wave": "x00112233xx",
      "data": [ "mid0","mid1","mid2","mid3" ] },
    { "name": "q_b(读数据)", "wave": "xx00112233x",
      "data": [ "d(m0)","d(m1)","d(m2)","d(m3)" ] },
    { "name": "匹配比较(CMP拍)", "wave": "00101010100" },
    { "name": "lookup_done", "wave": "00000000010" }
], "head": { "text": "模式 1 二分查找：req→done ≤10 拍（miss 全程 4 迭代；命中提前退出更短）" },
   "foot": { "text": "地址在 ISSUE 拍由 mid 直驱上端口 → 下一拍(CMP)数据有效；每迭代固定 2 拍；空表 2 拍即 done" } }
```
> **图 1** 二分查找 FSM 逐拍时序（自设计）。IDLE(c0)→ISSUE(c1)→CMP(c2)→ISSUE(c3)→CMP(c4)→ISSUE(c5)→CMP(c6)→ISSUE(c7)→CMP(c8)→DONE(c9)，req 在 c0、done 在 c9 → 10 拍。

**为什么不能流水**：发 mid1 之前必须知道 mac[mid0] 与目标的大小关系——数据依赖链强制串行。要更快只能上 MODE 2 哈希（2~3 拍），那是另一个项目。

**读地址驱动的推论**（实现要点，模式1-步骤3.3 落实）：BRAM 同步读是"地址第 N 拍上端口 → 数据第 N+1 拍有效"。要让 CMP 拍恰好见数据，地址必须在 ISSUE 拍就出现在端口上——所以读地址必须由 `mid` 寄存器**直驱**（mid 在上一状态末沿锁定，ISSUE 拍已稳定）。**不要**在 mid 和 BRAM 端口之间再插一级 `rd_addr_r` 寄存器：那会让地址整体晚 1 拍上端口，CMP 拍比到的是上一跳的旧数据，且仿真可能侥幸通过（首跳前 q_b 恰为 0 时误打误撞），周期数断言与随机对拍是兜底。

### 1.4 四个硬件特有的关键细节（最容易踩坑处，逐条记住）

| # | 细节 | 错误做法的后果 | 正确做法 |
|---|------|--------------|---------|
| 1 | **hi 初值用 `used_cnt-1`，不是 `ENTRY_NUM-1`** | 若用 15：mid 越过 used-1 后读到 invalid 条目（49'b0，mac=0）。mac=0 比任何真实 MAC 都小 → 二分被误导**向右**走 → 永不收敛到正确结果，miss 的包查成"向右越界"，**hit 的包也可能漏判** | 复用模式 0 已有的 `used_cnt_comb`（popcount 链），INV1 保证它精确等于有效条数 |
| 2 | **invalid 强制向左（双保险）** | 同上 | `S_CMP` 里：`!bram_rd_valid` 时按"mac[mid] > target"分支处理（hi=mid-1）。双保险，即使 used_cnt 短暂不准也不死循环 |
| 3 | **全零 MAC 禁止入表** | mac=0 无法与 invalid 区分，破坏细节 1/2 的推断 | C 侧 `whitelist_add` 开头校验：6 字节全 0 拒绝（单播 MAC 永不为全零，无功能损失） |
| 4 | **48bit 比较必须无符号** | 若信号被声明成 signed，mac[47]=1 的 MAC（如 80:00... 开头的组播位）比较方向全错 | Verilog 的 reg/wire 默认无符号；**不要**在任何比较路径上加 signed 声明；tb 里用 `2**48` 以上随机值覆盖高位 |

### 1.5 空表与单条表

- `used_cnt==0`：IDLE 收到 req 直接转 DONE，match=0（连 ISSUE 都不发，req→done 仅 2 拍）——tb 必须覆盖；
- `used_cnt==1`：区间 [0,0]，一次迭代收敛——tb 必须覆盖。

---

## 第 2 章 框架机制要点回顾（自包含）

> 本章把模式 0 文档第 1 章压缩为执行本文所需的最小集合。三特性、寄存器表**逐字有效**；更多细节（数据通路四步、存储结构图、已知问题 8 条全文）见模式 0 文档对应章节。

### 2.1 配置通路三特性（模式0-§1.2）

C 固件经 LCPU 总线 → `reg_webserver`（SubBus 0x5000~0x5FFF 段译码）→ `ramintf` → 白名单 cfg 口（50MHz 域）。上游 LCPU 写时序与白名单 cfg 口电平采样波形见模式 0 文档图 1/图 2；cfg 口上看到的核心事实（图 2）：

```wavedrom
{ "signal": [
    { "name": "cfg_clk",        "wave": "10P......" },
    { "name": "cfg_rlwh",       "wave": "01...0.." },
    { "name": "cfg_addr[11:0]", "wave": "x.3...x.", "data": [ "0x003(WR)" ] },
    {},
    { "name": "bram_wr_en_r（译码加载）", "wave": "001110..." },
    { "name": "BRAM+shadow 实际写口",     "wave": "001110..." }
], "head": { "text": "cfg 口电平敏感写：rlwh 持续约 3 拍，同一笔写被译码 3 次" },
   "foot": { "text": "写内容恒定 → 重复执行无害（幂等）。禁止边沿检测/计数式逻辑" } }
```
> **图 2** 白名单 cfg 口电平敏感写采样。与模式 0 文档图 2 同源（自设计）。

| # | 特性 | 对 RTL/C 的要求 |
|---|------|----------------|
| 1 | 电平敏感写、无握手（rlwh 持续约 3 拍） | RTL 所有写动作幂等（`*_r` 单拍脉冲结构）；C 每笔写走 `subbus_write()` |
| 2 | C 侧每笔写后必须 flush（读 0x500A） | `subbus_write()` 内已实现；模式 1 搬移的每一笔都必须过它（6.3 问题 10） |
| 3 | BRAM 与 shadow_rf 双副本同步写 | 每条写路径同拍写两存储——模式 1 完全复用，RTL 零改动 |

### 2.2 寄存器表（同模式 0 §1.5，SubBus 基址 0x5000）

| 偏移 | 名称 | 类型 | 写入行为 / 读出内容 | 模式 1 下语义 |
|-----|------|------|---------------------|--------------|
| 0x00 | INDEX | RW | 写：加载 cfg_idx；wdata[31]=1 附带删除该索引条目 | **index=有序排名**（第几小） |
| 0x01 | MAC_H | RW | 写/读 cfg_mac[47:16] | 不变 |
| 0x02 | MAC_L | RW | 写/读 cfg_mac[15:0] | 不变 |
| 0x03 | WR | WC | {1'b1, cfg_mac} 双副本写入 cfg_idx 槽 | 写入后表仍须有序（C 负责顺序） |
| 0x04 | DEL | WC | 49'b0 双副本清零 cfg_idx 槽 | 不变 |
| 0x05 | CLEAR | WC | 启动 16 拍清除序列器 | 不变 |
| 0x06/07/08 | RD_MAC_H/L、RD_VALID | RO | 读 shadow_rf[cfg_idx] | 不变 |
| 0x09 | FREE_IDX | RO | 首个空闲索引（全满=0xF） | 模式 1 有序表下 C 侧不使用（位置由排名决定） |
| 0x0A | MAX_ENTRIES | RO | 恒 16（**flush 固定读这个地址**） | 不变 |
| 0x0B | USED_CNT | RO | 有效条目数（popcount） | **二分 hi 初值的来源**（1.4 细节 1） |

RTL 侧寄存器逻辑从 seq **原样保留**，本文零改动。

### 2.3 C 驱动现状（`c/whitelist.c`，346 行）

| 函数 | 职责 | 模式 1 改动 |
|------|------|------------|
| `subbus_write(base, off, data)` | 写 + 读 0x500A flush | 不变（**所有 HW 写必须走它**） |
| `sw_wl_*` 影子表 | Web 显示/Flash 持久化权威数据源 | 改为**始终有序**维护 |
| `whitelist_add / delete` | 影子表 + HW 双写 | **替换主体**为有序搬移式（模式1-步骤8） |
| `whitelist_clear_all` | 影子表 + CLEAR 序列器 | 不变 |
| `whitelist_hw_read_entry(i)` | 经 0x06/07/08 读 HW | 不变（读的顺序自动变成升序） |
| `whitelist_apply_snapshot` | Flash 恢复灌入 | 改为**排序灌入**（模式1-步骤8.6） |
| `whitelist_get / hw_diag` | 快照保存 / 诊断 | 不变 |

### 2.4 构建与烧录链（同模式 0 §1.7）

```bash
cd /home/haitaoz/work/FPGA_Prj/fpga_webserver-wldev-v2
cd c_build && make PLATFORM=xilinx riscv_reset_addr=0xf TCL_BASE=0x8000 && cd ..   # 固件
cd build_xilinx_xc7a35tfgg484 && ./build_fpga.sh <4位hex版本> && cd ..             # bitstream
openFPGALoader -c digilent_hs2 <工程目录>/<同名>.bit                                # 烧录
vivado -mode batch -source scripts/load_firmware_vivado.tcl                        # 加载固件
ping 192.168.1.88 && curl http://192.168.1.88/                                     # 验证（应 200）
```

模式 1 的特殊性：**同一份 C 固件两模式通用**（有序表在模式 0 下也只是"恰好有序"的普通表）——切模式只需重出 bitstream，固件不必重编；反之 C 改造完成后在模式 0 上验证也不需要特殊处理。

---

## 第 3 章 从零改造十步

> 步骤依赖链：**1 契约 → 2 复制骨架 → 3 二分FSM → 4 集成改动 → 5 参数化tb → 6 L1仿真+回归 → 7 L2集成仿真 → 8 C有序化 → 9 上板回归 → 10 并发/掉电/收尾**。每步六段：目的/前置条件/操作步骤/产出物/完成判据/常见错误。判据不过不进下一步。

### 步骤 1：契约确认与规格落笔

**目的**：把 1.2 节的三条不变式和 1.3 节的时序结论固化成文档与代码注释——它们是 RTL"信任不校验"的依据，也是 C 侧实现正确性的验收标准，先立契约后写码。

**前置条件**：模式 0 已收官（tag `mode0-verified`）；已通读本文第 1 章。

**操作步骤**：

**1.1** 通读 1.1~1.5，确认理解：排序在软件（1.1）、INV1~3（1.2）、每迭代 2 拍共 ≤10 拍（1.3）、四个细节坑（1.4）、空表/单条特例（1.5）。

**1.2** 时序预算验算（写入将新建模块的头注释）：miss 全程 4 迭代 × 2 拍 + IDLE/DONE 各 1 拍 = 10 拍 = 80ns ≪ 672ns 最小帧间隔，线速安全；命中提前退出 4~10 拍。

**1.3** 在工作记录里抄录 INV1~3 原文——步骤 2.2 要把它们写进 RTL 头注释，步骤 8 要写进 C 函数注释。

**产出物**：契约要点记录（INV 原文 + 时序预算）。

**完成判据**：能不看文档复述：hi 初值是什么、invalid 比较方向、为什么全零 MAC 禁入、每迭代几拍。

**常见错误**：跳过本章直接开始复制代码——四个细节坑（1.4）每一个都对应第 4 章排查表里一类真实故障。

### 步骤 2：复制与骨架改造

**目的**：以 seq 为起点建立 `mac_whitelist_bin.v`——配置通路、存储、辅助逻辑**一行不改**地继承（已由模式 0 验证），把改动面收窄到查找 FSM 与读地址驱动两处。

**前置条件**：模式1-步骤1 完成。

**操作步骤**：

**2.1** 复制文件：

```bash
cd /home/haitaoz/work/FPGA_Prj/fpga_webserver-wldev-v2
cp rtl/mac_whitelist_seq.v rtl/mac_whitelist_bin.v
```

**2.2** 改模块名与头注释：`module mac_whitelist_seq` → `module mac_whitelist_bin`；头部注释**必须**写上 INV1/INV2/INV3 契约原文、"信任契约、不做校验"声明、时序预算（≤10 拍）。

**2.3** 清点保留区（以下内容**一行不改**）：

| 保留（一行不改） | 参考答案位置（seq.v） |
|------------------|----------------------|
| 端口声明（仅模块名不同） | 11~35 行 |
| 配置译码 always 块 | 144~216 行 |
| shadow_rf / CLEAR 序列器 | 60~142、144~216 行内相关段 |
| free_idx / popcount / 读 mux | 217~244 行 |
| 寄存器表语义 | 全部（C 侧语义变化见第 2.2 节，RTL 本身不变） |

**2.4** 标记替换区（步骤 3 处理）：查找 FSM（281~314 行）、`bram_rd_addr` 驱动（256 行）。

**产出物**：`rtl/mac_whitelist_bin.v`（除模块名外与 seq 等价，编译干净）。

**完成判据**：`iverilog -g2012 -o /dev/null sim/define_sim.sv rtl/mac_whitelist_bin.v ../ip_common/rtl/dual_clock_simple_dual_port_ram.v` 0 error（define_sim.sv 沿用模式0-步骤3.5 创建的文件）；grep 确认模块名已改且全文唯一。

**常见错误**：复制后忘改模块名 → 与 seq 重名，top 例化报错；手痒"顺手优化"保留区 → 把模式 0 已验证的逻辑改出回归问题（共享代码回归靠模式1-步骤6.3 兜底，但别主动制造）。

### 步骤 3：二分查找 FSM 实现（模式 1 核心）

**目的**：用四态 FSM（IDLE→ISSUE→CMP→DONE）替换顺序扫描。每迭代 2 拍（ISSUE 拍地址上 BRAM 端口、CMP 拍数据有效并算下一跳），命中提前退出，miss 全程 ≤10 拍。同时把读地址驱动改为 `mid` 直驱（1.3 推论）。

**前置条件**：模式1-步骤2 完成。

**操作步骤**：

**3.1** 声明二分状态变量（加在 FSM 信号区）：

```verilog
reg [ADDR_WIDTH-1:0] lo, hi, mid;
reg                  hit;
```

**3.2** 读地址驱动替换——删掉 seq 的扫地址式驱动（原 256 行），改为 **mid 直驱**：

```verilog
// ★ 与 seq 的差异：seq 是 (state==S_COMPARE)?cmp_index:0 的"扫地址"式；
//   二分地址跳变由比较结果决定 → 由 mid 寄存器直驱。
//   ★ 不要在此再加 rd_addr_r 一级寄存器：地址会整体晚 1 拍上端口，
//     S_CMP 比到上一跳旧数据（见 1.3 读地址驱动的推论）。
assign bram_rd_addr = mid;
```

**3.3** FSM 本体替换（替换 seq 原 281~314 行）：

```verilog
// ============================================================
// Binary search FSM (125MHz) — 信任 INV1/INV2 契约
//   IDLE → ISSUE(地址上端口) → CMP(比较+算下一跳) → ... → DONE
//   每迭代 2 拍；命中提前退出；≤4 迭代；req→done ≤10 拍
// ============================================================
localparam S_IDLE=2'd0, S_ISSUE=2'd1, S_CMP=2'd2, S_DONE=2'd3;

always @(posedge clk or negedge reset_l) begin
    if (!reset_l) begin
        state<=S_IDLE; lo<=0; hi<=0; mid<=0; hit<=0;
        lookup_match<=0; lookup_done<=0;
    end else begin
        lookup_done <= 1'b0;
        case (state)
        S_IDLE:
            if (lookup_req) begin
                hit <= 1'b0;
                if (used_cnt_comb == 0) begin          // 空表直接 miss（1.5 节）
                    state <= S_DONE;
                end else begin
                    lo  <= {ADDR_WIDTH{1'b0}};
                    hi  <= used_cnt_comb[ADDR_WIDTH-1:0] - 1'b1;   // ★ 细节1：used-1
                    mid <= (used_cnt_comb[ADDR_WIDTH-1:0] - 1'b1) >> 1;
                    state <= S_ISSUE;
                end
            end
        S_ISSUE: begin
            // mid 上一沿已锁定，本拍地址已在 BRAM 端口上；只等下一拍数据
            state <= S_CMP;
        end
        S_CMP: begin
            if (bram_rd_valid && (bram_rd_mac == lookup_mac)) begin
                hit   <= 1'b1;                         // ★ 命中提前退出
                state <= S_DONE;
            end else if (!bram_rd_valid || (bram_rd_mac > lookup_mac)) begin
                // ★ 细节2：invalid 当作"偏大"强制向左
                if (mid == 0) state <= S_DONE;         // 向左越界 → miss
                else begin
                    hi  <= mid - 1'b1;
                    mid <= ({1'b0, lo} + {1'b0, mid} - 1'b1) >> 1;
                    state <= S_ISSUE;
                end
            end else begin                             // mac[mid] < target → 向右
                if (mid == hi) state <= S_DONE;        // 向右越界 → miss
                else begin
                    lo  <= mid + 1'b1;
                    mid <= ({1'b0, mid} + 1'b1 + {1'b0, hi}) >> 1;
                    state <= S_ISSUE;
                end
            end
        end
        S_DONE: begin
            lookup_match <= whitelist_en ? hit : default_pass;   // 兜底语义同模式 0
            lookup_done  <= 1'b1;
            state        <= S_IDLE;
        end
        default: state <= S_IDLE;
        endcase
    end
end
assign lookup_busy = (state != S_IDLE);
```

（`bram_rd_valid`/`bram_rd_mac` 即 BRAM `q_b` 的 valid 判断与 [47:0] 切片，与 seq 同一接线惯例。）

**3.4** 位宽安全说明（写进代码注释）：向左/向右分支的下一跳计算中，中间和最大 `lo+mid-1 = 14+15` 可达 28，**超出 4bit 范围会回绕出错误 mid**（例如区间 [8,15] 会算出 mid=1，落到区间外）。所以用 `{1'b0, x}` 扩到 5bit 再加减移位——3.3 代码里两处 `>> 1` 前的拼接扩位不可省。

**3.5** 逐拍自查——对照图 1（1.3 节）逐拍走查：IDLE(c0) 收 req 锁 lo/hi/mid → ISSUE(c1) mid0 上端口 → CMP(c2) d(m0) 有效、比较、算 mid1 → … → CMP(c8) 最后一跳 → DONE(c9) 锁存+done。

**3.6** 收敛性心算（照原文走一遍，写进注释）：used=16, hi=15, mid0=7 → 偏大 hi=6, mid1=3 → 偏小 lo=4, mid2=5 → 偏大 hi=4, mid3=4 → 最后一跳恰 mid==lo==hi，一次定输赢。4 次迭代覆盖 16 条 ✓。

**产出物**：`rtl/mac_whitelist_bin.v` 的二分 FSM（本步完成后 RTL 改动全部结束）。

**完成判据**：模块编译 0 error；对照图 1 能逐拍指出你的代码在每个状态做什么；3.6 心算能复述。

**常见错误**：`hi` 初值用 `ENTRY_NUM-1`（1.4 细节 1）→ 表半满时全错；`rd_addr_r` 又加回来了 → CMP 比旧数据、对拍必炸；下一跳计算忘扩位 → 大下标区间二分跑飞（3.4）；S_CMP 漏 `!bram_rd_valid` 向左分支 → used_cnt 短暂不准时死循环；比较信号 signed 化 → 高位 MAC 方向反（1.4 细节 4）。

### 步骤 4：集成改动（wl_status 修复、top 分支、filelist）

**目的**：完成三处外围集成改动，使 MODE=1 可被编译、可被验收。其中 `wl_status` 是现存工程缺口（公共已知问题 2）在本模式的必修项——读不出 1 就无法验收 G5 第 1 项。

**前置条件**：模式1-步骤3 完成。

**操作步骤**：

**4.1** `wl_status` 未驱动修复——现状：`webserver_wrapper.v` 168 行声明 `wl_status`（[7:0]=lookup_mode，[15:8]=used_cnt），480 行连进 reg_webserver（0x301，Web `/api/wl/status` 的 lookup_mode 字段），但**全工程没有一处 assign 驱动它**，读回恒 0。二选一：

```verilog
// 方案 a（最小改动）：wrapper 里直接 assign 常量模式号
assign wl_status = {8'b0, 8'd1};            // LOOKUP_MODE=1

// 方案 b（完整，推荐）：给 mac_whitelist_top 加输出口
//   top:  output [7:0] used_cnt_o   →  assign used_cnt_o = used_cnt_comb;
//   bin/seq 各加同名输出口透传
//   wrapper:  assign wl_status = {u_mac_wl_used, 8'd1};
//   → Web 状态栏同时显示 模式号 + 实时条目数（tcp.c 的 status 接口已在读 wl_status）
```

选 b 则 seq/bin/top 三处各加一个 8bit 输出口；选 a 只动 wrapper 一行。**注意**：方案 a 在 MODE=0 的 bit 里会误报 1——本工程模式切换靠重编 bit，报当前 bit 的模式号即正确语义。

**4.2** `rtl/mac_whitelist_top.v` 的 generate 改三段（38~67 行；原 60~66 行 placeholder 收窄为 MODE=2 留位）：

```verilog
generate
    if (LOOKUP_MODE == 0) begin : g_mode_seq
        mac_whitelist_seq #(...) u_lookup (...);   // 原样
    end else if (LOOKUP_MODE == 1) begin : g_mode_bin
        mac_whitelist_bin  #(...) u_lookup (...);  // 新增：连线照抄 mode0 分支
    end else begin : g_mode_placeholder            // MODE=2 留位
        ...
    end
endgenerate
```

**4.3** `build_xilinx_xc7a35tfgg484/filelist.cfg` 加一行：`../rtl/mac_whitelist_bin.v`。

**4.4** `webserver_wrapper.v` 模式号**本步不改**（保持 1139 行 `.LOOKUP_MODE(0)`）——模式切换在步骤 9 上板时进行，此期间一切仿真验证均不需要动它。

**产出物**：改动后的 `mac_whitelist_top.v`、`webserver_wrapper.v`、`filelist.cfg`。

**完成判据**：top 级 `iverilog -g2012 -o /dev/null` 语法自查无新增 error（两个模式分支都会被 elaboration 检查到，seq/bin 必须都能编译）；grep `wl_status` 能找到驱动源。

**常见错误**：mode1 分支连线漏抄某根（对照 4.2 的 mode0 分支逐根抄）；filelist 忘加 bin.v → 上板 build 时才报 undefined module（白等半小时构建）；方案 b 忘给 seq 加透传口 → MODE=0 编译失败。

### 步骤 5：参数化单元 tb 搭建

**目的**：建一套用例代码跑两种模式的回归框架——`MODE=0` 例化 seq、`MODE=1` 例化 bin。它同时服务本模式验证（G2）与共用代码回归（G2b），一劳永逸。

**前置条件**：模式1-步骤4 完成；模式 0 的 `sim/tb_mac_whitelist_seq.sv` 存在（作为模板）。

**操作步骤**：

**5.1** 新建 `sim/tb_mac_whitelist_bin.sv`：以模式 0 的 L1 tb 为模板（时钟生成、SubBus 写任务照抄，见模式0-步骤7.1/7.2），顶层加 `parameter MODE = 1`，DUT 例化处按 MODE 选择 seq/bin。

**5.2** 在 tb 内用 SV 队列维护**金模型**（软件视角的有序表，参考实现）：

```systemverilog
// tb 内软件金模型（有序数组）
int unsigned model[$];
function automatic bit model_lookup(int unsigned mac);
    int lo=0, hi=model.size()-1;
    while (lo<=hi) begin
        int mid=(lo+hi)/2;
        if (model[mid]==mac) return 1;
        else if (model[mid]<mac) lo=mid+1; else hi=mid-1;
    end
    return 0;
endfunction
// 随机激励循环：8% add / 8% del / 84% lookup；add/del 后同步 model 与 DUT；
// 每次 lookup：DUT match（done 拍采样）异或 model_lookup → mismatch 计数
```

**5.3** 周期数断言参数化：模式 0 tb 里 `==18` 的断言点改为 `parameter` 驱动——MODE=0 断言 `==18`，MODE=1 断言 `<=10`（两模式的分水岭断言）。

**产出物**：`sim/tb_mac_whitelist_bin.sv`（双模式可跑）。

**完成判据**：`MODE=0` 编译运行通过（此时用例尚未写全，跑通框架即可）。

**常见错误**：金模型忘了与 DUT 增删同步 → 对拍 0 mismatch 是假象（先人为注入一次不同步验证对拍能报错）；随机 MAC 范围低于 2^48 → 覆盖不到高位比较路径（1.4 细节 4）。

### 步骤 6：L1 仿真——MODE=1 全用例 + MODE=0 回归

**目的**：14 用例验证二分全路径 + 500 次随机对拍验证统计正确性；再以 MODE=0 重跑证明共用代码没被改坏。这是 Gate G2 + G2b。

**前置条件**：模式1-步骤5 完成。

**操作步骤**：

**6.1** 实现用例矩阵（14 条）：

| # | 用例 | 期望 | 备注 |
|---|------|------|------|
| 1~6 | 复用模式 0 用例 1~6（增删查清/表满/en+defpass） | 同模式 0 | 配置通路共用的回归 |
| 7 | 周期数断言 | **≤10**（模式 0 为 ==18） | 两模式的分水岭断言 |
| 8 | busy 期间 req 被忽略 | 同模式 0 | — |
| 9 | 有序灌 8 条随机 MAC → 查 8 命中 + 8 miss | 全部正确 | — |
| 10 | 边界值：查最小条目 / 最大条目 / 中位 | 命中 | 二分路径全覆盖 |
| 11 | **金模型随机对拍**：500 次随机 add/del/lookup，每次 lookup 后比对 RTL match 与软件模型判断 | 0 mismatch | 本模式核心校验 |
| 12 | 空表 lookup | done=1、match=0、周期最短（2 拍） | 1.5 节 |
| 13 | used=1 单条表查命中/miss | 正确收敛 | 1.5 节 |
| 14 | 乱序注入防御 | C 契约测试（软件层） | 若有 C 单测环境则跑，否则靠对拍覆盖 |

**6.2** 跑 MODE=1（全部 14 条）：

```bash
cd /home/haitaoz/work/FPGA_Prj/fpga_webserver-wldev-v2
iverilog -g2012 -o tb_bin.vvp -Ptb_mac_whitelist_bin.MODE=1 \
    sim/define_sim.sv \
    sim/tb_mac_whitelist_bin.sv \
    rtl/mac_whitelist_bin.v \
    ../ip_common/rtl/dual_clock_simple_dual_port_ram.v
vvp tb_bin.vvp
```

**6.3** 跑 MODE=0 回归（用例 1~8）：

```bash
iverilog -g2012 -o tb_reg.vvp -Ptb_mac_whitelist_bin.MODE=0 \
    sim/define_sim.sv \
    sim/tb_mac_whitelist_bin.sv \
    rtl/mac_whitelist_seq.v \
    ../ip_common/rtl/dual_clock_simple_dual_port_ram.v
vvp tb_reg.vvp
```

**产出物**：两份全 PASS 的仿真记录（含对拍 mismatch 计数 = 0）。

**完成判据**：MODE=1 14 用例全过 + 500 次对拍 0 mismatch（G2）；MODE=0 用例 1~8 全过（G2b）。失败时按第 4 章排查表定位——对拍 mismatch 的具体次序号 + 当时表状态可直接回放定位。

**常见错误**：对拍只在命中上比对不比 miss → hi 初值错这类"多查不漏"型 bug 漏网（miss 样本要占一半）；用例 12/13 跳过 → 1.5 节两个特例恰是边界 bug 高发区。

### 步骤 7：L2 集成仿真——bin × cpu_channel_tri

**目的**：沿用模式 0 的集成 tb（`sim/tb_wl_integration.sv`，见模式0-步骤8）验证"提取 SrcMAC→触发→门控"整条链路在二分引擎下依旧成立，并验证 INV3 在集成级成立——这是"搬移期间不关过滤"设计的最终证据。这是 Gate G3。

**前置条件**：模式1-步骤6 全过（G2/G2b）；模式 0 的 `sim/tb_wl_integration.sv` 存在。

**操作步骤**：

**7.1** 参数化：tb 的 MODE parameter 改成可传（`MODE=1` 时例化 `mac_whitelist_bin`）。

**7.2** 命令行替换：iverilog 文件清单里 `rtl/mac_whitelist_seq.v` → `rtl/mac_whitelist_bin.v`（其余 7 个 `../ip_common/rtl/` 文件不变，完整清单见模式0-步骤8.3）。

**7.3** 回归双跑：
- `MODE=0` + seq：6 用例过（证明共用代码没被本次改动弄坏）；
- `MODE=1` + bin：6 用例过 + **周期数断言改为 ≤10**（tb 里原 ==18 的断言点参数化，同模式1-步骤5.3）。

**7.4** 模式 1 特有加测一条：

| # | 用例 | 期望 |
|---|------|------|
| 7 | tb 直接驱动 DUT1（bin）做**有序表随机对拍**（复用 5.2 金模型），同时 cpu_channel_tri 侧持续喂帧 | 增删的每一笔写之间查找结果都符合金模型（INV3 在集成级验证） |

**产出物**：双模式 L2 全 PASS 的仿真记录。

**完成判据**：双模式各 6 用例 + 特有用例 7 全过 → G3 绿。**G1~G3 全绿后才允许步骤 9 上板。**

**常见错误**：只跑 MODE=1 不跑 MODE=0 回归 → 共用改动（若有）带病上板；特有用例 7 里对拍与喂帧用同一时钟进程 → 阻塞成串行、验证不到并发（两进程独立驱动）。

### 步骤 8：C 驱动有序化改造（`c/whitelist.c`）

**目的**：让 C 固件维护 INV1~3——add/delete 改为有序搬移式，apply_snapshot 改为排序灌入。函数签名不变 → tcp.c/http.c/flash_cfg.c 零改动。**刻意排在仿真之后**：RTL 已验透，软件改造不阻塞仿真发现的问题。

**前置条件**：模式1-步骤7 全过（G3）；1.2 节 INV 契约已确认。

**操作步骤**：

**8.1** 新增 2 个 static 工具函数：

```c
// 把影子表第 i 条写入 HW（4 笔 SubBus 写，每笔内含 flush）
static void wl_hw_write_entry(int i, const uint8_t mac[6]) {
    uint32 mac_h = ((uint32)mac[0]<<24)|((uint32)mac[1]<<16)|((uint32)mac[2]<<8)|mac[3];
    uint32 mac_l = ((uint32)mac[4]<<8)|mac[5];
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, (uint32)i);
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_MAC_H, mac_h);
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_MAC_L, mac_l);
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_WR, 1);
}

// HW 删除第 i 条（一笔 INDEX|bit31 带删，比 INDEX+DEL 两笔少一次事务）
static void wl_hw_delete_entry(int i) {
    subbus_write(WL_SUBBUS_ADDR, WL_REG_ENTRY_INDEX, 0x80000000u | (uint32)i);
}
```

**8.2** 有序插入（替换 `whitelist_add` 主体）：

```c
int whitelist_add(uint8_t mac[6]) {
    // 0. 全零 MAC 拒绝（1.4 细节 3：保护二分的 invalid 推断）
    // 1. 查重：影子表线性扫 16 条，已存在 → 直接返回其 index（幂等语义）
    // 2. 表满 sw_wl_count==16 → -1
    // 3. 找插入位 pos：第一个 mac[pos] > 新 MAC 的下标（线性扫即可，16 条无需二分）
    // 4. 影子表 memmove 上移：sw_wl_mac[pos+1..count-1] ← [pos..count-2]（含 valid 标记）
    // 5. ★ HW 保序搬移【从高往低】：
    //      for (i = count-1; i > pos; i--)
    //          wl_hw_write_entry(i, sw_wl_mac[i]);   // 写的是搬移后的影子值
    // 6. wl_hw_write_entry(pos, mac)；影子表落位、sw_wl_valid[pos]=1、sw_wl_count++
    // 7. return pos
}
```

**8.3** 有序删除（替换 `whitelist_delete` 主体）：

```c
int whitelist_delete(uint8_t index) {
    // 1. index >= sw_wl_count 或该条无效 → -1
    // 2. ★ HW 保序搬移【从低往高】覆盖 + 清尾：
    //      for (i = index; i < sw_wl_count-1; i++)
    //          wl_hw_write_entry(i, sw_wl_mac[i+1]);   // 后一个前移覆盖
    //      wl_hw_delete_entry(sw_wl_count-1);          // 最后一条清零
    // 3. 影子表 memmove 下移 + sw_wl_count--
    // 4. return 0
}
```

**8.4** 保序方向论证（写进两个函数的注释，INV3 的核心）：搬移的本质是整块平移一格。插入**从高往低**覆盖时，任意两笔写之间 HW 表是"新表尾段 ∪ 旧表前段"，每个 index 处的值仍随 index 单调不减——只会出现**瞬时重复**（同一 MAC 同时在 i 和 i-1），重复不影响二分命中判断。**反过来从低往高写，中间态会出现"前一条比后一条大"的真乱序点**，此时恰落在乱序区间的包会被错误 miss。删除**从低往高**覆盖 = 整体左移一格，同理保序。

**8.5** 取舍声明（写进注释）：按上述顺序，搬移期间**无需临时关闭白名单**（wl_ctrl[0] 不用动），打流完全无感。若实现选了无序覆盖，就必须"搬移前置 en=0、完成恢复"——功能也正确，但过滤会瞬断几百 µs。两种都算对，**注释里写清你选的哪种、为什么**。

**8.6** 快照恢复改造（`whitelist_apply_snapshot`）：Flash 格式（`flash_cfg.h` 的 42 word 布局）**零改动**；读回后先在影子数组内**插入排序**，再按 index 0..n-1 逐条 `wl_hw_write_entry` 灌入——即使 Flash 内容被外部改乱也能恢复出合法有序表。`whitelist_clear_all` 不变。

**8.7** 回读一致性确认：`/api/wl/list`（tcp.c 731 行起）逐条 `whitelist_hw_read_entry(i)` 读的是 shadow_rf——搬移时影子表与 shadow_rf 同步更新，页面显示自动与 HW 一致。**预期行为变化**：列表从"添加顺序"变为"MAC 升序"（index=排名），网页无需改动。

**8.8** 重编固件：

```bash
cd c_build && make PLATFORM=xilinx riscv_reset_addr=0xf TCL_BASE=0x8000
```

**产出物**：有序化改造后的 `c/whitelist.c` + 新固件。

**完成判据**：编译 0 warning；代码走查逐条对照 8.2/8.3 的 7 步/4 步序号无遗漏；注释含 INV 契约与 8.4/8.5 论证。板级效果在步骤 9/10 验收。

**常见错误**：搬移写漏一笔 flush（绕过 subbus_write 直写 LCPU_REG32_WRITE）→ 中间条目丢失，步骤 10.1 并发测试必炸（6.3 问题 10）；插入从低往高写 → 打流偶发 miss（静态查表全对，最难查的一类）；全零 MAC 校验漏掉（8.2 第 0 步）→ 表内混入 0 后整表查找错乱；删除表尾忘 `wl_hw_delete_entry` 清尾 → USED_CNT 不减。

### 步骤 9：模式切换、烧录与功能回归

**目的**：切 MODE=1 出 bit 上板，5 项功能回归全过。这是 Gate G4/G5 的主体。

**前置条件**：模式1-步骤8 完成（G1~G3 已绿，见 6.2）。

**操作步骤**：

**9.1** 模式切换与构建：`webserver_wrapper.v:1139` `.LOOKUP_MODE(0)` → `(1)`，然后：

```bash
cd build_xilinx_xc7a35tfgg484 && ./build_fpga.sh 0002 && cd ..
# build 后查 timing report：u_ila_ 前缀路径的已知违例忽略（模式0 文档 5.3 问题 1）
```

**9.2** 烧录加载（**固件不用重编**，两模式共用；若步骤 8 的新固件尚未加载过，此时一并加载）：

```bash
openFPGALoader -c digilent_hs2 webserver_xilinx_xc7a35tfgg484_v0002_<时间戳>/webserver_xilinx_xc7a35tfgg484_v0002_<时间戳>.bit
vivado -mode batch -source scripts/load_firmware_vivado.tcl
ping 192.168.1.88 && curl http://192.168.1.88/    # 基础连通，应 200
```

**9.3** 功能回归 5 项：

| # | 项 | 操作 | 期望 |
|---|----|------|------|
| 1 | 模式号上报 | `curl /api/wl/status` | `"lookup_mode":1`（wl_status 修复生效） |
| 2 | 列表有序 | Web 加 3 条乱序 MAC → `/api/wl/list` | 显示为 MAC 升序（index=排名） |
| 3 | 过滤正/反 | 加本机 MAC ping 通；删除后 ping 不通 | 同模式 0 |
| 4 | defpass 两态 | 切换全断/全放 | 同模式 0 |
| 5 | 幂等重复添加 | 同一 MAC 加两次 | 返回同一 index，条目数不涨（8.2 查重生效） |

**产出物**：MODE=1 的 `.bit`、功能回归 5 项记录。

**完成判据**：9.3 五项全过。

**常见错误**：改了 LOOKUP_MODE 忘重出 bit（只重烧旧 bit）→ `/api/wl/status` 仍 0；加载了 `tcl/` 时间戳历史副本 → 行为对不上（公共问题 4）；先上板后发现列表无序→回头查才知 C 固件还是旧版（9.2 没加载步骤 8 产物）。

### 步骤 10：并发、掉电与性能验证（收官）

**目的**：验证本模式两条核心设计承诺在真实环境成立——INV3 搬移中间态保序（打流无感）与 Flash 恢复有序；选做 ILA 实测周期数。全过后 tag `mode1-verified`。

**前置条件**：模式1-步骤9 全过。

**操作步骤**：

**10.1** 搬移并发验证（本模式特有，**必做**）——验证 INV3 在真实打流下成立：

1. 白名单 enable=1，PC 持续 `ping <对端>`；
2. 在 Web 上**连续快速增删 10 次**（每次换不同 MAC，覆盖插入到表头/表尾/中间三种位置）；
3. 期望：ping 允许个别瞬态抖动（插入位次变化可能让新 MAC 短暂未生效），但**不允许长期不通**；
4. 结束后 `/api/wl/hwlist` 与影子表逐条一致（INV1/INV2 未被破坏）。

**10.2** 掉电恢复验证：加 3 条 → 板子断电 → 重启 → `/api/wl/list` 仍有序且过滤行为正确（`apply_snapshot` 排序灌入正确）。

**10.3** 性能实测（选做，ILA）：fpga_ila 已在位（`webserver_signals.json` 4 核）。把 Core0 换抓 `wl_lookup_req/lookup_done`（或用 debug_wc_0 手动触发脉冲，公共问题 5），实测 req→done 拍数：miss 恒 10 拍、命中 4~10 拍（提前退出），与 1.3 理论对照。

**10.4** 收尾：全过 → `git commit` + tag `mode1-verified`。

**产出物**：并发/掉电验证记录（+ ILA 波形截图，若做）；tag `mode1-verified`。

**完成判据**：10.1/10.2 全过（10.3 选做）→ Gate G5 绿，两阶段全部收官。

**常见错误**：并发测试只增不删 → 删除方向的保序 bug（8.3）漏测；掉电前忘 enable=1 → 恢复后行为对但验证不了过滤；ping 长期不通时先怀疑 INV3——先跑静态查表与 `/api/wl/hwlist` 分层定位（思路同模式 0 步骤 10.5 排查）。

---

## 第 4 章 常见错误与排查速查

> 按症状查根因；"相关步骤"列回引第 3 章。

| 症状 | 根因 | 排查 | 相关步骤 |
|------|------|------|---------|
| 表半满时命中判断错、全满时反而对 | hi 初值用了 ENTRY_NUM-1（1.4 细节 1） | 改 `used_cnt-1`；tb 用例 9/11 必抓 | 模式1-步骤3.3 |
| 查高位 MAC（≥0x8000_0000_0000）方向反 | 比较路径被 signed 化 | 检查端口/reg 声明；tb 加高位随机 MAC | 模式1-步骤3.3 |
| 周期数 >10 或死等 done | 忘改读地址驱动 / 又加了 rd_addr_r（1.3 推论） | 核对 `assign bram_rd_addr = mid;`；周期断言兜底 | 模式1-步骤3.2 |
| 大下标区间二分结果错、mid 跳出区间 | 下一跳计算 4bit 回绕 | 核对 `{1'b0, x}` 扩位 | 模式1-步骤3.4 |
| 只在打流时偶发漏判，静态查表全对 | C 搬移顺序破坏 INV3 | 核对插入高→低 / 删除低→高；跑 模式1-步骤10.1 | 模式1-步骤8.2/8.3 |
| 删除表尾条目后 USED_CNT 不减 | 尾条清理漏了 `wl_hw_delete_entry` | 核对 8.3 第 2 步 | 模式1-步骤8.3 |
| 添加全零 MAC 后整个表查找错乱 | 破坏 invalid 推断（1.4 细节 3） | add 开头加全零校验 | 模式1-步骤8.2 |
| Flash 重启后表乱序但功能时对时错 | apply_snapshot 没排序灌入 | 核对 8.6 | 模式1-步骤8.6 |
| Web lookup_mode 还是 0 | wl_status 修复没做 / wrapper 模式号没改 | 4.1 / 9.1 | 模式1-步骤4.1/9.1 |
| MODE=0 回归失败 | 共用代码被本次改动误伤 | diff bin 与 seq 的非 FSM 区，应零差异 | 模式1-步骤2.3/6.3 |

---

## 第 5 章 验收清单与里程碑

| 里程碑 | 完成判据 | 对应步骤 |
|--------|---------|---------|
| M1-1 RTL 完成 | bin.v 编译干净；MODE=1 仿真 14 用例 + 500 次对拍 0 mismatch | 模式1-步骤1~6 |
| M1-1b 回归 | MODE=0 重跑用例 1~8 全过（共用代码没被改坏） | 模式1-步骤6.3 |
| M1-2 上板 | 9.3 功能回归 5 项过 | 模式1-步骤9 |
| M1-3 并发与恢复 | 10.1 搬移并发 + 10.2 掉电恢复过 | 模式1-步骤10 |
| M1-4（选做） | ILA 实测 req→done ≤10 拍 | 模式1-步骤10.3 |
| 收尾 | git tag `mode1-verified` | 模式1-步骤10.4 |

---

## 第 6 章 仿真分层、上板门禁与已知问题

### 6.1 整链路仿真分层

分层定义（L0~L3）与"不单独仿真的模块"清单见模式 0 文档 5.1 节。模式 1 的差异：**每层都双跑**——L1/L2 的 tb 参数化两模式，MODE=1 验证新算法、MODE=0 回归共用代码（G2b）。L3 系统层本期同样跳过。

### 6.2 上板门禁（Gate）——不满足不许烧板

| Gate | 内容 | 通过标准 | 达成于 |
|------|------|---------|--------|
| G1 | L0 编译干净 | bin.v + wrapper 0 error / 0 critical warning | 模式1-步骤2/4 |
| G2 | L1 单元 tb | MODE=1 的 14 用例 + 500 次对拍 0 mismatch | 模式1-步骤6.2 |
| G2b | L1 回归 | MODE=0 重跑 8 用例全过（共用代码未被改坏） | 模式1-步骤6.3 |
| G3 | L2 集成 tb | 双模式各 6 用例过 + 模式 1 特有用例 7 过 | 模式1-步骤7 |
| G4 | 产物齐套 | MODE=1 的 `.bit` + **固定名 `tcl/InstructRAM.tcl`**（勿拿时间戳历史副本） | 模式1-步骤9.1/9.2 |
| G5 | 板测 | 9.3 + 10.1/10.2 全过 → tag `mode1-verified` | 模式1-步骤9/10 |

> G1~G3 全绿才允许执行 `build_fpga.sh`。

### 6.3 已知问题（干活前必读）

**公共 8 条**见《模式 0》文档 5.3 节（已知时序违例=u_ila 路径忽略、固件加载只用固定名 InstructRAM.tcl、sim/Makefile 别碰、跨域信号用 `_125m` 后缀等），执行前先通读一遍。**模式 1 额外注意**：

| # | 问题 | 处理 | 相关步骤 |
|---|------|------|---------|
| 9 | `wl_status` 未驱动在本模式**必须修**（模式 0 读数凑巧=0 可缓，模式 1 读不出 1 就无法验收 G5 第 1 项） | 模式1-步骤4.1，方案 a/b 任选 | 模式1-步骤4.1 |
| 10 | C 搬移的 16 条×4 笔写全部要过 `subbus_write()`（内含 flush） | 漏一笔 flush = 中间条目丢失，10.1 并发测试必炸 | 模式1-步骤8 |
| 11 | 全零 MAC 校验别忘（1.4 细节 3） | add 开头一行 | 模式1-步骤8.2 |

---

## 附录

### A. 二分 vs 顺序 vs 哈希选型（背景知识）

| | 模式 0 顺序 | 模式 1 二分（本文） | 模式 2 布谷鸟哈希 |
|---|-----------|------------------|------------------|
| 最坏周期（16 条） | 18 拍 144ns | 10 拍 80ns | 2~3 拍 |
| 64 条 | 66 拍 528ns（逼近极限） | 14 拍 112ns | 2~3 拍 |
| 512 条 | 不可行 | 22 拍 176ns | 必须 |
| 前置条件 | 无 | **表有序（软件维护）** | Hash 函数 + eviction 状态机 |
| 实现复杂度 | 低 | 中 | 高 |

16 条目下两模式都线速安全；模式 1 的真正价值是掌握**"软件维护有序结构 + 硬件二分查找"范式**——它是后续防火墙 L3/L4 规则表（IP/五元组、条目数增长）的直接基础。

### B. 文件索引

| 文件 | 角色 |
|------|------|
| `rtl/mac_whitelist_bin.v` | 本模式待新建（设计稿=第 1、3 章） |
| `rtl/mac_whitelist_seq.v` | 复制起点（配置通路部分原样保留） |
| `rtl/mac_whitelist_top.v` | MODE 分支（38~67 行 generate 改三段） |
| `rtl/webserver_wrapper.v` | 1139 行模式号；wl_status 修复（168/480 行） |
| `c/whitelist.c` | 模式1-步骤8：有序 add/delete/snapshot |
| `sim/define_sim.sv` | 仿真专用宏（模式0-步骤3.5 创建，双模式共用） |
| `../ip_common/rtl/` | 仓库外层共享库（仿真依赖路径前缀） |
| `doc/MAC白名单查找引擎实现指南_模式0_顺序查找.md` | 前置文档（框架机制 + L1/L2 tb 模板） |

### C. 时序图来源索引

| 图 | 内容 | 来源 |
|----|------|------|
| 图 1 | 二分查找 FSM 逐拍时序（≤10 拍） | 自设计（本模式特有，共享库无对应文档） |
| 图 2 | cfg 口电平敏感写采样 | 自设计，与模式 0 文档图 2 同源 |

---
*文档结束。实施顺序：第 1 章吃透 → 步骤 2~4 RTL → 步骤 5~7 仿真（先 MODE=1 后 MODE=0 回归）→ 步骤 8 C 改造 → 步骤 9~10 上板。每步验收不过不进下一步。*
