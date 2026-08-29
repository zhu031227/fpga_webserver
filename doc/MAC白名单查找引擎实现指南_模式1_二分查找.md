# MAC 白名单查找引擎实现指南 · 模式 1 —— BRAM 二分查找（从零实现）

> 文档编号：ED003R01-B
> 日期：2026-08-28
> 适用工程：`fpga_webserver-whitelist_dev`（whitelist_dev 分支）
> 平台：Xilinx XC7A35T-FGG484-2（ACX750 开发板）
> 性质：**从零实现指南**。模式 1 当前在工程中**不存在任何实现**（`mac_whitelist_top.v` 里是 placeholder），本文即完整设计稿与实施步骤。
> **前置条件**：《MAC白名单查找引擎实现指南_模式0_顺序查找.md》已全部完成并上板（tag `mode0-verified`）。第 1 章的框架机制（数据通路/配置通路/存储结构/寄存器表）在模式 0 文档中详述，本文默认你已掌握，只做要点回顾。

---

## 第 0 章 文档定位与差异总览

### 0.1 目标

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
| 增删条目 | 找 free slot 直接写 | **软件搬移保持有序**（第 3 章） |
| 配置通路/寄存器表/shadow_rf/CLEAR 序列器 | — | **完全复用，RTL 零改动** |
| C 驱动接口签名 | — | **完全复用**（tcp.c 等上层无感知） |

### 0.3 白名单位置（简版，详见模式 0 文档 0.3 节）

```
eth1 RX ─► 提取SrcMAC ─► lookup_req ─► [mac_whitelist_top MODE=1 二分查BRAM] ─► match ─► 门控wpkt_push ─► eth2 TX
                                            ▲ cfg口(SubBus 0x5000, 50MHz)
                                     C固件 whitelist.c（有序影子表 + 搬移式增删）
```

---

## 第 1 章 设计决策与软硬件契约

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
不变式 INV3：任意时刻 HW 表都满足 INV1+INV2 —— 包括 C 搬移的每笔写之间（第 3.5 节保序设计）。
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

**为什么不能流水**：发 mid1 之前必须知道 mac[mid0] 与目标的大小关系——数据依赖链强制串行。要更快只能上 MODE 2 哈希（2~3 拍），那是另一个项目。

### 1.4 四个硬件特有的关键细节（最容易踩坑处，逐条记住）

| # | 细节 | 错误做法的后果 | 正确做法 |
|---|------|--------------|---------|
| 1 | **hi 初值用 `used_cnt-1`，不是 `ENTRY_NUM-1`** | 若用 15：mid 越过 used-1 后读到 invalid 条目（49'b0，mac=0）。mac=0 比任何真实 MAC 都小 → 二分被误导**向右**走 → 永不收敛到正确结果，miss 的包查成"向右越界"，**hit 的包也可能漏判** | 复用模式 0 已有的 `used_cnt_comb`（popcount 链），INV1 保证它精确等于有效条数 |
| 2 | **invalid 强制向左（双保险）** | 同上 | `S_CMP` 里：`!bram_rd_valid` 时按"mac[mid] > target"分支处理（hi=mid-1）。双保险，即使 used_cnt 短暂不准也不死循环 |
| 3 | **全零 MAC 禁止入表** | mac=0 无法与 invalid 区分，破坏细节 1/2 的推断 | C 侧 `whitelist_add` 开头校验：6 字节全 0 拒绝（单播 MAC 永不为全零，无功能损失） |
| 4 | **48bit 比较必须无符号** | 若信号被声明成 signed，mac[47]=1 的 MAC（如 80:00... 开头的组播位）比较方向全错 | Verilog 的 reg/wire 默认无符号；**不要**在任何比较路径上加 signed 声明；tb 里用 `2**48` 以上随机值覆盖高位 |

### 1.5 空表与单条表

- `used_cnt==0`：IDLE 收到 req 直接转 DONE，match=0（连 ISSUS 都不发）——tb 必须覆盖；
- `used_cnt==1`：区间 [0,0]，一次迭代收敛——tb 必须覆盖。

---

## 第 2 章 RTL 实现：`mac_whitelist_bin.v`

### 2.1 复用策略：从 seq 复制，只动两处

```bash
cp rtl/mac_whitelist_seq.v rtl/mac_whitelist_bin.v
```

然后：

| 保留（一行不改） | 替换 |
|------------------|------|
| 端口声明（只改模块名） | 查找 FSM（256、281~314 行）→ 新四态 FSM |
| 配置译码 always 块（144~216 行） | `bram_rd_addr` 驱动方式（见 2.3） |
| shadow_rf / CLEAR 序列器 / free_idx / popcount / 读 mux（217~254 行） | — |
| 寄存器表语义 | **注意 C 侧语义变化见第 3 章（RTL 本身不变）** |

模块头部注释**必须**写上 INV1/INV2/INV3 契约和"信任契约、不做校验"的声明。

### 2.2 查找 FSM 完整代码

```verilog
// ============================================================
// Binary search FSM (125MHz) — 信任 INV1/INV2 契约
//   IDLE → ISSUE(发mid地址) → CMP(比较+算下一跳) → ... → DONE
//   每迭代 2 拍；命中提前退出；≤4 迭代；req→done ≤10 拍
// ============================================================
localparam S_IDLE=2'd0, S_ISSUE=2'd1, S_CMP=2'd2, S_DONE=2'd3;

reg [ADDR_WIDTH-1:0] lo, hi, mid;
reg                  hit;

// ★ 与 seq 的差异：rd_addr 改为寄存器驱动（S_ISSUE 拍发出，S_CMP 拍数据有效）
//   seq 里挂在 state 上是"扫地址"式；二分必须显式控制发哪个地址
reg [ADDR_WIDTH-1:0] rd_addr_r;
assign bram_rd_addr = rd_addr_r;

always @(posedge clk or negedge reset_l) begin
    if (!reset_l) begin
        state<=S_IDLE; lo<=0; hi<=0; mid<=0; hit<=0;
        lookup_match<=0; lookup_done<=0; rd_addr_r<=0;
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
            rd_addr_r <= mid;                          // 发地址，下一拍数据有效
            state     <= S_CMP;
        end
        S_CMP: begin
            if (bram_rd_valid && (bram_rd_mac == lookup_mac)) begin
                hit   <= 1'b1;                         // ★ 提前退出
                state <= S_DONE;
            end else if (!bram_rd_valid || (bram_rd_mac > lookup_mac)) begin
                // ★ 细节2：invalid 当作"偏大"强制向左
                if (mid == 0) state <= S_DONE;         // 向左越界 → miss
                else begin
                    hi  <= mid - 1'b1;
                    mid <= (lo + mid - 1'b1) >> 1;
                    state <= S_ISSUE;
                end
            end else begin                             // mac[mid] < target → 向右
                if (mid == hi) state <= S_DONE;        // 向右越界 → miss
                else begin
                    lo  <= mid + 1'b1;
                    mid <= (mid + 1'b1 + hi) >> 1;
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

**逐拍自查表**（used=16、查 miss、全程 4 迭代）：

```
拍:    0     1      2      3      4      5      6      7      8      9
状态:  IDLE  ISSUE  CMP    ISSUE  CMP    ISSUE  CMP    ISSUE  CMP    DONE
地址:  -     mid0   -      mid1   -      mid2   -      mid3   -
数据:  -     -      d(m0)  -      d(m1)  -      d(m2)  -      d(m3)
                                   req→done = 10 拍 ✓（tb 强断言）
```

**收敛性自查**（心算走一遍）：used=16, hi=15, mid0=7 → 若偏大 hi=6, mid1=3 → 若偏小 lo=4, mid2=5 → 若偏大 hi=4, mid3=4 → 最后一跳恰 mid==lo==hi，比较一次定输赢。4 次迭代覆盖 16 条 ✓。

### 2.3 `bram_rd_addr` 驱动方式改动说明

模式 0 里 `assign bram_rd_addr = (state==S_COMPARE) ? cmp_index : 0;` 是"扫地址"式——地址由递增计数器隐式产生。二分不能这样写（地址跳变由比较结果决定），改为 **`rd_addr_r` 寄存器 + S_ISSUE 拍装载**。这是从 seq 复制后**必须改**的第二处（第一处是 FSM 本体），漏改会综合出错误行为且仿真可能侥幸通过——tb 的周期数断言和随机对拍是兜底。

### 2.4 顺手修复：`wl_status` 未驱动（现存缺口）

现状（通读工程发现）：`webserver_wrapper.v` 168 行声明 `wl_status`，480 行连进 reg_webserver（0x301，Web `/api/wl/status` 的 lookup_mode 字段），但**全工程没有一处 assign 驱动它**——读回恒 0，无法核对当前模式。

修复（2 选 1）：

```verilog
// 方案 a（最小改动）：wrapper 里直接 assign 常量模式号
assign wl_status = {8'b0, 8'd1};            // LOOKUP_MODE=1

// 方案 b（完整，推荐）：给 mac_whitelist_top 加输出口
//   top:  output [7:0] used_cnt_o   →  assign used_cnt_o = used_cnt_comb;
//   bin/seq 各加同名输出口透传
//   wrapper:  assign wl_status = {u_mac_wl_used, 8'd1};
//   → Web 状态栏同时显示 模式号 + 实时条目数（tcp.c 的 status 接口已在读 wl_status）
```

### 2.5 top 集成与模式切换

`mac_whitelist_top.v` 的 generate 改成三段：

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

切换：`webserver_wrapper.v:1139` `LOOKUP_MODE(0)` → `(1)`，重编 bitstream。**C 固件不用重编**（同一份固件两模式通用）。

`filelist.cfg` 加：`../rtl/mac_whitelist_bin.v`。

---

## 第 3 章 C 驱动有序化改造（`c/whitelist.c`）

### 3.1 改动范围

**只动 `whitelist.c`**，四处函数：`whitelist_add`、`whitelist_delete`、`whitelist_apply_snapshot`（改为排序灌入）、新增 2 个 static 工具函数。`whitelist.h` 签名不变 → tcp.c/http.c/flash_cfg.c 零改动。

新增工具函数：

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

### 3.2 有序插入（替换 `whitelist_add` 主体）

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

**为什么必须从高往低写（INV3 论证）**：搬移的本质是"pos 及之后的条目整体右移一格"。从高往低覆盖时，任意两笔写之间 HW 表的形态是"新表的一部分 ∪ 旧表的一部分"，数学上可证每个 index 处的值仍随 index 单调不减——只会出现**瞬时重复**（同一个 MAC 同时在 i 和 i-1），重复不影响二分命中判断（查到哪个都=命中）。**反过来从低往高写，中间态会出现"前一条比后一条大"的真乱序点**，此时打流进来一个恰落在乱序区间的包就会被错误 miss。

### 3.3 有序删除（替换 `whitelist_delete` 主体）

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

同理，从低往高覆盖 = "整体左移一格"，每笔之间表仍有序（可能瞬时重复），INV3 成立。

> **设计取舍说明**：按上述顺序，搬移期间**无需临时关闭白名单**（wl_ctrl[0] 不用动），打流完全无感。若你实现时选了无序覆盖，就必须"搬移前置 en=0、完成恢复"——功能也正确，但过滤会瞬断几百 µs。两种都算对，注释里写清你选的哪种、为什么。

### 3.4 快照恢复与 Flash 兼容性

- Flash 格式（`flash_cfg.h` 的 42 word 布局）**零改动**——它存的是影子表快照（valid_mask + mac 数组），模式 1 下影子表本身有序，存取顺序天然一致；
- `whitelist_apply_snapshot` 防御性改造：Flash 读回后先在影子数组内**插入排序**，再按 index 0..n-1 逐条 `wl_hw_write_entry` 灌入——即使 Flash 内容被外部改乱也能恢复出合法有序表；
- `whitelist_clear_all` 不变（CLEAR 序列器 RTL 原样）。

### 3.5 与 HW 回读接口的一致性

`/api/wl/list`（tcp.c 731 行起）逐条 `whitelist_hw_read_entry(i)` 读的是 shadow_rf——搬移时影子表与 shadow_rf 同步更新，页面显示自动与 HW 一致。**预期行为变化**：列表从"添加顺序"变为"MAC 升序"——这是模式 1 的正确语义（index=排名），网页无需改动。

---

## 第 4 章 仿真验证

### 4.1 tb 设计

新建 `sim/tb_mac_whitelist_bin.sv`：**参数化两模式**（`parameter MODE`，MODE=0 例化 seq、MODE=1 例化 bin），一套用例代码跑两种模式——这同时就是回归框架。tb 内用 SV 队列（`int unsigned sw_model[$]`）维护**金模型**（软件视角的有序表）。

SubBus 写任务、时钟生成照抄模式 0 tb（模式 0 文档步骤 7）。

### 4.2 用例矩阵（14 条）

| # | 用例 | 期望 | 备注 |
|---|------|------|------|
| 1~6 | 复用模式 0 用例 1~6（增删查清/表满/en+defpass） | 同模式 0 | 配置通路共用的回归 |
| 7 | 周期数断言 | **≤10**（模式 0 为 ==18） | 两模式的分水岭断言 |
| 8 | busy 期间 req 被忽略 | 同模式 0 | — |
| 9 | 有序灌 8 条随机 MAC → 查 8 命中 + 8 miss | 全部正确 | — |
| 10 | 边界值：查最小条目 / 最大条目 / 中位 | 命中 | 二分路径全覆盖 |
| 11 | **金模型随机对拍**：500 次随机 add/del/lookup，每次 lookup 后比对 RTL match 与软件模型判断 | 0 mismatch | 本模式核心校验 |
| 12 | 空表 lookup | done=1、match=0、周期最短 | 1.5 节 |
| 13 | used=1 单条表查命中/miss | 正确收敛 | 1.5 节 |
| 14 | 乱序注入防御 | C 契约测试（软件层） | 若有 C 单测环境则跑，否则靠对拍覆盖 |

**跑法**：`MODE=0` 跑一遍（回归模式 0 没被改坏）→ `MODE=1` 跑一遍（全 14 条）。

### 4.3 对拍金模型参考

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

---

## 第 5 章 上板验证

### 5.1 模式切换与烧录

```bash
# 1. wrapper LOOKUP_MODE 改 1 → 出 bit
cd build_xilinx_xc7a35tfgg484 && ./build_fpga.sh 0002
# 2. 烧录（固件不用重编，两模式共用）
openFPGALoader -c digilent_hs2 webserver_xilinx_.../webserver_...0002....bit
vivado -mode batch -source load_fw.tcl
```

### 5.2 功能回归

| # | 项 | 操作 | 期望 |
|---|----|------|------|
| 1 | 模式号上报 | `curl /api/wl/status` | `"lookup_mode":1`（wl_status 修复生效） |
| 2 | 列表有序 | Web 加 3 条乱序 MAC → `/api/wl/list` | 显示为 MAC 升序（index=排名） |
| 3 | 过滤正/反 | 加本机 MAC ping 通；删除后 ping 不通 | 同模式 0 |
| 4 | defpass 两态 | 切换全断/全放 | 同模式 0 |
| 5 | 幂等重复添加 | 同一 MAC 加两次 | 返回同一 index，条目数不涨（3.2 查重生效） |

### 5.3 搬移并发验证（本模式特有，必做）

**目的**：验证 INV3（搬移中间态保序）在真实打流下成立。

1. 白名单 enable=1，PC 持续 `ping <对端>`；
2. 在 Web 上**连续快速增删 10 次**（每次换不同 MAC，覆盖插入到表头/表尾/中间三种位置）；
3. 期望：ping 允许个别瞬态抖动（插入位次变化可能让新 MAC 短暂未生效），但**不允许长期不通**；
4. 结束后 `/api/wl/hwlist` 与影子表逐条一致（INV1/INV2 未被破坏）。

### 5.4 掉电恢复验证

加 3 条 → 板子断电 → 重启 → `/api/wl/list` 仍有序且过滤行为正确（`apply_snapshot` 排序灌入正确）。

### 5.5 性能实测（选做，ILA）

fpga_ila 已在位（`webserver_signals.json` 4 核）。把 Core0 换抓 `wl_lookup_req/lookup_done`（或用 debug_wc_0 手动触发脉冲），实测 req→done 拍数：miss 恒 10 拍、命中 4~10 拍（提前退出），与理论对照。

---

## 第 6 章 常见错误与排查

| 症状 | 根因 | 排查 |
|------|------|------|
| 表半满时命中判断错、全满时反而对 | hi 初值用了 ENTRY_NUM-1（1.4 细节 1） | 改 `used_cnt-1`；tb 用例 9/11 必抓 |
| 查高位 MAC（≥0x8000_0000_0000）方向反 | 比较路径被 signed 化 | 检查端口/reg 声明；tb 加高位随机 MAC |
| 周期数 >10 或死等 done | 忘了改 `bram_rd_addr` 驱动方式（2.3） | 核对 rd_addr_r；周期断言兜底 |
| 只在打流时偶发漏判，静态查表全对 | C 搬移顺序破坏 INV3 | 核对插入高→低 / 删除低→高；跑 5.3 并发验证 |
| 删除表尾条目后 USED_CNT 不减 | 尾条清理漏了 `wl_hw_delete_entry` | 核对 3.3 第 2 步 |
| 添加全零 MAC 后整个表查找错乱 | 破坏 invalid 推断（1.4 细节 3） | add 开头加全零校验 |
| Flash 重启后表乱序但功能时对时错 | apply_snapshot 没排序灌入 | 核对 3.4 |
| Web lookup_mode 还是 0 | wl_status 修复没做 / wrapper 模式号没改 | 2.4/2.5 |

---

## 第 7 章 验收清单与里程碑

| 里程碑 | 完成判据 |
|--------|---------|
| M1-1 RTL 完成 | bin.v 编译干净；MODE=1 仿真 14 用例 + 500 次对拍 0 mismatch |
| M1-1b 回归 | MODE=0 重跑用例 1~8 全过（证明共用代码没被改坏） |
| M1-2 上板 | 5.2 功能回归 5 项过 |
| M1-3 并发与恢复 | 5.3 搬移并发 + 5.4 掉电恢复过 |
| M1-4（选做） | ILA 实测 req→done ≤10 拍 |
| 收尾 | git tag `mode1-verified` |

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
| `rtl/mac_whitelist_bin.v` | 本模式待新建（设计稿=第 2 章） |
| `rtl/mac_whitelist_seq.v` | 复制起点（配置通路部分原样保留） |
| `rtl/mac_whitelist_top.v` | MODE 分支（60~66 行 placeholder 替换） |
| `rtl/webserver_wrapper.v` | 1139 行模式号；wl_status 修复 |
| `c/whitelist.c` | 第 3 章：有序 add/delete/snapshot |
| `doc/MAC白名单查找引擎实现指南_模式0_顺序查找.md` | 前置文档（框架机制） |

---
*文档结束。实施顺序：第 1 章吃透 → 第 2 章 RTL → 第 4 章仿真（先 MODE=1 后 MODE=0 回归）→ 第 3 章 C 改造 → 第 5 章上板。每步验收不过不进下一步。*
