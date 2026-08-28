`timescale 1ns / 1ps
//==============================================================================
// tb_spi_bootloader — 验证 spi_bootloader 双时钟域重构（v411）
//
// 覆盖两个时钟域：bootloader pram 写 @ 50MHz(clk_50m)，SPI 读状态机 @ 5MHz(clk_5m)。
// 5MHz 由 50MHz 分频得到（与真实 spi_clk_bl 一致）。重点验证：
//   1. SPI 控制搬到 5MHz 域后 op_done 同域直采，读回字正确；
//   2. word_valid/word_ack + start_req/start_ack 两个 4 相位握手跨域正确。
//
// 用法：
//   4 字 smoke：  vvp x.vvp
//   N 字 full：   vvp x.vvp +NUM_WORDS=5980
//
// flash_model 按字节地址生成确定性数据 data_byte(a) = (a*31+7) & 0xFF，
// 支持全地址范围（旧版只有 16 字节 mem 取模）。
//==============================================================================

// ---- 最小 SPI flash 读模型：只支持 0x03 Read Data，数据按地址确定性生成 ----
module flash_model (
    input  cs_n,
    input  clk,
    input  mosi,
    input  first_read_ff,   // 1 = 建模 flash 上电/复位后第一次读返回全 F
    output reg miso
);
  integer in_bits;      // 已收到的 bit 数（posedge 采样）
  integer tx_bit;       // 正在输出的数据 bit 索引
  reg [23:0] addr;
  reg tx_en;
  reg first_txn;        // 是否是复位后的第一次事务
  reg this_txn_ff;      // 当前事务是否返回全 F

  function [7:0] data_byte(input [31:0] a);
    data_byte = (a * 8'h1F + 8'h07) & 8'hFF;   // 与 tb 内 exp_word 公式一致
  endfunction

  initial begin
    in_bits = 0; tx_bit = 0; addr = 0; tx_en = 0; miso = 1'bz;
    first_txn = 1; this_txn_ff = 0;
  end

  always @(negedge cs_n) begin
    in_bits = 0; tx_bit = 0; addr = 0; tx_en = 0; miso = 1'bz;
    this_txn_ff = first_read_ff && first_txn;  // 第一次事务返回全 F，之后正常
    first_txn   = 0;
  end

  // 采样 MOSI（命令 + 地址），地址收满后开启数据输出
  always @(posedge clk) begin
    if (!cs_n) begin
      if (in_bits >= 8 && in_bits < 32)
        addr = {addr[22:0], mosi};
      if (in_bits == 31) begin
        tx_en  = 1;
        tx_bit = 0;
      end
      in_bits = in_bits + 1;
    end
  end

  // 下降沿输出数据（MSB first），数据按字节地址生成
  reg [7:0] cur_byte;
  always @(negedge clk) begin
    if (!cs_n && tx_en) begin
      if (this_txn_ff) begin
        miso = 1'b1;  // 全 F（flash 未驱动，MISO 浮高）
      end else begin
        cur_byte = data_byte(addr + (tx_bit/8));
        miso     = cur_byte[7 - (tx_bit%8)];
      end
      tx_bit   = tx_bit + 1;
    end else begin
      miso = 1'bz;
    end
  end
endmodule


module tb_spi_bootloader;

  // ---- 时钟 ----
  // 50MHz 系统时钟。5MHz 两种生成方式（wire mux 二选一）：
  //   默认：由 50MHz 同步分频（与真实 spi_clk_bl 一致，锁相）；
  //   +INDEP_5M：独立自由振荡（~5.15MHz，与 50MHz 相位漂移），验证 4 相位握手
  //   对相位关系不敏感 —— 这正是本次重构要消灭的竞态类别。
  reg clk_50m = 0;
  reg clk_5m_der  = 0;
  reg clk_5m_free = 0;
  reg [3:0] clk_div = 0;
  int  indep_5m = 0;
  wire clk_5m = indep_5m ? clk_5m_free : clk_5m_der;

  always #10 clk_50m = ~clk_50m;             // 50MHz
  always #97 clk_5m_free = ~clk_5m_free;     // 独立 ~5.15MHz（194ns 周期，非 50MHz 整数倍）
  always @(posedge clk_50m) begin
    if (clk_div == 4'd4) begin
      clk_div <= 0;
      clk_5m_der <= ~clk_5m_der;
    end else begin
      clk_div <= clk_div + 1;
    end
  end

  reg reset_l = 0;
  reg first_read_ff = 0;   // +FLASH_FIRST_FF：建模 flash 复位后首读返回全 F

  // ---- bootloader 控制 ----
  reg        trigger;
  reg [31:0] flash_addr;
  reg [31:0] length;
  wire [2:0] status;

  // ---- bootloader -> spi_ctrl ----
  wire        spi_op_start;
  wire [15:0] spi_channel_len;
  wire [63:0] spi_wdata;
  wire [31:0] spi_rdata;
  wire        spi_op_done;

  // ---- pram 写口 ----
  wire        pram_wr;
  wire [14:0] pram_addr;
  wire [31:0] pram_wdata;

  // ---- SPI 总线 ----
  wire sck, cs, mosi, miso;

  spi_bootloader #(.PRAM_ADDR_WIDTH(15)) u_boot (
      .clk(clk_50m), .spi_clk(clk_5m), .reset_l(reset_l),
      .trigger(trigger), .flash_addr(flash_addr), .length(length),
      .status(status),
      .pram_wr(pram_wr), .pram_addr(pram_addr), .pram_wdata(pram_wdata),
      .spi_op_start(spi_op_start), .spi_channel_len(spi_channel_len),
      .spi_wdata(spi_wdata), .spi_rdata(spi_rdata), .spi_op_done(spi_op_done)
  );

  spi_ctrl #(.cpol(0), .cpha(0)) u_spi (
      .reset_l(reset_l), .clk(clk_5m),
      .op_start(spi_op_start), .channel_len(spi_channel_len), .wdata(spi_wdata),
      .rdata(spi_rdata), .op_done(spi_op_done),
      .sck(sck), .cs(cs), .mosi(mosi), .miso(miso)
  );

  flash_model u_flash (
      .cs_n(cs), .clk(sck), .mosi(mosi), .miso(miso), .first_read_ff(first_read_ff)
  );

  // ---- 期望值 & 校验 ----
  // 与 flash_model.data_byte 公式一致：data_byte(a) = (a*31+7) & 0xFF
  function [7:0] data_byte(input [31:0] a);
    data_byte = (a * 8'h1F + 8'h07) & 8'hFF;
  endfunction
  function [31:0] exp_word(input [31:0] i);  // i = 字索引
    exp_word = {data_byte(i*4+0), data_byte(i*4+1), data_byte(i*4+2), data_byte(i*4+3)};
  endfunction

  int num_words = 4;       // 默认 smoke 4 字；可用 +NUM_WORDS=5980 覆盖
  integer errors = 0;
  integer seen   = 0;

  always @(posedge clk_50m) begin
    if (reset_l && pram_wr) begin
      if (pram_addr < num_words) begin
        if (pram_wdata !== exp_word(pram_addr)) begin
          $display("[%0t] ERROR pram[%0d]=0x%08X expect 0x%08X",
                   $time, pram_addr, pram_wdata, exp_word(pram_addr));
          errors = errors + 1;
        end else if (num_words <= 8) begin
          $display("[%0t] OK    pram[%0d]=0x%08X", $time, pram_addr, pram_wdata);
        end
        seen = seen + 1;
      end
    end
  end

  // ---- 测试流程 ----
  integer t;
  integer run;
  int num_runs = 1;   // 默认 1 次；+RUNS=N 验证重复 trigger（不重下 bitstream 反复搬运）
  initial begin
    indep_5m = $test$plusargs("INDEP_5M");
    first_read_ff = $test$plusargs("FLASH_FIRST_FF");
    if (!$value$plusargs("NUM_WORDS=%d", num_words)) num_words = 4;
    if (!$value$plusargs("RUNS=%d", num_runs)) num_runs = 1;

    trigger = 0; flash_addr = 32'h00000000;
    repeat (5) @(posedge clk_50m);
    reset_l = 1;
    repeat (5) @(posedge clk_50m);

    length = num_words * 4;

    for (run = 0; run < num_runs; run = run + 1) begin
      // 单周期 trigger（非阻塞驱动，DUT 在下一 posedge 稳定采到高电平）
      @(posedge clk_50m); trigger <= 1;
      @(posedge clk_50m); trigger <= 0;
      @(posedge clk_50m); // 让 trigger 生效进入 busy：re-trigger 时 status[1] 可能还是
                          // 上一次的 done，需等一拍，否则误判“已经完成”直接跳过等待

      // 等 done/error，带超时（每字约 640 个 50MHz 周期，超时留 3 倍余量）
      t = 0;
      while (!(status[1] || status[2]) && t < num_words * 2000) begin
        @(posedge clk_50m);
        t = t + 1;
      end
      // done 与最后一字 pram_wr 同拍置起，多等几拍让 monitor 把 seen 补到最终值
      repeat (4) @(posedge clk_50m);
      $display("[%0t] run=%0d status=%b seen=%0d errors=%0d (timeout=%0d)",
               $time, run, status, seen, errors, (status[1]||status[2])?0:1);
    end

    if (seen == num_runs * num_words && errors == 0 && status[1])
      $display("=== PASS (%0d runs x %0d words) ===", num_runs, num_words);
    else
      $display("=== FAIL (seen=%0d expected=%0d errors=%0d status=%b) ===",
               seen, num_runs * num_words, errors, status);

    #1000;
    $finish;
  end

endmodule
