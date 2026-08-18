`timescale 1ns / 1ps
//==============================================================================
// tb_spi_bootloader — 验证 spi_bootloader + spi_ctrl 从 flash 读回的字正确
//
// 覆盖两个时钟域：bootloader @ 50MHz(clk_50m)，spi_ctrl @ 5MHz(clk_5m)。
// 重点验证 spi_ctrl 的 op_done 电平握手（op_start 上升沿启动、完成后保持高）。
//
// 4 个测试字（与 firmware_pads.bin 前 4 字一致）：
//   0x40D0006F, 0x47814701, 0x80018637, 0xCA584591
//==============================================================================

// ---- 最小 SPI flash 读模型：只支持 0x03 Read Data ----
module flash_model (
    input  cs_n,
    input  clk,
    input  mosi,
    output reg miso
);
  reg [7:0] mem [0:15];
  integer in_bits;      // 已收到的 bit 数（posedge 采样）
  integer tx_bit;       // 正在输出的数据 bit 索引
  reg [23:0] addr;
  reg tx_en;

  initial begin
    // 4 个测试字，big-endian 存储
    mem[0]=8'h40; mem[1]=8'hD0; mem[2]=8'h00; mem[3]=8'h6F; // 0x40D0006F
    mem[4]=8'h47; mem[5]=8'h81; mem[6]=8'h47; mem[7]=8'h01; // 0x47814701
    mem[8]=8'h80; mem[9]=8'h01; mem[10]=8'h86; mem[11]=8'h37;// 0x80018637
    mem[12]=8'hCA; mem[13]=8'h58; mem[14]=8'h45; mem[15]=8'h91;//0xCA584591
    in_bits = 0; tx_bit = 0; addr = 0; tx_en = 0; miso = 1'bz;
  end

  always @(negedge cs_n) begin
    in_bits = 0; tx_bit = 0; addr = 0; tx_en = 0; miso = 1'bz;
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

  // 下降沿输出数据（MSB first）
  always @(negedge clk) begin
    if (!cs_n && tx_en) begin
      miso   = mem[(addr + tx_bit/8) % 16][7 - (tx_bit%8)];
      tx_bit = tx_bit + 1;
    end else begin
      miso = 1'bz;
    end
  end
endmodule


module tb_spi_bootloader;

  // ---- 时钟 ----
  reg clk_50m = 0;
  reg clk_5m  = 0;
  always #10  clk_50m = ~clk_50m;   // 50MHz
  always #100 clk_5m  = ~clk_5m;    // 5MHz

  reg reset_l = 0;

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
      .clk(clk_50m), .reset_l(reset_l),
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
      .cs_n(cs), .clk(sck), .mosi(mosi), .miso(miso)
  );

  // ---- 期望值 & 校验 ----
  function [31:0] exp_word(input [3:0] i);
    case (i)
      0: exp_word = 32'h40D0006F;
      1: exp_word = 32'h47814701;
      2: exp_word = 32'h80018637;
      3: exp_word = 32'hCA584591;
      default: exp_word = 32'hDEADBEEF;
    endcase
  endfunction

  integer errors = 0;
  integer seen   = 0;
  always @(posedge clk_50m) begin
    if (reset_l && pram_wr) begin
      if (pram_addr < 4) begin
        if (pram_wdata !== exp_word(pram_addr[3:0])) begin
          $display("[%0t] ERROR pram[%0d]=0x%08X expect 0x%08X",
                   $time, pram_addr, pram_wdata, exp_word(pram_addr[3:0]));
          errors = errors + 1;
        end else begin
          $display("[%0t] OK    pram[%0d]=0x%08X", $time, pram_addr, pram_wdata);
        end
        seen = seen + 1;
      end
    end
  end

  // ---- 测试流程 ----
  integer t;
  initial begin
    trigger = 0; flash_addr = 32'h00000000; length = 32'd16; // 4 words
    repeat (5) @(posedge clk_50m);
    reset_l = 1;
    repeat (5) @(posedge clk_50m);

    // 单周期 trigger
    @(posedge clk_50m); trigger = 1;
    @(posedge clk_50m); trigger = 0;

    // 等 done/error，带超时
    t = 0;
    while (!(status[1] || status[2]) && t < 200000) begin
      @(posedge clk_50m);
      t = t + 1;
    end
    $display("[%0t] status=%b seen=%0d errors=%0d (timeout=%0d)", $time, status, seen, errors, (status[1]||status[2])?0:1);

    if (seen == 4 && errors == 0)
      $display("=== PASS ===");
    else
      $display("=== FAIL (seen=%0d errors=%0d) ===", seen, errors);

    #1000;
    $finish;
  end

endmodule
