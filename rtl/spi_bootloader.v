// spi_bootloader — SPI Flash → InstructRAM firmware bootloader
//
// Triggered by WC register write. Reads firmware from SPI Flash and writes
// it word-by-word into the InstructRAM (via pram_* interface).
//
// 时钟域重构版（v411）：SPI 控制状态机搬到 5MHz 域（spi_clk），与 u_bl_spi(spi_ctrl)
// 同域，彻底消除 op_done 的 CDC 竞态。
//
// 旧版根因（v409）：op_start/op_done 在 50MHz 域、spi_ctrl 在 5MHz 域，而这个 5MHz
// （spi_clk_bl）是 clock_frequency_divider 从 50MHz 同步分频出来的 —— op_done 的
// 跳变沿恰好落在 50MHz 采样沿上，2FF 同步器在同步分频关系下采不可靠（op_done 拉高
// 采不进来，pram_wr 永远没脉冲）。ASYNC_REG 只是让 2FF 进同一 slice，不解决根本竞态。
//
// 两个时钟域，两个 4 相位电平握手：
//   50MHz(clk)       5MHz(spi_clk)
//   ---------        --------------
//   trigger ──start_req/start_ack(带 flash_addr+length)──▶ SPI 读状态机
//   pram 写 ◀─────word_valid/word_ack(带 32bit 读回字)───── op_done 同域直采
//
// 握手是标准 4 相位电平握手：多 bit 数据在 req/valid 拉高期间保持稳定，只对单 bit
// 控制线做 2FF 同步 —— 与 lcpu_sflash 的 lcpu_clock_cross 同款 idiom。

module spi_bootloader #(
    parameter int PRAM_ADDR_WIDTH = 15
) (
    input clk,          // 50MHz — pram 写 + status + trigger 捕获
    input spi_clk,      // 5MHz  — SPI 控制（与 u_bl_spi 同域，接 spi_clk_bl）
    input reset_l,

    // Control / status
    input             trigger,     // single-cycle pulse from WC register
    input      [31:0] flash_addr,  // Flash source byte address
    input      [31:0] length,      // Bytes to transfer (multiple of 4)
    output reg [ 2:0] status,      // [0]=busy, [1]=done, [2]=error

    // InstructRAM write port (muxed with LCPU pram path)
    output reg                       pram_wr,
    output reg [PRAM_ADDR_WIDTH-1:0] pram_addr,
    output reg [               31:0] pram_wdata,

    // SPI master interface (to spi_ctrl, 5MHz 域)
    output reg        spi_op_start,
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

  // 50MHz 域 pram 写状态机
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
  reg [31:0] flash_addr_reg5;
  reg [31:0] bytes_remaining5;
  reg [31:0] word_data;     // 读回字，word_valid 期间保持稳定
  reg        word_valid;    // 读回握手 valid（电平，4 相位）
  reg [1:0]  word_ack_s;    // word_ack 的 2FF 同步（50→5）
  reg [63:0] spi_wdata_msb; // [63:56]=cmd, [55:32]=addr, [31:0]=data
  reg [2:0]  gap_cnt;
  reg        dummy_read;   // 1 = 当前是"唤醒"读（JEDEC ID），读回结果丢弃

  // ============================================================
  // 50MHz 域寄存器
  // ============================================================
  reg [1:0]  pstate;
  reg        start_req;     // 启动握手 req（电平，4 相位）
  reg [1:0]  start_ack_s;   // start_ack 的 2FF 同步（5→50）
  reg [31:0] addr_latch;    // trigger 时锁存的 flash_addr（握手期间稳定）
  reg [31:0] len_latch;     // trigger 时锁存的 length
  reg [31:0] bytes_remaining;
  reg [PRAM_ADDR_WIDTH-1:0] pram_addr_reg;
  reg [1:0]  word_valid_s;  // word_valid 的 2FF 同步（5→50）
  reg        word_ack;      // 读回握手 ack（电平，4 相位）

  // 内部采用 MSB-first 布局（cmd 在高字节），输出前做全 64bit 位反转。
  // 原因：spi_ctrl(cpol=0/cpha=0) 是 LSB-first（bit0 先发），反转后线上才是
  // cmd 在前、MSB-first，与 lcpu_sflash_core 对 TX 的处理完全一致。
  genvar gi;
  generate
    for (gi = 0; gi < 64; gi = gi + 1) begin : g_bit_reverse
      assign spi_wdata[gi] = spi_wdata_msb[63-gi];
    end
  endgenerate

  // ============================================================
  // 5MHz 域：SPI 读状态机（与 u_bl_spi 同域，op_done 同域直采）
  // ============================================================
  always @(posedge spi_clk or negedge reset_l) begin
    if (!reset_l) begin
      s5_state         <= S5_IDLE;
      start_req_s      <= 2'b0;
      start_ack        <= 1'b0;
      flash_addr_reg5  <= 32'd0;
      bytes_remaining5 <= 32'd0;
      word_data        <= 32'd0;
      word_valid       <= 1'b0;
      word_ack_s       <= 2'b0;
      spi_op_start     <= 1'b0;
      spi_channel_len  <= 16'd0;
      spi_wdata_msb    <= 64'd0;
      gap_cnt          <= 3'd0;
      dummy_read       <= 1'b0;
    end else begin
      // 2FF 同步器
      start_req_s <= {start_req_s[0], start_req};
      word_ack_s  <= {word_ack_s[0],  word_ack};

      // 启动握手 ack：仅在 FSM 空闲（S5_IDLE）真正锁存数据后置 1；req 拉低后拉低。
      // 不能无条件跟随 start_req_s[1]：上一轮最后一字还没交接完（FSM 还在 S5_PUSH/
      // S5_NEXT）时新的 start_req 可能已到来；若 ack 无条件上提，start_req 会被提前
      // 拉低，FSM 回到 S5_IDLE 时已错过请求 —— 二次搬运（不重下 bitstream）就卡死在这。
      if (start_req_s[1]) begin
        if (s5_state == S5_IDLE) start_ack <= 1'b1;
      end else begin
        start_ack <= 1'b0;
      end

      // op_start 单拍脉冲：S5_CMD 置 1，下一拍默认清 0。
      // spi_ctrl 在 negedge 采 op_start 电平；同域下 1 拍（半周期后采样）足够稳定
      // 启动事务，且远早于 op_done 拉高，不会触发 spi_ctrl 的 restart（电平型重启）。
      spi_op_start <= 1'b0;

      case (s5_state)

        S5_IDLE: begin
          // start_req_s[1] 拉高时，addr_latch/len_latch（50MHz 域）在握手期间
          // 保持稳定，可直接采样。
          if (start_req_s[1]) begin
            flash_addr_reg5  <= addr_latch;
            bytes_remaining5 <= len_latch;
            dummy_read       <= 1'b1;   // 每次启动先做一次唤醒读
            s5_state         <= S5_CMD;
          end
        end

        S5_CMD: begin
          if (dummy_read) begin
            // 唤醒读：读 JEDEC ID（0x9F），结果丢弃。flash 上电/复位后的第一次
            // 读会返回全 F（MISO 还没被驱动），需先做一次无意义的读把 flash 唤醒，
            // 否则第 0 个字会写成 0xFFFFFFFF（上板实测）。
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
          // op_done 同域直采（无需 2FF）。拉高时 rdata 已稳定（最后一次 shift 在
          // op_done 拉高前一个 sck 沿完成）。
          if (spi_op_done) begin
            if (dummy_read) begin
              dummy_read <= 1'b0;   // 唤醒读结果丢弃，回 S5_GAP 后进入真正读
              gap_cnt    <= 3'd0;
              s5_state   <= S5_GAP;
            end else begin
              word_data  <= spi_rdata;
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
          // 等 word_ack 放下，4 相位握手闭环后再发下一字。
          if (!word_ack_s[1]) begin
            flash_addr_reg5  <= flash_addr_reg5 + 32'd4;
            bytes_remaining5 <= bytes_remaining5 - 32'd4;
            if (bytes_remaining5 == 32'd4) begin
              s5_state <= S5_IDLE;   // 最后一字读完，回 idle 等下一次 start_req
            end else begin
              gap_cnt  <= 3'd0;
              s5_state <= S5_GAP;
            end
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
  // 50MHz 域：pram 写状态机 + status（与 reg_webserver 同域）
  // ============================================================
  always @(posedge clk or negedge reset_l) begin
    if (!reset_l) begin
      pstate          <= P_IDLE;
      status          <= 3'b000;
      start_req       <= 1'b0;
      start_ack_s     <= 2'b0;
      addr_latch      <= 32'd0;
      len_latch       <= 32'd0;
      bytes_remaining <= 32'd0;
      pram_addr_reg   <= 0;
      word_valid_s    <= 2'b0;
      word_ack        <= 1'b0;
      pram_wr         <= 1'b0;
      pram_addr       <= 0;
      pram_wdata      <= 32'd0;
    end else begin
      // 2FF 同步器
      start_ack_s  <= {start_ack_s[0],  start_ack};
      word_valid_s <= {word_valid_s[0], word_valid};

      pram_wr <= 1'b0;  // default: pulse

      // ---- 启动握手（50→5）：start_req ----
      // trigger 单拍脉冲；start_ack_s[1] 拉高（5MHz 域已收到并锁存 addr/len）后放下。
      // P_IDLE（首次）和 P_DONE（搬运完成后再次触发）都要响应 trigger，支持不重下
      // bitstream 反复搬运。
      if ((pstate == P_IDLE || pstate == P_DONE) && trigger && length != 32'd0)
        start_req <= 1'b1;
      else if (start_ack_s[1])
        start_req <= 1'b0;

      // ---- 读回握手（5→50）：word_ack ----
      // word_valid_s[1] 拉高时 word_data（5MHz 域）已稳定；消费一个字后拉高 ack，
      // word_valid 放下后再放 ack（4 相位闭环，P_DONE 下也要能放 ack）。
      if (word_valid_s[1] && !word_ack && pstate == P_BUSY && bytes_remaining > 0)
        word_ack <= 1'b1;
      else if (!word_valid_s[1])
        word_ack <= 1'b0;

      case (pstate)

        P_IDLE: begin
          status <= 3'b000;
          if (trigger) begin
            if (length == 32'd0) begin
              status <= 3'b010;  // 空载直接 done
              pstate <= P_DONE;
            end else begin
              addr_latch      <= flash_addr;
              len_latch       <= length;
              bytes_remaining <= length;
              pram_addr_reg   <= 0;
              status          <= 3'b001;  // busy
              pstate          <= P_BUSY;
            end
          end
        end

        P_BUSY: begin
          if (word_valid_s[1] && !word_ack) begin
            pram_wr    <= 1'b1;
            pram_addr  <= pram_addr_reg;
            pram_wdata <= word_data;
            if (bytes_remaining == 32'd4) begin
              status <= 3'b010;  // done, stays until next trigger
              pstate <= P_DONE;
            end else begin
              bytes_remaining <= bytes_remaining - 32'd4;
              pram_addr_reg   <= pram_addr_reg + 1;
            end
          end
        end

        P_DONE: begin
          // 保持 done（status[1]=1），直到下一次 trigger 重新启动搬运 —— 支持
          // 不重下 bitstream 反复运行 Instruct_load2fpga.tcl。
          status <= 3'b010;
          if (trigger) begin
            if (length == 32'd0) begin
              status <= 3'b010;  // 空载保持 done
            end else begin
              addr_latch      <= flash_addr;
              len_latch       <= length;
              bytes_remaining <= length;
              pram_addr_reg   <= 0;
              status          <= 3'b001;  // busy
              pstate          <= P_BUSY;
            end
          end
        end

        default: pstate <= P_IDLE;
      endcase
    end
  end
endmodule
