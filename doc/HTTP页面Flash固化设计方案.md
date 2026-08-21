# HTTP 页面 Flash 固化设计方案（方案 B：硬件内存映射读）

> 生成时间：2026-08-20
> 目标：把 Web 页面从固件 `http.c` 内嵌字符串，迁到 SPI Flash `0x420000`，运行时经硬件
> `flash_mem_reader` 内存映射到 RISC-V 地址 `0x90000000` 段读取。

---

## 1. 已拍板决定

1. **方案 B**：新增硬件 `flash_mem_reader`，把 Flash **整颗 16MB** 内存映射到 `0x90000000`
   段，固件读页面 = 读内存。**不走**方案 A（固件经 lcpu_sflash 软件逐字读）。
2. **页面支持 CSS/JS/图片**：TOC 条目带 `content_type`，固件按类型动态生成 `Content-Type`。
3. **按 4KB 扇区对齐、只擦用到的扇区**：TOC 占第 0 扇区，每页各占一个 4KB 扇区。
4. 译码只改 `webserver_wrapper.v`，**不动共享库 ip_riscv**。

## 2. 地址映射（整 16MB 直接映射）

`lcpu_riscv_wrapper` 输出的 `cpu_address` 是**字地址** = `{3'b0, byte_addr[30:2]}`
（`riscv_reg.v:88` 丢 bit31、`riscv32_top.v:76` 高3位补0）。
字节 `0x90000000` = 字 `(0x90000000 & 0x7FFFFFFF)>>2` = `0x04000000`（**不是** `0x24000000`）。
在 `webserver_wrapper.v` 截断成 `[15:0]` 之前单独译码：

```verilog
assign flash_mem_window = (cpu_address[31:24] == 8'h04);   // 0x90000000~0x90FFFFFF = 16MB（字 0x04000000~0x043FFFFF）
assign flash_mem_addr   = {cpu_address[21:0], 2'b00};       // 24bit flash 字节地址（字地址低22位 = 字节地址>>2，左移2位恢复）
```

- `0x90000000 + flash字节地址 → flash[flash字节地址]`，web/config/预留/固件区都能读，零额外 RTL。
- `0x90000000` 段从 reg_webserver 屏蔽（`.req(cpu_req & ~flash_mem_window)`），否则会截断成
  字地址 `0x8000` 假命中 `program_ram`。
- CPU 应答多路：`cpu_ack = reg_ws_ack | fmr_ack; cpu_rdata = flash_mem_window ? fmr_rddata : reg_ws_rdata;`

## 3. RTL 设计

### 3.1 flash_mem_reader.v（新增）

- 接口：50MHz bus（`op_req/rhwl/address[23:0]/rddata/op_ack/busy`）+ 5MHz `spi_ctrl`。
- 时钟域（镜像 `spi_bootloader` v411，规避 op_done 的 CDC 竞态）：
  - 50MHz：请求捕获 + `start_req/start_ack`、`word_valid/word_ack` 两个 4 相位电平握手。
  - 5MHz：SPI 读状态机（与 `spi_ctrl` 同域，`op_done` 同域直采）。
- 逐字 stall 读：收到 `op_req`（读）→ 发 `0x03` Read Data（8 cmd + 24 addr + 32 data = 64bit）→
  CPU 停等 `mem_ready` 约 640 周期 → `op_ack` + `rddata`。
- **首读唤醒**：复位后第一次读前先发一笔 `0x9F` JEDEC ID 读（结果丢弃），之后靠 `woke` 标志跳过。
- **只读写保护**：`rhwl=0`（写）立即 `op_ack` 丢弃，防 lcpu_merge 无人应答卡死。
- **字节序**：`spi_rdata[31:24]` 是 flash 低地址字节（线上 MSB-first），RISC-V 是小端，故硬件
  做 32bit 字节交换，让 `0x90000000` 段呈现小端内存（`flash[addr]` 落在字节 0）。

### 3.2 webserver_wrapper.v（修改）

- 加 `flash_mem_window/sel/addr` 译码 + `reg_ws_ack/rdata` 拆分 + `cpu_ack/cpu_rdata` 多路。
- 例化 `flash_mem_reader` + 专属 `spi_ctrl u_fmr_spi`（复用 `spi_clk_bl` 5MHz）。
- SPI 引脚 mux 从 2 路扩成 3 路优先级：
  ```verilog
  flash_sclk = bootloader_status[0] ? spi_sclk_bl : (fmr_busy ? spi_sclk_fmr : spi_sclk_sf);
  ```
  优先级 `bootloader > flash_mem_reader > lcpu_sflash`；`fmr_busy` 是电平，覆盖整个 SPI 事务。

## 4. 固件设计

- `c/inc/web_pages.h`：TOC 常量 + content_type 枚举 + 路由 ID + 声明。
- `c/web_pages.c`：
  - `web_page_lookup(route_id, &addr, &len, &type)`：读 TOC 匹配路由。
  - `send_web_page(conn_idx, route_id)`：生成 `Content-Length/Content-Type` 头 + 从 flash 流式发 body。
  - `send_web_body`：按 32bit 字读 flash，逐字节填入发送缓冲（每字读一次，4 字节复用）。
- `c/tcp.c`：
  - 新增 `send_http_buffer(conn_idx, ptr, len)`（从 `send_http_response` 抽出 MSS 分片循环，
    参数化指针+长度，不 strlen）。
  - 路由改调 `send_web_page(conn_idx, WEB_ROUTE_*)`。
- `c/http.c`：删除 3 个内嵌页面字符串（只留 `post_response`）。Content-Length 改为动态计算，
  顺带修掉 `localconfig_page` 硬编码长度偏小的隐患和 `wlconfig_page` 的 `width:100%%` CSS bug。
- `c/inc/lcpu_general.h`：加 `FLASH_MEM_BASE/FLASH_MEM_RD32` 宏；修过时 `SFLASH_SUBBUS_BASE`
  `0x1400→0x4000`、`WL_SUBBUS_BASE 0x1500→0x5000`。

## 5. TOC 布局与字节序

Flash `0x420000`（TOC 占第 0 扇区，每页各占一个 4KB 扇区）：

```
0x420000  0x00  magic  4B  "WEBP"（小端 0x50424557）
          0x04  version u16 = 1
          0x06  count   u16 = N
          0x08  N × 16B 条目：
                0x00 route_id u32
                0x04 content_type u8 + 3B reserved
                0x08 offset u32（相对 0x420000，4KB 对齐）
                0x0C length u32（字节）
0x421000  页面 1 内容（index.html）
0x422000  页面 2 内容（wlconfig.html）
0x423000  页面 3 内容（localconfig.html）
```

- 路由 ID：`'/'=1`、`'/wlconfig'=2`、`'/localconfig'=3`。
- content_type 枚举：`0=text/html 1=text/css 2=application/javascript 3=image/png 4=image/svg+xml
  5=image/x-icon 6=application/json 7=text/plain`。
- **字节序约定**：打包工具把 `image[0]` 放 word 的 MSB（`flash_program_word` 是 MSB-first 写），
  配合 `flash_mem_reader` 硬件字节交换，RISC-V（小端）读回恰好是自然字节序，TOC 字段按小端存。

## 6. 打包工具与烧写

- `c_build/pages_to_flash_tcl.py`：读 `html/*.html` → 生成「TOC + 内容」镜像 → 输出自包含
  `tcl/html_flash_initial.tcl`（复用 `bin_to_flash_tcl.py` 的 `FLASH_INIT_PREAMBLE`）。
- 脚本流程：`jwrite 0xF 0x0`（复位 RISC-V）→ 擦 4 个 4KB 扇区 `0x420000/0x421000/0x422000/
  0x423000` → 逐字 `0x02` 编程（1661 字）→ `jwrite 0xF 0x1`。
- 调试闭环：改 `html/` 文件 → `python3 pages_to_flash_tcl.py` → Vivado 里重跑脚本 → 浏览器刷新，
  **不重编固件、不重下 bitstream**。

## 7. 影响面 / 兼容性

- **JTAG/LCPU 内部寄存器访问**：不受影响。JTAG 走 `lcpu_merge` 的 Port 1，地址高位为 0，进不了
  `0x24` 窗口；`0x90000000` 段已从 reg_webserver 屏蔽。
- **flash 固件区（0x400000）**：bootloader 读仍是 mux 最高优先级；JTAG 写固件时 RISC-V 处于复位、
  flash_mem_reader idle，lcpu_sflash 照常占有引脚。
- **唯一新增行为**：页面读期间 CPU 经 `mem_ready` 停等约 640 周期（13µs），这段时间 JTAG 总线访问
  顺延最多 13µs（JTAG TCL 轮询是 ms 级，无感）。

## 8. 关键文件

| 文件 | 状态 |
|------|------|
| `rtl/flash_mem_reader.v` | 新增 |
| `rtl/webserver_wrapper.v` | 修改（译码 + 3 路 mux + 应答多路） |
| `c/inc/web_pages.h` | 新增 |
| `c/web_pages.c` | 新增 |
| `c/tcp.c` / `c/inc/tcp.h` | 修改（send_http_buffer + 路由） |
| `c/http.c` / `c/inc/http.h` | 修改（删页面字符串） |
| `c/inc/lcpu_general.h` | 修改（FLASH_MEM 宏 + 修过时地址） |
| `html/*.html` | 新增（源页面，body only） |
| `c_build/pages_to_flash_tcl.py` → `tcl/html_flash_initial.tcl` | 新增 |
| `sim/tb_flash_mem_reader.sv` | 新增（单仿，4 读+写验证通过） |

## 9. 验证状态

- `flash_mem_reader.v` iverilog 语法检查通过。
- 固件 `make elf` 编译链接通过（`text` 从 ~23920 降到 18052 字节，页面字符串已移出）。
- `tb_flash_mem_reader.sv` 单仿 PASS：首读唤醒、0x03 读、32bit 字节交换、24bit 地址、只读写保护、
  写后重读不变，全部正确。
- 待上板：烧 `html_flash_initial.tcl` → bootloader 载固件 → 浏览器访问 3 页。
