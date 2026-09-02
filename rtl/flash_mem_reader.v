// flash_mem_reader — RISC-V 只读内存映射读 SPI Flash（方案 B）
//
// 把整颗 SPI Flash（MX25L12845, 16MB）映射到 RISC-V 地址 0x90000000 段：
//     0x90000000 + flash字节地址  →  flash[flash字节地址]
// 每次 CPU 读一个字（4 字节），本模块发 0x03 Read Data 命令，停等 SPI 返回
// 32bit 数据后 op_ack 回总线（CPU 经 mem_ready 停等）。只读：写访问立即 ack
// 丢弃（防 lcpu_merge 因无人应答而卡死），不改写 Flash。
//
// 时钟域（与 spi_bootloader v411 同款结构，避免 op_done 的 CDC 竞态）：
//   50MHz(clk)    — 总线接口 + 请求捕获 + 结果握手
//   5MHz(spi_clk) — SPI 读状态机（与 spi_ctrl 同域，op_done 同域直采）
// 两个 4 相位电平握手：
//   op_req ──start_req/start_ack(带 flash 字节地址)──▶ 5MHz SPI 读状态机
//   rddata ◀─────word_valid/word_ack(带 32bit 读回字)───── op_done 同域直采
//
// 首读唤醒：flash 上电/复位后第一次读会返回全 F（MISO 未驱动）。首次读请求前
// 先发一笔 0x9F JEDEC ID 读（结果丢弃）唤醒 flash，之后靠 woke 标志跳过。正常
// 流程里 bootloader 已先唤醒（读 0x400000 固件），这笔只是兜底。

module flash_mem_reader (
    input           clk,          // 50MHz — 总线接口
    input           spi_clk,      // 5MHz  — SPI 控制（与 spi_ctrl 同域）
    input           reset_l,

    // LCPU bus slave（只读映射）
    input           op_req,       // single-cycle pulse
    input           rhwl,         // 1=read, 0=write（写：立即 ack 丢弃）
    input  [23:0]   address,      // Flash byte address (0x000000 ~ 0xFFFFFF)
    output reg [31:0] rddata,
    output reg      op_ack,
    output          busy,         // 电平：整个 SPI 读事务期间为 1，供顶层 mux 选通

    // SPI master interface (to spi_ctrl, 5MHz 域)
    output reg      spi_op_start,
    output reg [15:0] spi_channel_len,
    output     [63:0] spi_wdata,
    input      [31:0] spi_rdata,
    input             spi_op_done
);

  // ============================================================
  // 状态定义
  // ============================================================
  // 5MHz 域 SPI 读状态机
  localparam [2:0] S5_IDLE       = 3'd0;
  localparam [2:0] S5_CMD        = 3'd1;
  localparam [2:0] S5_WAIT_START = 3'd2;
  localparam [2:0] S5_WAIT_DONE  = 3'd3;
  localparam [2:0] S5_PUSH       = 3'd4;
  localparam [2:0] S5_NEXT       = 3'd5;
  localparam [2:0] S5_GAP        = 3'd6;

  // 50MHz 域请求状态机
  localparam [1:0] P_IDLE = 2'd0;
  localparam [1:0] P_BUSY = 2'd1;
  localparam [1:0] P_DONE = 2'd2;

  // 字间空隙拍数（冗余保险：握手本身已保证 spi_ctrl 回到空闲）
  localparam [2:0] GAP_CYCLES = 3'd2;

  // ============================================================
  // 5MHz 域寄存器
  // ============================================================
  reg [2:0]  s5_state;
  reg [1:0]  start_req_s;   // start_req 的 2FF 同步（50→5）
  reg        start_ack;     // 启动握手 ack（电平，4 相位）
  reg [23:0] flash_addr_reg5;
  reg [31:0] word_data;     // 读回字，word_valid 期间保持稳定
  reg        word_valid;    // 读回握手 valid（电平，4 相位）
  reg [1:0]  word_ack_s;    // word_ack 的 2FF 同步（50→5）
  reg [63:0] spi_wdata_msb; // [63:56]=cmd, [55:32]=addr, [31:0]=data
  reg [2:0]  gap_cnt;
  reg        woke;          // 1 = flash 已被唤醒（做过一次 0x9F 读）
  reg        wake_read;     // 1 = 当前这笔是唤醒读（结果丢弃）

  // ============================================================
  // 50MHz 域寄存器
  // ============================================================
  reg [1:0]  pstate;
  reg        start_req;     // 启动握手 req（电平，4 相位）
  reg [1:0]  start_ack_s;   // start_ack 的 2FF 同步（5→50）
  reg [23:0] addr_latch;    // op_req 时锁存的 flash 地址（握手期间稳定）
  reg [1:0]  word_valid_s;  // word_valid 的 2FF 同步（5→50）
  reg        word_ack;      // 读回握手 ack（电平，4 相位）

  // busy：P_BUSY 覆盖整个 SPI 读事务（op_start→op_done 全部落在 P_BUSY 内），
  // 供顶层 3 路 mux 选通 flash_mem_reader 的 SPI 引脚。P_DONE 进入前 op_done 已拉高、
  // spi_ctrl 已回到空闲（cs=1），故此时 busy 变低无碍（两边都是空闲态）。
  assign busy = (pstate == P_BUSY);

  // 内部采用 MSB-first 布局（cmd 在高字节），输出前做全 64bit 位反转。
  // 原因：spi_ctrl(cpol=0/cpha=0) 是 LSB-first（bit0 先发），反转后线上才是
  // cmd 在前、MSB-first，与 lcpu_sflash_core / spi_bootloader 对 TX 的处理一致。
  genvar gi;
  generate
    for (gi = 0; gi < 64; gi = gi + 1) begin : g_bit_reverse
      assign spi_wdata[gi] = spi_wdata_msb[63-gi];
    end
  endgenerate

  // ============================================================
  // 5MHz 域：SPI 读状态机（与 spi_ctrl 同域，op_done 同域直采）
  // ============================================================
  always @(posedge spi_clk or negedge reset_l) begin
    if (!reset_l) begin
      s5_state         <= S5_IDLE;
      start_req_s      <= 2'b0;
      start_ack        <= 1'b0;
      flash_addr_reg5  <= 24'd0;
      word_data        <= 32'd0;
      word_valid       <= 1'b0;
      word_ack_s       <= 2'b0;
      spi_op_start     <= 1'b0;
      spi_channel_len  <= 16'd0;
      spi_wdata_msb    <= 64'd0;
      gap_cnt          <= 3'd0;
      woke             <= 1'b0;
      wake_read        <= 1'b0;
    end else begin
      // 2FF 同步器
      start_req_s <= {start_req_s[0], start_req};
      word_ack_s  <= {word_ack_s[0],  word_ack};

      // 启动握手 ack：仅在 FSM 空闲（S5_IDLE）真正锁存数据后置 1；req 拉低后拉低。
      if (start_req_s[1]) begin
        if (s5_state == S5_IDLE) start_ack <= 1'b1;
      end else begin
        start_ack <= 1'b0;
      end

      // op_start 单拍脉冲：S5_CMD 置 1，下一拍默认清 0（与 spi_bootloader 同款）。
      spi_op_start <= 1'b0;

      case (s5_state)

        S5_IDLE: begin
          // start_req_s[1] 拉高时，addr_latch（50MHz 域）在握手期间保持稳定，可直接采样。
          if (start_req_s[1]) begin
            flash_addr_reg5 <= addr_latch;
            wake_read       <= !woke;   // 首次请求先做唤醒读
            s5_state        <= S5_CMD;
          end
        end

        S5_CMD: begin
          if (wake_read) begin
            // 唤醒读：读 JEDEC ID（0x9F），结果丢弃。flash 上电/复位后的第一次
            // 读会返回全 F（MISO 还没被驱动），需先做一次无意义的读把 flash 唤醒。
            spi_wdata_msb   <= {8'h9F, 56'd0};
            spi_channel_len <= 16'd32;  // 8 cmd + 24 data（JEDEC ID 3 字节）
          end else begin
            spi_wdata_msb[63:56] <= 8'h03;                  // Read Data 命令
            spi_wdata_msb[55:32] <= flash_addr_reg5[23:0];  // 24bit 源地址
            spi_wdata_msb[31:0]  <= 32'h0;
            spi_channel_len      <= 16'd64;                 // 8 cmd + 24 addr + 32 data
          end
          spi_op_start <= 1'b1;                   // 单拍脉冲
          s5_state     <= S5_WAIT_START;
        end

        S5_WAIT_START: begin
          // 等事务真正开始（op_done 拉低），防抓到旧 rdata。
          if (!spi_op_done) s5_state <= S5_WAIT_DONE;
        end

        S5_WAIT_DONE: begin
          // op_done 同域直采（无需 2FF）。拉高时 rdata 已稳定。
          if (spi_op_done) begin
            if (wake_read) begin
              woke      <= 1'b1;   // 唤醒读结果丢弃
              wake_read <= 1'b0;
              gap_cnt   <= 3'd0;
              s5_state  <= S5_GAP; // 回 GAP 后发真正读
            end else begin
              // 字节序修正：spi_rdata[31:24]=flash 低地址字节（线上 MSB-first），而
              // RISC-V 是小端。做全 32bit 字节交换，让 0x90000000 段呈现为小端内存
              // （CPU 读字/读字节都自然，flash[addr] 落在字节 0）。打包工具据此按
              // 「image[0] 放 word MSB」写入，见 pages_to_flash_tcl.py。
              word_data  <= {spi_rdata[7:0], spi_rdata[15:8], spi_rdata[23:16], spi_rdata[31:24]};
              word_valid <= 1'b1;
              s5_state   <= S5_PUSH;
            end
          end
        end

        S5_PUSH: begin
          // 等 50MHz 域确认收下（word_ack 2FF 同步后拉高）再放下 word_valid。
          if (word_ack_s[1]) begin
            word_valid <= 1'b0;
            s5_state   <= S5_NEXT;
          end
        end

        S5_NEXT: begin
          // 等 word_ack 放下，4 相位握手闭环后再回 idle 等下一次请求。
          if (!word_ack_s[1]) begin
            s5_state <= S5_IDLE;
          end
        end

        S5_GAP: begin
          // 字间空隙（冗余保险）。握手本身已保证 spi_ctrl 回到空闲（op_done=1）。
          if (gap_cnt >= GAP_CYCLES - 3'd1) s5_state <= S5_CMD;
          else gap_cnt <= gap_cnt + 3'd1;
        end

        default: s5_state <= S5_IDLE;
      endcase
    end
  end

  // ============================================================
  // 50MHz 域：请求捕获 + 结果握手（与 reg_webserver 同域）
  // ============================================================
  always @(posedge clk or negedge reset_l) begin
    if (!reset_l) begin
      pstate      <= P_IDLE;
      start_req   <= 1'b0;
      start_ack_s <= 2'b0;
      addr_latch  <= 24'd0;
      word_valid_s <= 2'b0;
      word_ack    <= 1'b0;
      rddata      <= 32'd0;
      op_ack      <= 1'b0;
    end else begin
      // 2FF 同步器
      start_ack_s  <= {start_ack_s[0],  start_ack};
      word_valid_s <= {word_valid_s[0], word_valid};

      op_ack <= 1'b0;  // default: pulse

      // ---- 启动握手（50→5）：start_req ----
      // op_req 单拍脉冲。上一读的 word_valid/word_ack 收尾还没回到 P_IDLE 时下一读可能已
      // 到来（固件连续读页面），只查 P_IDLE 会漏掉请求 → 读超时/卡死。故 P_DONE 也要响应
      // （对齐 spi_bootloader：P_IDLE 和 P_DONE 都响应 trigger）。
      if ((pstate == P_IDLE || pstate == P_DONE) && op_req && rhwl)
        start_req <= 1'b1;
      else if (start_ack_s[1])
        start_req <= 1'b0;

      // ---- 读回握手（5→50）：word_ack ----
      // word_valid 放下后无条件放 word_ack（4 相位闭环），与 pstate 无关（对齐 bootloader）。
      if (pstate == P_BUSY && word_valid_s[1] && !word_ack)
        word_ack <= 1'b1;
      else if (!word_valid_s[1])
        word_ack <= 1'b0;

      // ---- 请求/结果状态机 ----
      case (pstate)
        P_IDLE: begin
          if (op_req) begin
            if (rhwl) begin
              // 读：启动 SPI 读
              addr_latch <= address;
              pstate     <= P_BUSY;
            end else begin
              // 写：只读映射区，立即 ack 丢弃数据（防总线无人应答卡死）
              op_ack <= 1'b1;
              rddata <= 32'd0;
            end
          end
        end

        P_BUSY: begin
          if (word_valid_s[1] && !word_ack) begin
            op_ack <= 1'b1;
            rddata <= word_data;
            pstate <= P_DONE;
          end
        end

        P_DONE: begin
          // 上一读的 word_valid/word_ack 还没完全收尾时，下一读可能已到来（连续读页面），
          // 这里也要响应，否则单拍 op_req 被漏掉 → CPU 读超时。
          if (op_req) begin
            if (rhwl) begin
              addr_latch <= address;
              pstate     <= P_BUSY;
            end else begin
              op_ack <= 1'b1;
              rddata <= 32'd0;
            end
          end else if (!word_valid_s[1]) begin
            pstate <= P_IDLE;
          end
        end

        default: pstate <= P_IDLE;
      endcase
    end
  end
endmodule
