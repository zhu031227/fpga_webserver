// auto_boot — 上电自动加载固件到指令 RAM
//
// FPGA 配置完成后，延迟 DELAY_CYCLES 个周期，自动发一拍触发脉冲给 spi_bootloader，
// 把固件从 SPI Flash 0x400000 搬到指令 RAM。搬完（bootloader_status[1]=done）再释放
// RISC-V 复位，让 CPU 从地址 0 开始执行。
//
// auto_boot_active：上电即拉高，钳住 RISC-V 复位（防止指令 RAM 为空时 CPU 乱跑），
//   直到固件加载完成才拉低。顶层用它做：cpu_reset_l = riscv_reset_l & ~auto_boot_active。
// auto_boot_trigger：延迟后的一拍脉冲，与手工 WC 触发（bootloader_trigger_ind）相或，
//   两者都能触发 bootloader，互不干扰。
//
// 手工流程（Instruct_load2fpga.tcl）不受影响：auto_boot 只在 S_DONE 停留，不再重复触发。

module auto_boot #(
    parameter int DELAY_CYCLES = 5000000  // 上电延迟（50MHz 下 5M 拍 = 100ms）
) (
    input           clk,          // 50MHz
    input           reset_l,      // 系统复位（= reset_l_synced，PLL 锁定后才释放）
    input  [2:0]    bootloader_status,  // [0]=busy [1]=done [2]=error
    output reg      auto_boot_active,   // 1 = 自动加载进行中（钳 RISC-V 复位）
    output reg      auto_boot_trigger   // 1 拍脉冲，触发 bootloader
);

  localparam [1:0] S_DELAY   = 2'd0;
  localparam [1:0] S_TRIGGER = 2'd1;
  localparam [1:0] S_WAIT    = 2'd2;
  localparam [1:0] S_DONE    = 2'd3;

  reg [1:0]  state;
  reg [31:0] delay_cnt;
  reg [31:0] wait_cnt;   // 加载超时兜底，防止 bootloader 卡死导致 CPU 永久不复位

  // 加载超时：bootloader 读 ~20KB 固件约 100ms，给 2s 余量
  localparam [31:0] WAIT_TIMEOUT = 32'd100000000;  // 2s @ 50MHz

  always @(posedge clk or negedge reset_l) begin
    if (!reset_l) begin
      state            <= S_DELAY;
      delay_cnt        <= 32'd0;
      wait_cnt         <= 32'd0;
      auto_boot_active <= 1'b1;   // 上电即保持 RISC-V 复位
      auto_boot_trigger<= 1'b0;
    end else begin
      auto_boot_trigger <= 1'b0;  // default: 单拍脉冲

      case (state)
        S_DELAY: begin
          if (delay_cnt >= DELAY_CYCLES) begin
            state <= S_TRIGGER;
          end else begin
            delay_cnt <= delay_cnt + 32'd1;
          end
        end

        S_TRIGGER: begin
          auto_boot_trigger <= 1'b1;
          wait_cnt          <= 32'd0;
          state             <= S_WAIT;
        end

        S_WAIT: begin
          // done 或 error 都结束；超时兜底释放复位
          if (bootloader_status[1] || bootloader_status[2]) begin
            state <= S_DONE;
          end else if (wait_cnt >= WAIT_TIMEOUT) begin
            state <= S_DONE;
          end else begin
            wait_cnt <= wait_cnt + 32'd1;
          end
        end

        S_DONE: begin
          auto_boot_active <= 1'b0;   // 释放 RISC-V 复位
          // 保持 S_DONE，不重复触发
        end

        default: state <= S_DONE;
      endcase
    end
  end

endmodule
