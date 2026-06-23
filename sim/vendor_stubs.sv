// vendor_stubs.sv — Behavioral stubs for Verilator (all vendor paths)
module IDDR #(DDR_CLK_EDGE="SAME_EDGE_PIPELINED",INIT_Q1=0,INIT_Q2=0,SRTYPE="SYNC",Q0_INIT=0,Q1_INIT=0)
  (output reg Q0, Q1, Q2, input C, CLK, CE, D, R, S);
  wire async_rst = (SRTYPE == "ASYNC") ? R : 1'b0;
  wire async_set = (SRTYPE == "ASYNC") ? S : 1'b0;
  wire sync_rst  = (SRTYPE == "SYNC" ) ? R : 1'b0;
  wire sync_set  = (SRTYPE == "SYNC" ) ? S : 1'b0;
  // Match iverilog IDDR exactly — use C directly (not _clk) for posedge/negedge
  always @(posedge C, posedge async_rst, posedge async_set) begin
    if (async_rst)        Q1 <= 1'b0;
    else if (async_set)   Q1 <= 1'b1;
    else if (CE) begin
      if (sync_rst)       Q1 <= 1'b0;
      else if (sync_set)  Q1 <= 1'b1;
      else                Q1 <= D;
    end
    Q0 <= D;  // Gowin: posedge data, no R/S/CE gating
  end
  always @(negedge C, posedge async_rst, posedge async_set) begin
    if (async_rst)        Q2 <= 1'b0;
    else if (async_set)   Q2 <= 1'b1;
    else if (CE) begin
      if (sync_rst)       Q2 <= 1'b0;
      else if (sync_set)  Q2 <= 1'b1;
      else                Q2 <= D;
    end
  end
endmodule

module ODDR #(DDR_CLK_EDGE="SAME_EDGE",INIT=0,SRTYPE="SYNC",TXCLK_POL=0)
  (output reg Q,Q0,Q1,input C,CLK,CE,D0,D1,D2,R,S,TX);
  assign Q0=Q; assign Q1=0;
  always@(posedge C) if(CE) Q<=R?0:S?1:(TX?D0:D1);
  always@(negedge C) if(CE) Q<=R?0:S?1:D2; endmodule

module IDELAYCTRL(output RDY,input REFCLK,RST); assign RDY=~RST; endmodule

module IDELAYE2 #(IDELAY_VALUE=0,IDELAY_TYPE="FIXED",DELAY_SRC="IDATAIN",
  CINVCTRL_SEL="FALSE",HIGH_PERFORMANCE_MODE="TRUE",PIPE_SEL="FALSE",
  REFCLK_FREQUENCY=200.0,SIGNAL_PATTERN="DATA")
  (output DATAOUT,input IDATAIN,C,CE,INC,LD,LDPIPEEN,
   output[4:0]CNTVALUEOUT,input CINVCTRL,input[4:0]CNTVALUEIN);
  assign DATAOUT=IDATAIN; assign CNTVALUEOUT=IDELAY_VALUE; endmodule

module xpm_memory_tdpram #(
  ADDR_WIDTH_A=6,ADDR_WIDTH_B=6,AUTO_SLEEP_TIME=0,
  BYTE_WRITE_WIDTH_A=8,BYTE_WRITE_WIDTH_B=8,CASCADE_HEIGHT=0,
  CLOCKING_MODE="common_clock",ECC_MODE="no_ecc",
  MEMORY_INIT_FILE="none",MEMORY_INIT_PARAM="0",MEMORY_OPTIMIZATION="true",
  MEMORY_PRIMITIVE="block",MEMORY_SIZE=2048,MESSAGE_CONTROL=0,
  READ_DATA_WIDTH_A=32,READ_DATA_WIDTH_B=32,READ_LATENCY_A=1,READ_LATENCY_B=1,
  READ_RESET_VALUE_A="0",READ_RESET_VALUE_B="0",
  RST_MODE_A="SYNC",RST_MODE_B="SYNC",SIM_ASSERT_CHK=0,
  USE_EMBEDDED_CONSTRAINT=0,USE_MEM_INIT=0,WAKEUP_TIME="disable_sleep",
  WRITE_DATA_WIDTH_A=32,WRITE_DATA_WIDTH_B=32,WRITE_MODE_A="read_first",WRITE_MODE_B="read_first"
) (input sleep,clka,ena,injectsbiterra,injectdbiterra,clkb,enb,injectsbiterrb,injectdbiterrb,
   input [WRITE_DATA_WIDTH_A/8-1:0] wea, input [WRITE_DATA_WIDTH_B/8-1:0] web,
   input [ADDR_WIDTH_A-1:0] addra, input [ADDR_WIDTH_B-1:0] addrb,
   input [WRITE_DATA_WIDTH_A-1:0] dina, input [WRITE_DATA_WIDTH_B-1:0] dinb,
   output [READ_DATA_WIDTH_A-1:0] douta, output [READ_DATA_WIDTH_B-1:0] doutb,
   output sbiterra,dbiterra,sbiterrb,dbiterrb,
   input rsta,rstb,regcea,regceb);
  localparam D=1<<ADDR_WIDTH_A;
  reg [READ_DATA_WIDTH_A-1:0] m[0:D-1],da,db; integer _i;
  initial begin for(_i=0;_i<D;_i=_i+1) m[_i]=0;  end
  assign douta=da; assign doutb=db; assign sbiterra=0; assign dbiterra=0; assign sbiterrb=0; assign dbiterrb=0;
  always@(posedge clka) if(ena&&regcea) begin
    if(|wea) m[addra]<=dina;
    da <= (|wea) ? (WRITE_MODE_A=="read_first" ? m[addra] : dina) : m[addra];
  end
  always@(posedge clkb) if(enb&&regceb) begin
    if(|web) m[addrb]<=dinb;
    db <= (|web) ? (WRITE_MODE_B=="read_first" ? m[addrb] : dinb) : m[addrb];
  end endmodule

module altddio_in #(width=1,power_up_high="OFF",invert_input_clocks="ON",
  intended_device_family="Cyclone V",lpm_type="altddio_in",lpm_hint="UNUSED")
  (input[width-1:0]datain,inclock,inclocken,aset,aclr,sset,sclr,output[width-1:0]dataout_h,dataout_l);
  genvar g; generate for(g=0;g<width;g=g+1) begin:g_ IDDR #(.SRTYPE("ASYNC"))
    u(.Q1(dataout_h[g]),.Q2(dataout_l[g]),.C(inclock),.CE(inclocken),.D(datain[g]),.R(aclr),.S(aset)); end endgenerate endmodule

module altddio_out #(width=1,power_up_high="OFF",oe_reg="UNUSED",
  extend_oe_disable="UNUSED",intended_device_family="Cyclone V",
  invert_output="OFF",lpm_type="altddio_out",lpm_hint="UNUSED")
  (input[width-1:0]datain_h,datain_l,outclock,outclocken,aset,aclr,sset,sclr,oe,output[width-1:0]dataout,output oe_out);
  assign oe_out=oe; genvar g; generate for(g=0;g<width;g=g+1) begin:g_ ODDR
    u(.Q(dataout[g]),.C(outclock),.CE(outclocken),.D1(datain_h[g]),.D2(datain_l[g]),.R(aclr),.S(aset)); end endgenerate endmodule

module altsyncram #(operation_mode="BIDIR_DUAL_PORT",width_a=8,widthad_a=6,numwords_a=64,
  width_b=8,widthad_b=6,numwords_b=64,width_byteena_a=1,width_byteena_b=1,
  outdata_reg_a="UNREGISTERED",outdata_reg_b="UNREGISTERED",
  clock_enable_input_a="NORMAL",clock_enable_input_b="NORMAL",
  clock_enable_output_a="NORMAL",clock_enable_output_b="NORMAL",
  read_during_write_mode_port_a="NEW_DATA_NO_NBE_READ",
  read_during_write_mode_port_b="NEW_DATA_NO_NBE_READ",
  power_up_uninitialized="FALSE",power_up_high="OFF",
  intended_device_family="Cyclone V",lpm_type="altsyncram",lpm_hint="UNUSED",
  address_aclr_a="NONE",address_aclr_b="NONE",address_reg_b="CLOCK1",
  indata_aclr_a="NONE",indata_aclr_b="NONE",
  outdata_aclr_a="NONE",outdata_aclr_b="NONE",
  wrcontrol_aclr_a="NONE",wrcontrol_aclr_b="NONE",
  byte_size=8,read_during_write_mode_mixed_ports="DONT_CARE",
  ram_block_type="AUTO",maximum_depth=0,init_file="UNUSED",init_file_layout="UNUSED")
  (input[width_a-1:0]data_a,input[widthad_a-1:0]address_a,input wren_a,output[width_a-1:0]q_a,
   input clock0,clocken0,clocken1,clocken2,clocken3,aclr0,aclr1,rden_a,rden_b,
   input[width_b-1:0]data_b,input[widthad_b-1:0]address_b,input wren_b,output[width_b-1:0]q_b,
   input clock1,input[widthad_b-1:0]addressstall_b,input[widthad_a-1:0]addressstall_a,
   input[width_byteena_a-1:0]byteena_a,input[width_byteena_b-1:0]byteena_b,
   output[1:0]eccstatus);
  reg[width_a-1:0]m[0:numwords_a-1],qa,qb; integer _i;
  initial for(_i=0;_i<numwords_a;_i=_i+1) m[_i]=0;
  assign q_a=qa; assign q_b=qb;
  always@(posedge clock0) begin if(wren_a)m[address_a]<=data_a; qa<=m[address_a]; end
  always@(posedge clock1) begin if(wren_b)m[address_b]<=data_b; qb<=m[address_b]; end endmodule
module IODELAY(output DO,DF,input DI,SDTAP,SETN,VALUE); parameter C_STATIC_DLY=0; assign DO=DI; assign DF=0; endmodule
module GTP_ISERDES #(ISERDES_MODE="IDDR",GRS_EN="TRUE",LRS_EN="TRUE")(input DI,ICLK,DESCLK,RCLK,RST,input[2:0]WADDR,RADDR,output[5:0]DO);
  reg q1,q2; always@(posedge RCLK) q1<=DI; always@(negedge RCLK) q2<=DI; assign DO={q2,q1,4'b0}; endmodule
module GTP_OSERDES #(OSERDES_MODE="ODDR",TSDDR_INIT=0,WL_EXTEND="FALSE",GRS_EN="TRUE",LRS_EN="TRUE")
  (output DO,TQ,input[7:0]DI,input[3:0]TI,RCLK,SERCLK,OCLK,RST);
  reg q; always@(posedge RCLK) q<=RST?TSDDR_INIT:DI[0]; always@(negedge RCLK) q<=RST?TSDDR_INIT:DI[1]; assign DO=q; assign TQ=TI[0]; endmodule
module GTP_OUTBUFT(output O,input I,T); assign O=T?I:1'bz; endmodule

module PLL_50M(input inclk0,output c0,c1,c2,locked);
  assign c0=inclk0; assign c1=inclk0; assign c2=inclk0; assign locked=1; endmodule
