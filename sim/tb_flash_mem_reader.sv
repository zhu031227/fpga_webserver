`timescale 1ns / 1ps
//==============================================================================
// tb_flash_mem_reader — 验证 flash_mem_reader（方案 B：0x90000000 内存映射只读）
//
// 覆盖：
//   1. 单字 0x03 Read Data 读回正确 + 32bit 字节交换（flash 呈现小端）；
//   2. start_req/start_ack + word_valid/word_ack 两个 4 相位握手跨域；
//   3. 首读唤醒（0x9F）丢弃结果后，真正读仍正确（flash_model 建模首读全 F）；
//   4. 写访问（rhwl=0）立即 ack、不改写 flash。
//
// 用法：iverilog ... -o x.vvp ; vvp x.vvp
//==============================================================================

// ---- 最小 SPI flash 读模型：只支持 0x03/0x9F，数据按地址确定性生成 ----
module flash_model (
    input  cs_n,
    input  clk,
    input  mosi,
    input  first_read_ff,   // 1 = 建模 flash 上电/复位后第一次读返回全 F
    output reg miso
);
  integer in_bits;
  integer tx_bit;
  reg [23:0] addr;
  reg tx_en;
  reg first_txn;
  reg this_txn_ff;

  function [7:0] data_byte(input [31:0] a);
    data_byte = (a * 8'h1F + 8'h07) & 8'hFF;   // 与 tb 内 data_byte 一致
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


module tb_flash_mem_reader;

  // ---- 时钟 ----
  reg clk_50m = 0;
  reg clk_5m  = 0;
  reg [3:0] clk_div = 0;
  always #10 clk_50m = ~clk_50m;             // 50MHz
  always @(posedge clk_50m) begin
    if (clk_div == 4'd4) begin
      clk_div  <= 0;
      clk_5m   <= ~clk_5m;
    end else begin
      clk_div <= clk_div + 1;
    end
  end

  reg reset_l = 0;
  reg first_read_ff = 0;

  // ---- flash_mem_reader 总线口 ----
  reg        op_req;
  reg        rhwl;
  reg [23:0] address;
  wire [31:0] rddata;
  wire        op_ack;
  wire        busy;

  // ---- flash_mem_reader -> spi_ctrl ----
  wire        spi_op_start;
  wire [15:0] spi_channel_len;
  wire [63:0] spi_wdata;
  wire [31:0] spi_rdata;
  wire        spi_op_done;

  // ---- SPI 总线 ----
  wire sck, cs, mosi, miso;

  flash_mem_reader u_fmr (
      .clk(clk_50m), .spi_clk(clk_5m), .reset_l(reset_l),
      .op_req(op_req), .rhwl(rhwl), .address(address),
      .rddata(rddata), .op_ack(op_ack), .busy(busy),
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

  // ---- 期望值 ----
  function [7:0] data_byte(input [31:0] a);
    data_byte = (a * 8'h1F + 8'h07) & 8'hFF;
  endfunction
  // flash_mem_reader 做了 32bit 字节交换：rddata = {data_byte(a+3),...,data_byte(a)}
  function [31:0] exp_word(input [31:0] a);
    exp_word = {data_byte(a+3), data_byte(a+2), data_byte(a+1), data_byte(a+0)};
  endfunction

  integer errors = 0;
  integer reads_checked = 0;
  reg [23:0] issued_addr;
  reg        check_read;   // 1 = 当前 op_ack 对应读，校验 rddata

  always @(posedge clk_50m) begin
    if (reset_l && op_ack) begin
      if (check_read) begin
        $display("[%0t] op_ack addr=0x%06X rddata=0x%08X (busy=%b)",
                 $time, issued_addr, rddata, busy);
        if (rddata !== exp_word(issued_addr)) begin
          $display("  ERROR addr 0x%06X: got 0x%08X expect 0x%08X",
                   issued_addr, rddata, exp_word(issued_addr));
          errors = errors + 1;
        end
        reads_checked = reads_checked + 1;
      end else begin
        // 写 ack：rddata 应为 0
        if (rddata !== 32'd0) begin
          $display("  ERROR write ack rddata=0x%08X expect 0", rddata);
          errors = errors + 1;
        end
        $display("[%0t] op_ack write (rddata=0x%08X)", $time, rddata);
      end
    end
  end

  // ---- 测试流程 ----
  task automatic do_read(input [23:0] addr);
    integer t;
    begin
      @(posedge clk_50m); op_req <= 1; rhwl <= 1; address <= addr;
      issued_addr <= addr; check_read <= 1;
      @(posedge clk_50m); op_req <= 0;
      // 等 op_ack（首读含唤醒 0x9F，约 96bit；单读 64bit≈640 个 50MHz 周期；超时留 5000）
      t = 0;
      while (!op_ack && t < 5000) begin
        @(posedge clk_50m); t = t + 1;
      end
      if (!op_ack) begin
        $display("  ERROR read 0x%06X: op_ack timeout", addr);
        errors = errors + 1;
      end
      check_read <= 0;
      // 等 word_valid/word_ack 握手收尾（~60 个 50MHz 周期）让 FSM 回 idle
      repeat (200) @(posedge clk_50m);
    end
  endtask

  task automatic do_write(input [23:0] addr);
    integer t;
    begin
      @(posedge clk_50m); op_req <= 1; rhwl <= 0; address <= addr;
      check_read <= 0;
      @(posedge clk_50m); op_req <= 0;
      t = 0;
      while (!op_ack && t < 20) begin
        @(posedge clk_50m); t = t + 1;
      end
      if (!op_ack) begin
        $display("  ERROR write 0x%06X: no immediate ack", addr);
        errors = errors + 1;
      end
      repeat (200) @(posedge clk_50m);
    end
  endtask

  integer t;
  initial begin
    first_read_ff = $test$plusargs("FLASH_FIRST_FF");
    op_req = 0; rhwl = 1; address = 0; check_read = 0; issued_addr = 0;

    repeat (5) @(posedge clk_50m);
    reset_l = 1;
    repeat (5) @(posedge clk_50m);

    $display("=== 读 0x420000（首读，含唤醒 0x9F）===");
    do_read(24'h420000);
    $display("=== 读 0x420004 ===");
    do_read(24'h420004);
    $display("=== 读 0x42ABCD（测 24bit 地址）===");
    do_read(24'h42ABCD);
    $display("=== 写 0x420000（应立即 ack，不改 flash）===");
    do_write(24'h420000);
    // 写后再读一次，确认 flash 未被改（仍返回原数据）
    $display("=== 写后重读 0x420000（确认未被改写）===");
    do_read(24'h420000);

    if (errors == 0 && reads_checked == 4)
      $display("=== PASS (4 reads checked, errors=%0d) ===", errors);
    else
      $display("=== FAIL (reads_checked=%0d errors=%0d) ===", reads_checked, errors);

    #1000;
    $finish;
  end

endmodule
