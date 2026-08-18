// spi_bootloader — SPI Flash → InstructRAM firmware bootloader
//
// Triggered by WC register write. Reads firmware from SPI Flash and writes
// it word-by-word into the InstructRAM (via pram_* interface).
//
// Operation:
//   1. Wait for trigger pulse
//   2. Read flash word at flash_addr via spi_ctrl
//   3. Write word to pram, increment addresses
//   4. Repeat until length bytes transferred
//   5. Assert done; status[2]=error on failure
//
// op_start is held high until op_done (level-triggered), safe for CDC
// between 50MHz system clock and slower spi_clk (5MHz).

module spi_bootloader #(
    parameter int PRAM_ADDR_WIDTH = 15
) (
    input clk,
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

    // SPI master interface (to spi_ctrl, level-triggered op_start)
    output reg        spi_op_start,
    output reg [15:0] spi_channel_len,
    output     [63:0] spi_wdata,
    input      [31:0] spi_rdata,
    input             spi_op_done
);

  localparam S_IDLE = 3'd0;
  localparam S_READ_CMD = 3'd1;
  localparam S_READ_WAIT = 3'd2;
  localparam S_WRITE_PRAM = 3'd3;
  localparam S_NEXT = 3'd4;
  localparam S_DONE = 3'd5;
  localparam S_GAP  = 3'd6;
  localparam S_READ_START = 3'd7;

  reg [ 2:0] state;
  reg [31:0] flash_addr_reg;
  reg [31:0] bytes_remaining;
  reg [31:0] pram_addr_reg;
  reg [ 4:0] gap_cnt;
  reg [ 1:0] spi_op_done_s;  // spi_op_done 的 2FF 同步（5MHz -> 50MHz）

  // 内部采用 MSB-first 布局（cmd 在高字节），输出前做全 64bit 位反转。
  // 原因：spi_ctrl(cpol=0/cpha=0) 是 LSB-first（bit0 先发），反转后线上才是
  // cmd 在前、MSB-first，与 lcpu_sflash_core 对 TX 的处理完全一致。
  reg [63:0] spi_wdata_msb;   // [63:56]=cmd, [55:32]=addr, [31:0]=data

  genvar gi;
  generate
    for (gi = 0; gi < 64; gi = gi + 1) begin : g_bit_reverse
      assign spi_wdata[gi] = spi_wdata_msb[63-gi];
    end
  endgenerate

  // spi_op_done 是 5MHz(spi_clk_bl) 域信号：空闲保持高、事务中保持低、完成时
  // 是一个 200ns 窄脉冲。这里用 2FF 同步到 50MHz(clk) 域。
  // 不能用 pulse_clock_region_pass：它面向单周期脉冲，而 op_done 空闲是常高
  // 电平，会让 toggle 同步器反复翻转。
  always @(posedge clk or negedge reset_l) begin
    if (!reset_l) spi_op_done_s <= 2'b0;
    else          spi_op_done_s <= {spi_op_done_s[0], spi_op_done};
  end

  always @(posedge clk or negedge reset_l) begin
    if (!reset_l) begin
      state           <= S_IDLE;
      status          <= 3'b000;
      pram_wr         <= 1'b0;
      pram_addr       <= 0;
      pram_wdata      <= 32'b0;
      spi_op_start    <= 1'b0;
      spi_channel_len <= 16'd0;
      spi_wdata_msb   <= 64'd0;
      flash_addr_reg  <= 32'd0;
      bytes_remaining <= 32'd0;
      pram_addr_reg   <= 0;
      gap_cnt         <= 5'd0;
      spi_op_done_s   <= 2'b0;
    end else begin
      pram_wr <= 1'b0;  // default: pulse

      case (state)

        S_IDLE: begin
          status       <= 3'b000;
          spi_op_start <= 1'b0;
          if (trigger) begin
            flash_addr_reg <= flash_addr;
            bytes_remaining <= length;
            pram_addr_reg <= 0;
            state <= S_READ_CMD;
          end
        end

        S_READ_CMD: begin
          status[0]        <= 1'b1;  // busy
          spi_wdata_msb[63:56] <= 8'h03;
          spi_wdata_msb[55:32] <= flash_addr_reg[23:0];
          spi_wdata_msb[31:0]  <= 32'h0;
          spi_channel_len  <= 16'd64;  // 8 cmd + 24 addr + 32 data
          spi_op_start     <= 1'b1;  // hold until op_done (CDC-safe)
          state            <= S_READ_START;
        end

        S_READ_START: begin
          // 等 spi_ctrl 拉低 op_done（即检测到 op_start 上升沿、开始事务）。
          // op_start 在此期间保持为高，确保 5MHz 域能采到上升沿，
          // 否则 op_done 仍是上一次的电平，op_start 只高 20ns 就被清掉。
          if (!spi_op_done_s[1]) state <= S_READ_WAIT;
        end

        S_READ_WAIT: begin
          if (spi_op_done_s[1]) begin
            spi_op_start <= 1'b0;
            pram_wr      <= 1'b1;
            pram_addr    <= pram_addr_reg;
            pram_wdata   <= spi_rdata;
            state        <= S_WRITE_PRAM;
          end
        end

        S_WRITE_PRAM: begin
          flash_addr_reg <= flash_addr_reg + 4;
          pram_addr_reg <= pram_addr_reg + 1;
          bytes_remaining <= bytes_remaining - 4;
          state <= S_NEXT;
        end

        S_NEXT: begin
          if (bytes_remaining == 32'd0) state <= S_DONE;
          else begin
            state   <= S_GAP;
            gap_cnt <= 5'd0;
          end
        end

        S_GAP: begin
          // 保持 spi_op_start=0 足够久（>1 个 5MHz 周期），确保 spi_ctrl
          // 能检测到下一次 op_start 上升沿；否则 40ns 的低脉冲会被漏采，
          // 后续读会一直采到上一次的旧数据。
          if (gap_cnt >= 5'd20) state <= S_READ_CMD;
          else gap_cnt <= gap_cnt + 5'd1;
        end

        S_DONE: begin
          status <= 3'b010;  // done, stays until next trigger
        end

        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
