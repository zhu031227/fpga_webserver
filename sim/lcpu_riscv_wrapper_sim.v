module lcpu_riscv_wrapper_sim #(
    parameter sim_mod = 0,
    parameter script_file = "../tcl/InstructRAM.tcl",

    parameter lcpu_type = "xilinx",  //"intel";	"xilinx"; "uart"
    parameter uart_baud_rate = 115200,

    parameter riscv_inst_en = 1,
    parameter instr_databits = 32,
    parameter init_addr_width = 13,
    parameter init_addr_depth = 8192,
    parameter device_vendor = "",  //"intel";	"xilinx"; ""
    parameter instr_ram_type = "M4K",  /* "registers" ; "M4K" */
    parameter init_blockram_size = 32,
    parameter enable_irq = 0,
    parameter enable_irq_qregs = 1,
    parameter progaddr_irq = 16
) (
    input clk,
    input reset_l,

    input  uart_rx,
    output uart_tx,

    // RISC-V reset control (from outside)
    input                        riscv_reset_l,
    // unified program RAM interface (shared by riscv32_top and cpu_reg)
    input                        pram_wr,
    input  [init_addr_width-1:0] pram_addr,
    input  [ instr_databits-1:0] pram_wdata,
    output [ instr_databits-1:0] pram_rdata,
    // Merged bus (to/from external)
    output                       req,
    output                       rhwl,
    output [               31:0] wdata,
    output [               31:0] address,
    input                        ack,
    input  [               31:0] rdata
);

  wire        jtag_req;
  wire        jtag_rhwl;
  wire [31:0] jtag_wdata;
  wire [31:0] jtag_address;
  wire [31:0] jtag_rdata;
  wire        jtag_ack;

  wire        riscv_req;
  wire        riscv_rhwl;
  wire [31:0] riscv_wdata;
  wire [31:0] riscv_address;
  wire [31:0] riscv_rdata;
  wire        riscv_ack;
  wire [31:0] riscv_address_s;

  // LCPU / JTAG master: real hardware or simulation BFM
  generate
    if (sim_mod == 0) begin : lcpu_real
      lcpu_top #(
          .lcpu_vendor(lcpu_type),
          .device_vendor(device_vendor),
          .uart_baud_rate(uart_baud_rate)
      ) u_cpu (
          .clk    (clk),
          .reset_l(reset_l),
          .uart_rx(uart_rx),
          .uart_tx(uart_tx),

          .jtag_rhwl  (jtag_rhwl),
          .jtag_req   (jtag_req),
          .jtag_ack   (jtag_ack),
          .jtag_address (jtag_address),
          .jtag_wdata  (jtag_wdata),
          .jtag_rdata  (jtag_rdata)
      );
    end else begin : lcpu_sim
      lcpu_bfm #(
          .read_time_out(2000),
          .delay_time   (1000),
          .script_file  (script_file)
      ) u_lcpu_bfm (
          .clk    (clk),
          .reset_l(reset_l),
          .OP_DONE(jtag_ack),
          .RD_DATA(jtag_rdata),
          .ADDRESS(jtag_address),
          .WR_DATA(jtag_wdata),
          .RH_WL  (jtag_rhwl),
          .EXEC   (jtag_req)
      );
      assign uart_tx = 1'b1;
    end
  endgenerate

  generate
    if (riscv_inst_en == 1) begin : riscv_cpu_generation
      riscv32_top #(
          .instr_databits    (instr_databits),
          .instr_ram_type    (instr_ram_type),
          .init_addr_width   (init_addr_width),
          .init_addr_depth   (init_addr_depth),
          .init_blockram_size(init_blockram_size),
          .vendor            (device_vendor),
          .enable_irq        (enable_irq),
          .enable_irq_qregs  (enable_irq_qregs),
          .progaddr_irq      (progaddr_irq)
      ) u_riscv_cpu (
          .clk          (clk),
          .reset_l      (riscv_reset_l),
          .req          (riscv_req),
          .rhwl         (riscv_rhwl),
          .wr_byte_en   (),
          .wdata        (riscv_wdata),
          .address      (riscv_address),
          .rdata        (riscv_rdata),
          .ack          (riscv_ack),
          .program_wr   (pram_wr),
          .program_waddr(pram_addr[init_addr_width-1:0]),
          .program_wdata(pram_wdata),
          .program_rdata(pram_rdata),
          .irq          (32'b0)
      );

    end else begin : riscv_cpu_disabled
      assign riscv_req     = 1'b0;
      assign riscv_rhwl    = 1'b0;
      assign riscv_wdata   = 32'b0;
      assign riscv_address = 32'b0;
      assign riscv_ack     = 1'b0;
      assign riscv_rdata   = 32'b0;
    end
  endgenerate


  lcpu_merge #(
      .addr_width(32),
      .data_width(32)
  ) u_lcpu_merge (
      .reset_l(reset_l),
      .clk    (clk),

      // Port 1: JTAG
      .op_req_1 (jtag_req),
      .wrl_rdh_1(jtag_rhwl),
      .wrdata_1 (jtag_wdata),
      .address_1(jtag_address),
      .op_ack_1 (jtag_ack),
      .rddata_1 (jtag_rdata),

      // Port 2: RISC-V
      .op_req_2 (riscv_req),
      .wrl_rdh_2(riscv_rhwl),
      .wrdata_2 (riscv_wdata),
      .address_2(riscv_address),
      .op_ack_2 (riscv_ack),
      .rddata_2 (riscv_rdata),

      // Merged output
      .op_req (req),
      .wrl_rdh(rhwl),
      .wrdata (wdata),
      .address(address),
      .op_ack (ack),
      .rddata (rdata)
  );
endmodule
