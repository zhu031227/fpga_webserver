//-------------------------------------------------------------------
// vendor_stubs.sv — Behavioral stubs for iverilog simulation
//-------------------------------------------------------------------

// ===========================================================================
// Xilinx primitives
// ===========================================================================
module IDELAYCTRL (
    input REFCLK,
    RST
);
endmodule

module IDELAYE2 #(
    parameter CINVCTRL_SEL = "FALSE",
    DELAY_SRC = "IDATAIN",
    HIGH_PERFORMANCE_MODE = "TRUE",
    IDELAY_TYPE = "FIXED",
    IDELAY_VALUE = 0,
    PIPE_SEL = "FALSE",
    REFCLK_FREQUENCY = 200.0,
    SIGNAL_PATTERN = "DATA"
) (
    input IDATAIN,
    output DATAOUT,
    input C,
    CE,
    INC,
    LD,
    LDPIPEEN,
    input [4:0] CNTVALUEIN,
    output [4:0] CNTVALUEOUT
);
  assign DATAOUT = IDATAIN;
  assign CNTVALUEOUT = 5'd0;
endmodule

module IDDR #(
    parameter DDR_CLK_EDGE = "SAME_EDGE_PIPELINED",
    INIT_Q1 = 1'b0,
    INIT_Q2 = 1'b0,
    SRTYPE = "SYNC"
) (
    output reg Q1,
    Q2,
    input C,
    CE,
    D,
    R,
    S
);
  wire rst = (SRTYPE == "ASYNC") ? R : 1'b0;
  always @(posedge C or posedge rst)
    if (rst) Q1 <= INIT_Q1;
    else if (CE) Q1 <= D;
  always @(negedge C or posedge rst)
    if (rst) Q2 <= INIT_Q2;
    else if (CE) Q2 <= D;
endmodule

module ODDR #(
    parameter DDR_CLK_EDGE = "SAME_EDGE",
    INIT = 1'b0,
    SRTYPE = "SYNC"
) (
    output reg Q,
    input C,
    CE,
    D1,
    D2,
    R,
    S
);
  always @(posedge C or negedge C)
    if (C) Q <= D1;
    else Q <= D2;
endmodule

// ===========================================================================
// Behavioral RGMII
// ===========================================================================
module rgmii_rx #(
    parameter Xilinx_IDELAY_VALUE = 16,
    vendor = "Pango"
) (
    input reset_l,
    clk_200m,
    rgmii_rxc,
    rgmii_rx_ctl,
    input [3:0] rgmii_rxd,
    output gmii_rx_dv,
    output [7:0] gmii_rxd,
    output gmii_rx_clk,
    gmii_tx_clk_deg
);
  // SAME_EDGE_PIPELINED behavioral model — both nibbles output at posedge.
  //
  // RGMII DDR nibble timeline (testbench drives):
  //   posedge → low nibble  + dv
  //   negedge → high nibble + (dv ^ er)
  //
  // SAME_EDGE_PIPELINED (Xilinx UG471):
  //   - Capture low nibble at posedge into pos_cap
  //   - Capture high nibble at negedge into neg_cap
  //   - At NEXT posedge: output {neg_cap, pos_cap} = complete byte
  //   - Pipeline delay: 1.5 clock cycles (3 half-cycles)
  //   - gmii_rxd stable for full clock cycle at each posedge

  reg [3:0] pos_cap, neg_cap;  // internal capture
  reg ctl_cap;  // dv capture
  reg [3:0] rx_l, rx_h;  // output registers (both update on posedge)
  reg rx_ctl_d;

  always @(posedge rgmii_rxc) begin
    rx_l     <= pos_cap;  // low  nibble from previous posedge
    rx_h     <= neg_cap;  // high nibble from previous negedge
    rx_ctl_d <= ctl_cap;  // dv   from previous posedge
    pos_cap  <= rgmii_rxd;  // capture new low nibble
    ctl_cap  <= rgmii_rx_ctl;  // capture new dv
  end

  always @(negedge rgmii_rxc) begin
    neg_cap <= rgmii_rxd;  // capture new high nibble
  end

  assign gmii_rx_clk     = rgmii_rxc;
  assign gmii_rxd        = {rx_h, rx_l};
  assign gmii_rx_dv      = rx_ctl_d;
  assign gmii_tx_clk_deg = 1'b0;
endmodule

module rgmii_tx #(
    parameter vendor = "intel"
) (
    input reset_l,
    gmii_tx_er,
    gmii_tx_clk,
    gmii_tx_en,
    input [7:0] gmii_txd,
    input gmii_tx_clk_deg,
    output rgmii_txc,
    rgmii_tx_ctl,
    output [3:0] rgmii_txd
);
  reg [3:0] tx_d;
  reg tx_c;
  always @(posedge gmii_tx_clk) begin
    tx_d <= gmii_txd[3:0];
    tx_c <= gmii_tx_en;
  end
  always @(negedge gmii_tx_clk) begin
    tx_d <= gmii_txd[7:4];
    tx_c <= gmii_tx_en ^ gmii_tx_er;
  end
  assign rgmii_txc = ~gmii_tx_clk;
  assign rgmii_txd = tx_d;
  assign rgmii_tx_ctl = tx_c;
endmodule

module rgmii2gmii #(
    parameter xilinx_idelay_value = 16,
    vendor = "Pango"
) (
    input reset_l,
    clk_200m,
    gmii_tx_clk,
    gmii_tx_en,
    input [7:0] gmii_txd,
    input rgmii_rxc,
    rgmii_rx_ctl,
    input [3:0] rgmii_rxd,
    output gmii_rx_clk,
    gmii_rx_dv,
    output [7:0] gmii_rxd,
    output rgmii_txc,
    rgmii_tx_ctl,
    output [3:0] rgmii_txd
);
  wire dmy;
  rgmii_rx #(
      .Xilinx_IDELAY_VALUE(xilinx_idelay_value),
      .vendor(vendor)
  ) u_rx (
      .reset_l,
      .clk_200m,
      .rgmii_rxc,
      .rgmii_rx_ctl,
      .rgmii_rxd,
      .gmii_rx_dv,
      .gmii_rxd,
      .gmii_rx_clk,
      .gmii_tx_clk_deg(dmy)
  );
  rgmii_tx #(
      .vendor(vendor)
  ) u_tx (
      .reset_l,
      .gmii_tx_er(1'b0),
      .gmii_tx_clk,
      .gmii_tx_en,
      .gmii_txd,
      .gmii_tx_clk_deg(gmii_tx_clk),
      .rgmii_txc,
      .rgmii_tx_ctl,
      .rgmii_txd
  );
endmodule

// ===========================================================================
// simple_dual_port_ram (linkreal_common interface)
// ===========================================================================
module simple_dual_port_ram (
    aclk,
    aclk_en,
    awr_en,
    awr_addr,
    awr_data,
    bclk,
    bclk_en,
    brd_addr,
    brd_data
);
  parameter addr_width = 4, data_width = 8, ram_type = "registers";
  input aclk, aclk_en, awr_en;
  input [addr_width-1:0] awr_addr;
  input [data_width-1:0] awr_data;
  input bclk, bclk_en;
  input [addr_width-1:0] brd_addr;
  output reg [data_width-1:0] brd_data;

  reg [data_width-1:0] ram[0:(1<<addr_width)-1];
  integer i;
  initial for (i = 0; i < (1 << addr_width); i = i + 1) ram[i] = {data_width{1'b0}};

  always @(posedge aclk) if (aclk_en && awr_en) ram[awr_addr] <= awr_data;
  always @(posedge bclk) if (bclk_en) brd_data <= ram[brd_addr];
endmodule

// ===========================================================================
// single_clock_true_dual_port_ram_v2 (linkreal_common interface)
// ===========================================================================
module single_clock_true_dual_port_ram_v2 (
    clk,
    aclk_en,
    awr_en,
    aaddr,
    awr_data,
    ard_data,
    bclk_en,
    bwr_en,
    baddr,
    bwr_data,
    brd_data
);
  parameter addr_width = 4, data_width = 32, ram_type = "M9K";
  input clk, aclk_en, awr_en;
  input [addr_width-1:0] aaddr;
  input [data_width-1:0] awr_data;
  output reg [data_width-1:0] ard_data;
  input bclk_en, bwr_en;
  input [addr_width-1:0] baddr;
  input [data_width-1:0] bwr_data;
  output reg [data_width-1:0] brd_data;

  reg [data_width-1:0] ram[0:(1<<addr_width)-1];
  integer i;
  initial for (i = 0; i < (1 << addr_width); i = i + 1) ram[i] = {data_width{1'b0}};

  always @(posedge clk) begin
    if (aclk_en && awr_en) ram[aaddr] <= awr_data;
    ard_data <= ram[aaddr];
    if (bclk_en && bwr_en) ram[baddr] <= bwr_data;
    brd_data <= ram[baddr];
  end
endmodule

// ===========================================================================
// Xilinx XPM primitive
// ===========================================================================
module vendor_stubs #(
    parameter MEMORY_SIZE = 2048,
    MEMORY_PRIMITIVE = "block",
    CLOCKING_MODE = "common_clock",
    MEMORY_INIT_FILE = "none",
    MEMORY_INIT_PARAM = "",
    USE_MEM_INIT = 1,
    WAKEUP_TIME = "disable_sleep",
    MESSAGE_CONTROL = 0,
    ECC_MODE = "no_ecc",
    AUTO_SLEEP_TIME = 0,
    WRITE_DATA_WIDTH_A = 32,
    READ_DATA_WIDTH_A = 32,
    BYTE_WRITE_WIDTH_A = 32,
    ADDR_WIDTH_A = 10,
    READ_RESET_VALUE_A = "0",
    READ_LATENCY_A = 1,
    WRITE_DATA_WIDTH_B = 32,
    READ_DATA_WIDTH_B = 32,
    BYTE_WRITE_WIDTH_B = 32,
    ADDR_WIDTH_B = 10,
    READ_RESET_VALUE_B = "0",
    READ_LATENCY_B = 1,
    WRITE_MODE_A = "no_change",
    WRITE_MODE_B = "no_change",
    SIM_ASSERT_CHK = 0,
    MEMORY_OPTIMIZATION = "true",
    RST_MODE_A = "SYNC",
    RST_MODE_B = "SYNC",
    CASCADE_HEIGHT = 0,
    USE_EMBEDDED_CONSTRAINT = 0
) (
    input sleep,
    clka,
    rsta,
    ena,
    regcea,
    input [WRITE_DATA_WIDTH_A-1:0] dina,
    injectsbiterra,
    injectdbiterra,
    output reg [READ_DATA_WIDTH_A-1:0] douta,
    output sbiterra,
    dbiterra,
    input [ADDR_WIDTH_A-1:0] addra,
    input [BYTE_WRITE_WIDTH_A-1:0] wea,
    input clkb,
    rstb,
    enb,
    regceb,
    input [WRITE_DATA_WIDTH_B-1:0] dinb,
    injectsbiterrb,
    injectdbiterrb,
    output reg [READ_DATA_WIDTH_B-1:0] doutb,
    output sbiterrb,
    dbiterrb,
    input [ADDR_WIDTH_B-1:0] addrb,
    input [BYTE_WRITE_WIDTH_B-1:0] web
);
  localparam DEPTH = MEMORY_SIZE / WRITE_DATA_WIDTH_A;
  reg [WRITE_DATA_WIDTH_A-1:0] ram[0:DEPTH-1];
  integer i;
  initial for (i = 0; i < DEPTH; i = i + 1) ram[i] = {WRITE_DATA_WIDTH_A{1'b0}};
  always @(posedge clka) begin
    if (ena) begin
      if (wea) ram[addra] <= dina;
      douta <= ram[addra];
    end
  end
  always @(posedge clkb) begin
    if (enb) begin
      if (web) ram[addrb] <= dinb;
      doutb <= ram[addrb];
    end
  end
  assign sbiterra = 1'b0;
  assign dbiterra = 1'b0;
  assign sbiterrb = 1'b0;
  assign dbiterrb = 1'b0;
endmodule
