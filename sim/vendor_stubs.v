// ============================================================================
// vendor_stubs.v — Behavioral stubs for FPGA vendor primitives
// ============================================================================
// Replaces Xilinx/Altera/Gowin/Pango primitives that are not available
// in iverilog. These stubs provide functionally equivalent behavior
// for RTL simulation.

// ============================================================================
// Xilinx 7-Series Unisim Primitives
// ============================================================================

// IDDR: Dedicated Dual Data Rate Input Register
module IDDR #(
    parameter DDR_CLK_EDGE = "SAME_EDGE_PIPELINED",
    parameter INIT_Q1 = 1'b0,
    parameter INIT_Q2 = 1'b0,
    parameter SRTYPE = "SYNC"
) (
    output reg Q1,
    output reg Q2,
    input      C,
    input      CE,
    input      D,
    input      R,
    input      S
);
    wire async_rst, async_set;
    wire sync_rst,  sync_set;

    assign async_rst = (SRTYPE == "ASYNC") ? R : 1'b0;
    assign async_set = (SRTYPE == "ASYNC") ? S : 1'b0;
    assign sync_rst  = (SRTYPE == "SYNC" ) ? R : 1'b0;
    assign sync_set  = (SRTYPE == "SYNC" ) ? S : 1'b0;

    always @(posedge C, posedge async_rst, posedge async_set) begin
        if (async_rst)
            Q1 <= 1'b0;
        else if (async_set)
            Q1 <= 1'b1;
        else if (CE) begin
            if (sync_rst)
                Q1 <= 1'b0;
            else if (sync_set)
                Q1 <= 1'b1;
            else
                Q1 <= D;
        end
    end

    always @(negedge C, posedge async_rst, posedge async_set) begin
        if (async_rst)
            Q2 <= 1'b0;
        else if (async_set)
            Q2 <= 1'b1;
        else if (CE) begin
            if (sync_rst)
                Q2 <= 1'b0;
            else if (sync_set)
                Q2 <= 1'b1;
            else
                Q2 <= D;
        end
    end
endmodule

// ODDR: Dedicated Dual Data Rate Output Register
module ODDR #(
    parameter DDR_CLK_EDGE = "SAME_EDGE",
    parameter INIT = 1'b0,
    parameter SRTYPE = "SYNC"
) (
    output reg Q,
    input      C,
    input      CE,
    input      D1,
    input      D2,
    input      R,
    input      S
);
    wire async_rst, async_set;
    wire sync_rst,  sync_set;

    assign async_rst = (SRTYPE == "ASYNC") ? R : 1'b0;
    assign async_set = (SRTYPE == "ASYNC") ? S : 1'b0;
    assign sync_rst  = (SRTYPE == "SYNC" ) ? R : 1'b0;
    assign sync_set  = (SRTYPE == "SYNC" ) ? S : 1'b0;

    // DDR output: D1 on posedge, D2 on negedge
    // For SAME_EDGE mode, both D1 and D2 are clocked on posedge
    always @(posedge C, posedge async_rst, posedge async_set) begin
        if (async_rst)
            Q <= 1'b0;
        else if (async_set)
            Q <= 1'b1;
        else if (CE) begin
            if (sync_rst)
                Q <= 1'b0;
            else if (sync_set)
                Q <= 1'b1;
            else
                Q <= D1;
        end
    end

    always @(negedge C, posedge async_rst, posedge async_set) begin
        if (async_rst)
            Q <= 1'b0;
        else if (async_set)
            Q <= 1'b1;
        else if (CE) begin
            if (sync_rst)
                Q <= 1'b0;
            else if (sync_set)
                Q <= 1'b1;
            else
                Q <= D2;
        end
    end
endmodule

// IDELAYCTRL: IDELAY Control Module
module IDELAYCTRL (
    output RDY,
    input  REFCLK,
    input  RST
);
    assign RDY = ~RST;
endmodule

// IDELAYE2: IDELAY Element (behavioral pass-through)
module IDELAYE2 #(
    parameter CINVCTRL_SEL = "FALSE",
    parameter DELAY_SRC = "IDATAIN",
    parameter HIGH_PERFORMANCE_MODE = "TRUE",
    parameter IDELAY_TYPE = "FIXED",
    parameter IDELAY_VALUE = 0,
    parameter PIPE_SEL = "FALSE",
    parameter REFCLK_FREQUENCY = 200.0,
    parameter SIGNAL_PATTERN = "DATA"
) (
    output DATAOUT,
    input  IDATAIN,
    input  C,
    input  CE,
    input  INC,
    input  LD,
    input  LDPIPEEN,
    input  [4:0] CNTVALUEIN,
    output [4:0] CNTVALUEOUT,
    input  CINVCTRL
);
    // Behavioral: pass IDATAIN straight through to DATAOUT
    // For FIXED mode, the exact delay is not modeled in RTL simulation
    assign DATAOUT     = IDATAIN;
    assign CNTVALUEOUT = IDELAY_VALUE;
endmodule

// ============================================================================
// Xilinx XPM Primitives
// ============================================================================

// xpm_memory_tdpram: XPM True Dual-Port RAM (behavioral)
module xpm_memory_tdpram #(
    parameter ADDR_WIDTH_A = 6,
    parameter ADDR_WIDTH_B = 6,
    parameter AUTO_SLEEP_TIME = 0,
    parameter BYTE_WRITE_WIDTH_A = 8,
    parameter BYTE_WRITE_WIDTH_B = 8,
    parameter CASCADE_HEIGHT = 0,
    parameter CLOCKING_MODE = "common_clock",
    parameter ECC_MODE = "no_ecc",
    parameter MEMORY_INIT_FILE = "none",
    parameter MEMORY_INIT_PARAM = "0",
    parameter MEMORY_OPTIMIZATION = "true",
    parameter MEMORY_PRIMITIVE = "block",
    parameter MEMORY_SIZE = 2048,
    parameter MESSAGE_CONTROL = 0,
    parameter READ_DATA_WIDTH_A = 32,
    parameter READ_DATA_WIDTH_B = 32,
    parameter READ_LATENCY_A = 1,
    parameter READ_LATENCY_B = 1,
    parameter READ_RESET_VALUE_A = "0",
    parameter READ_RESET_VALUE_B = "0",
    parameter RST_MODE_A = "SYNC",
    parameter RST_MODE_B = "SYNC",
    parameter SIM_ASSERT_CHK = 0,
    parameter USE_EMBEDDED_CONSTRAINT = 0,
    parameter USE_MEM_INIT = 0,
    parameter WAKEUP_TIME = "disable_sleep",
    parameter WRITE_DATA_WIDTH_A = 32,
    parameter WRITE_DATA_WIDTH_B = 32,
    parameter WRITE_MODE_A = "read_first",
    parameter WRITE_MODE_B = "read_first"
) (
    input  sleep,
    input  clka,
    input  ena,
    input  [WRITE_DATA_WIDTH_A/8-1:0] wea,
    input  [ADDR_WIDTH_A-1:0]        addra,
    input  [WRITE_DATA_WIDTH_A-1:0]  dina,
    input  injectsbiterra,
    input  injectdbiterra,
    output [READ_DATA_WIDTH_A-1:0]   douta,
    output sbiterra,
    output dbiterra,
    input  clkb,
    input  enb,
    input  [WRITE_DATA_WIDTH_B/8-1:0] web,
    input  [ADDR_WIDTH_B-1:0]         addrb,
    input  [WRITE_DATA_WIDTH_B-1:0]   dinb,
    input  injectsbiterrb,
    input  injectdbiterrb,
    output [READ_DATA_WIDTH_B-1:0]    doutb,
    output sbiterrb,
    output dbiterrb,
    input  rsta,
    input  rstb,
    input  regcea,
    input  regceb
);
    localparam DEPTH_A = 1 << ADDR_WIDTH_A;
    localparam DEPTH_B = 1 << ADDR_WIDTH_B;

    reg [READ_DATA_WIDTH_A-1:0] mem [0:DEPTH_A-1];
    reg [READ_DATA_WIDTH_A-1:0] douta_reg;
    reg [READ_DATA_WIDTH_B-1:0] doutb_reg;

    // Initialize all memory to 0 (prevents X reads in iverilog)
    integer _xpm_init_;
    initial begin
        for (_xpm_init_ = 0; _xpm_init_ < DEPTH_A; _xpm_init_ = _xpm_init_ + 1)
            mem[_xpm_init_] = 0;
    end

    assign sbiterra  = 1'b0;
    assign dbiterra  = 1'b0;
    assign sbiterrb  = 1'b0;
    assign dbiterrb  = 1'b0;
    assign douta     = douta_reg;
    assign doutb     = doutb_reg;

    // Port A
    always @(posedge clka) begin
        if (rsta) begin
            douta_reg <= READ_RESET_VALUE_A;
        end else if (ena && regcea) begin
            if (|wea) begin
                mem[addra] <= dina;
            end
            // read_first mode: old data if writing, new data if only reading
            if (|wea && WRITE_MODE_A == "read_first")
                douta_reg <= mem[addra];
            else if (!(|wea))
                douta_reg <= mem[addra];
            else
                douta_reg <= dina;
        end
    end

    // Port B
    always @(posedge clkb) begin
        if (rstb) begin
            doutb_reg <= READ_RESET_VALUE_B;
        end else if (enb && regceb) begin
            if (|web) begin
                mem[addrb] <= dinb;
            end
            if (|web && WRITE_MODE_B == "read_first")
                doutb_reg <= mem[addrb];
            else if (!(|web))
                doutb_reg <= mem[addrb];
            else
                doutb_reg <= dinb;
        end
    end
endmodule

// ============================================================================
// Altera/Intel Primitives
// ============================================================================

// altddio_in: Altera DDR Input Register
module altddio_in #(
    parameter width = 1,
    parameter power_up_high = "OFF",
    parameter invert_input_clocks = "ON",
    parameter intended_device_family = "Cyclone V",
    parameter lpm_type = "altddio_in",
    parameter lpm_hint = "UNUSED"
) (
    input  [width-1:0] datain,
    input              inclock,
    input              inclocken,
    input              aset,
    input              aclr,
    input              sset,
    input              sclr,
    output [width-1:0] dataout_h,
    output [width-1:0] dataout_l
);
    genvar i;
    generate
        for (i = 0; i < width; i = i + 1) begin : gen_ddr
            IDDR #(
                .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
                .INIT_Q1(1'b0),
                .INIT_Q2(1'b0),
                .SRTYPE("ASYNC")
            ) u_ddr (
                .Q1(dataout_h[i]),
                .Q2(dataout_l[i]),
                .C (inclock),
                .CE(inclocken),
                .D (datain[i]),
                .R (aclr),
                .S (aset)
            );
        end
    endgenerate
endmodule

// altddio_out: Altera DDR Output Register
module altddio_out #(
    parameter width = 1,
    parameter power_up_high = "OFF",
    parameter oe_reg = "UNUSED",
    parameter extend_oe_disable = "UNUSED",
    parameter intended_device_family = "Cyclone V",
    parameter invert_output = "OFF",
    parameter lpm_type = "altddio_out",
    parameter lpm_hint = "UNUSED"
) (
    input  [width-1:0] datain_h,
    input  [width-1:0] datain_l,
    input              outclock,
    input              outclocken,
    input              aset,
    input              aclr,
    input              sset,
    input              sclr,
    input              oe,
    output [width-1:0] dataout,
    output             oe_out
);
    assign oe_out = oe;
    genvar i;
    generate
        for (i = 0; i < width; i = i + 1) begin : gen_ddr
            ODDR #(
                .DDR_CLK_EDGE("SAME_EDGE"),
                .INIT(1'b0),
                .SRTYPE("ASYNC")
            ) u_ddr (
                .Q (dataout[i]),
                .C (outclock),
                .CE(outclocken),
                .D1(datain_h[i]),
                .D2(datain_l[i]),
                .R (aclr),
                .S (aset)
            );
        end
    endgenerate
endmodule

// altsyncram: Altera Synchronous RAM (minimal behavioral stub)
module altsyncram #(
    parameter operation_mode = "BIDIR_DUAL_PORT",
    parameter width_a = 8,
    parameter widthad_a = 6,
    parameter numwords_a = 64,
    parameter width_b = 8,
    parameter widthad_b = 6,
    parameter numwords_b = 64,
    parameter outdata_reg_a = "UNREGISTERED",
    parameter outdata_reg_b = "UNREGISTERED",
    parameter power_up_high = "OFF",
    parameter intended_device_family = "Cyclone V"
) (
    input  [width_a-1:0] data_a,
    input  [widthad_a-1:0] address_a,
    input  wren_a,
    output [width_a-1:0] q_a,
    input  clock0,
    input  [width_b-1:0] data_b,
    input  [widthad_b-1:0] address_b,
    input  wren_b,
    output [width_b-1:0] q_b,
    input  clock1
);
    reg [width_a-1:0] mem [0:numwords_a-1];
    reg [width_a-1:0] q_a_reg;
    reg [width_b-1:0] q_b_reg;

    // Initialize all memory to 0 (prevents X reads in iverilog)
    integer _alt_init_;
    initial begin
        for (_alt_init_ = 0; _alt_init_ < numwords_a; _alt_init_ = _alt_init_ + 1)
            mem[_alt_init_] = 0;
    end

    assign q_a = q_a_reg;
    assign q_b = q_b_reg;

    always @(posedge clock0) begin
        if (wren_a) mem[address_a] <= data_a;
        q_a_reg <= mem[address_a];
    end

    always @(posedge clock1) begin
        if (wren_b) mem[address_b] <= data_b;
        q_b_reg <= mem[address_b];
    end
endmodule

// ============================================================================
// Gowin Primitives
// ============================================================================

module IODELAY (
    output DO,
    output DF,
    input  DI,
    input  SDTAP,
    input  SETN,
    input  VALUE
);
    parameter C_STATIC_DLY = 0;
    assign DO = DI;
    assign DF = 1'b0;
endmodule

// ============================================================================
// Pango Primitives
// ============================================================================

module GTP_ISERDES #(
    parameter ISERDES_MODE = "IDDR",
    parameter GRS_EN = "TRUE",
    parameter LRS_EN = "TRUE"
) (
    input  DI,
    input  ICLK,
    input  DESCLK,
    input  RCLK,
    input  [2:0] WADDR,
    input  [2:0] RADDR,
    input  RST,
    output [5:0] DO
);
    // Behavioral: just passthrough for IDDR mode
    reg q1, q2;
    always @(posedge RCLK) q1 <= DI;
    always @(negedge RCLK) q2 <= DI;
    assign DO = {q2, q1, 4'b0000};
endmodule

module GTP_OSERDES #(
    parameter OSERDES_MODE = "ODDR",
    parameter WL_EXTEND = "FALSE",
    parameter GRS_EN = "TRUE",
    parameter LRS_EN = "TRUE",
    parameter TSDDR_INIT = 1'b0
) (
    output DO,
    output TQ,
    input  [7:0] DI,
    input  [3:0] TI,
    input  RCLK,
    input  SERCLK,
    input  OCLK,
    input  RST
);
    // Behavioral ODDR: DI[0] on posedge, DI[1] on negedge
    reg q;
    always @(posedge RCLK or posedge RST) begin
        if (RST) q <= TSDDR_INIT;
        else     q <= DI[0];
    end
    always @(negedge RCLK or posedge RST) begin
        if (RST) q <= TSDDR_INIT;
        else     q <= DI[1];
    end
    assign DO = q;
    assign TQ = TI[0];
endmodule

module GTP_OUTBUFT (
    output O,
    input  I,
    input  T
);
    assign O = T ? I : 1'bz;
endmodule

// ============================================================================
// Generic PLL stub (for pll_bypass=0 simulations; unused when pll_bypass=1)
// ============================================================================

module PLL_50M (
    input  inclk0,
    output c0,
    output c1,
    output c2,
    output locked
);
    // When pll_bypass=1, this module is never instantiated
    assign c0 = inclk0;
    assign c1 = inclk0;
    assign c2 = inclk0;
    assign locked = 1'b1;
endmodule
