`timescale 1ns / 1ps
//==============================================================================
// tb_flash_mem_reader_bb — 回归测试：背靠背连续读（修复 re-arm 漏请求 bug）
//
// 场景：固件连续读页面（TOC 查表命中后 ct/off/len 连续读）时，读 1 ack 之后、
// 读 2 可能在前一读的 word_valid/word_ack 收尾回到 P_IDLE 之前（~40 个 50MHz 周期
// 的重锁窗口内）到来。旧代码只在 pstate==P_IDLE 响应 op_req，会漏掉这个单拍请求 →
// CPU 读超时。修复后 P_DONE 也响应 op_req。
//
// 用法：iverilog -g2012 -s tb_flash_mem_reader_bb -o x.vvp \
//         -I rtl -I ../ip_common/rtl -I ../ip_common/sim/bfm \
//         sim/tb_flash_mem_reader_bb.sv rtl/flash_mem_reader.v \
//         ../ip_common/rtl/spi_ctrl.v ../ip_common/sim/bfm/w25q32_bfm.sv
//       vvp x.vvp
//==============================================================================

module flash_model_bb (
    input  cs_n,
    input  clk,
    input  mosi,
    output reg miso
);
  integer in_bits;
  integer tx_bit;
  reg [23:0] addr;
  reg tx_en;

  function [7:0] data_byte(input [31:0] a);
    data_byte = (a * 8'h1F + 8'h07) & 8'hFF;
  endfunction

  initial begin
    in_bits = 0; tx_bit = 0; addr = 0; tx_en = 0; miso = 1'bz;
  end

  always @(negedge cs_n) begin
    in_bits = 0; tx_bit = 0; addr = 0; tx_en = 0; miso = 1'bz;
  end

  always @(posedge clk) begin
    if (!cs_n) begin
      if (in_bits >= 8 && in_bits < 32) addr = {addr[22:0], mosi};
      if (in_bits == 31) begin tx_en = 1; tx_bit = 0; end
      in_bits = in_bits + 1;
    end
  end

  reg [7:0] cur_byte;
  always @(negedge clk) begin
    if (!cs_n && tx_en) begin
      cur_byte = data_byte(addr + (tx_bit/8));
      miso = cur_byte[7 - (tx_bit%8)];
      tx_bit = tx_bit + 1;
    end else begin
      miso = 1'bz;
    end
  end
endmodule


module tb_flash_mem_reader_bb;

  reg clk_50m = 0;
  reg clk_5m  = 0;
  reg [3:0] clk_div = 0;
  always #10 clk_50m = ~clk_50m;
  always @(posedge clk_50m) begin
    if (clk_div == 4'd4) begin clk_div <= 0; clk_5m <= ~clk_5m; end
    else clk_div <= clk_div + 1;
  end

  reg reset_l = 0;
  reg op_req;
  reg rhwl;
  reg [23:0] address;
  wire [31:0] rddata;
  wire op_ack;
  wire busy;

  wire spi_op_start;
  wire [15:0] spi_channel_len;
  wire [63:0] spi_wdata;
  wire [31:0] spi_rdata;
  wire spi_op_done;

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

  flash_model_bb u_flash (.cs_n(cs), .clk(sck), .mosi(mosi), .miso(miso));

  function [7:0] data_byte(input [31:0] a);
    data_byte = (a * 8'h1F + 8'h07) & 8'hFF;
  endfunction
  function [31:0] exp_word(input [31:0] a);
    exp_word = {data_byte(a+3), data_byte(a+2), data_byte(a+1), data_byte(a+0)};
  endfunction

  integer errors = 0;
  integer ack_cnt = 0;
  reg [23:0] issued_addr [0:3];

  // 每个 op_ack 校验 rddata 是否等于对应地址的期望值
  always @(posedge clk_50m) begin
    if (reset_l && op_ack) begin
      if (rddata !== exp_word(issued_addr[ack_cnt])) begin
        $display("  ERROR ack#%0d addr=0x%06X got=0x%08X expect=0x%08X",
                 ack_cnt, issued_addr[ack_cnt], rddata, exp_word(issued_addr[ack_cnt]));
        errors = errors + 1;
      end else begin
        $display("  [%0t] ack#%0d addr=0x%06X rddata=0x%08X OK", $time, ack_cnt, issued_addr[ack_cnt], rddata);
      end
      ack_cnt = ack_cnt + 1;
    end
  end

  // 发一次读，不等待重锁窗口（调用方控制下一笔的间隔）
  task automatic fire_read(input [23:0] addr);
    begin
      @(posedge clk_50m); op_req <= 1; rhwl <= 1; address <= addr;
      @(posedge clk_50m); op_req <= 0;
    end
  endtask

  integer t;
  integer expect_acks;

  initial begin
    op_req = 0; rhwl = 1; address = 0;
    for (t = 0; t < 4; t = t + 1) issued_addr[t] = 0;
    repeat (5) @(posedge clk_50m);
    reset_l = 1;
    repeat (5) @(posedge clk_50m);

    // 背靠背连续读：每笔 ack 之后、在前一读的 word_valid/word_ack 收尾回到 P_IDLE 之前
    // （~40 拍重锁窗口内）立刻发下一笔，模拟固件连续读页面（TOC 查表命中后 ct/off/len）。
    // 旧代码只查 P_IDLE 会漏掉第 2/3/4 笔；修复后 P_DONE 也响应，4 笔都应正确 ack。
    issued_addr[0] = 24'h420000;
    issued_addr[1] = 24'h420004;
    issued_addr[2] = 24'h420008;
    issued_addr[3] = 24'h42000C;

    for (t = 0; t < 4; t = t + 1) begin
      fire_read(issued_addr[t]);
      // 等本笔 ack（带超时，漏掉会触发 $fatal）
      expect_acks = t + 1;
      begin : wait_ack
        integer wt;
        wt = 0;
        while (ack_cnt < expect_acks) begin
          @(posedge clk_50m); wt = wt + 1;
          if (wt > 20000) begin
            $display("  ERROR 第 %0d 笔 ack 超时（请求被漏掉）", t);
            $fatal(1, "request missed");
          end
        end
      end
      // ack 后 5 拍（< 重锁 ~40 拍）内发下一笔
      if (t < 3) repeat (5) @(posedge clk_50m);
    end

    if (ack_cnt < expect_acks) begin
      $display("  ERROR 只收到 %0d/%0d 个 ack（有请求被漏掉/超时）", ack_cnt, expect_acks);
      errors = errors + 1;
    end

    if (errors == 0)
      $display("=== PASS (back-to-back 4 reads, ack_cnt=%0d, errors=0) ===", ack_cnt);
    else
      $display("=== FAIL (ack_cnt=%0d errors=%0d) ===", ack_cnt, errors);

    #1000;
    $finish;
  end

endmodule
