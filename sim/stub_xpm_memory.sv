//-------------------------------------------------------------------
// stub_xpm_memory.sv — Behavioral model of Xilinx XPM_MEMORY_TDPRAM
//
// Used for Verilator simulation only.  The Xilinx xpm_memory_tdpram
// is a vendor primitive; this provides a generic behavioral model.
//-------------------------------------------------------------------

module xpm_memory_tdpram #(
    parameter ADDR_WIDTH_A           = 10,
    parameter ADDR_WIDTH_B           = 10,
    parameter AUTO_SLEEP_TIME        = 0,
    parameter BYTE_WRITE_WIDTH_A     = 32,
    parameter BYTE_WRITE_WIDTH_B     = 32,
    parameter CASCADE_HEIGHT         = 0,
    parameter CLOCKING_MODE          = "common_clock",
    parameter ECC_MODE               = "no_ecc",
    parameter MEMORY_INIT_FILE       = "none",
    parameter MEMORY_INIT_PARAM      = "0",
    parameter MEMORY_OPTIMIZATION    = "true",
    parameter MEMORY_PRIMITIVE       = "block",
    parameter MEMORY_SIZE            = 32768,
    parameter MESSAGE_CONTROL        = 0,
    parameter READ_DATA_WIDTH_A      = 32,
    parameter READ_DATA_WIDTH_B      = 32,
    parameter READ_LATENCY_A         = 1,
    parameter READ_LATENCY_B         = 1,
    parameter READ_RESET_VALUE_A     = "0",
    parameter READ_RESET_VALUE_B     = "0",
    parameter RST_MODE_A             = "SYNC",
    parameter RST_MODE_B             = "SYNC",
    parameter SIM_ASSERT_CHK         = 0,
    parameter USE_EMBEDDED_CONSTRAINT = 0,
    parameter USE_MEM_INIT           = 0,
    parameter WAKEUP_TIME            = "disable_sleep",
    parameter WRITE_DATA_WIDTH_A     = 32,
    parameter WRITE_DATA_WIDTH_B     = 32,
    parameter WRITE_MODE_A           = "read_first",
    parameter WRITE_MODE_B           = "read_first"
) (
    input  sleep,
    input  clka,
    input  rsta,
    input  ena,
    input  regcea,
    input  [WRITE_DATA_WIDTH_A-1:0]  dina,
    input  injectsbiterra,
    input  injectdbiterra,
    output [READ_DATA_WIDTH_A-1:0]   douta,
    output sbiterra,
    output dbiterra,
    input  [ADDR_WIDTH_A-1:0]        addra,
    input  [WRITE_DATA_WIDTH_A-1:0]  wea,
    input  clkb,
    input  rstb,
    input  enb,
    input  regceb,
    input  [WRITE_DATA_WIDTH_B-1:0]  dinb,
    input  injectsbiterrb,
    input  injectdbiterrb,
    output [READ_DATA_WIDTH_B-1:0]   doutb,
    output sbiterrb,
    output dbiterrb,
    input  [ADDR_WIDTH_B-1:0]        addrb,
    input  [WRITE_DATA_WIDTH_B-1:0]  web
);

  localparam DEPTH_A = MEMORY_SIZE / WRITE_DATA_WIDTH_A;
  localparam DEPTH_B = MEMORY_SIZE / WRITE_DATA_WIDTH_B;

  reg [WRITE_DATA_WIDTH_A-1:0] ram [0:DEPTH_A-1];

  reg [READ_DATA_WIDTH_A-1:0] douta_r;
  reg [READ_DATA_WIDTH_B-1:0] doutb_r;

  always @(posedge clka) begin
    if (ena) begin
      if (|wea) ram[addra] <= dina;
      douta_r <= ram[addra];
    end
  end

  always @(posedge clkb) begin
    if (enb) begin
      if (|web) ram[addrb] <= dinb;
      doutb_r <= ram[addrb];
    end
  end

  assign douta    = douta_r;
  assign doutb    = doutb_r;
  assign sbiterra = 1'b0;
  assign dbiterra = 1'b0;
  assign sbiterrb = 1'b0;
  assign dbiterrb = 1'b0;

endmodule
