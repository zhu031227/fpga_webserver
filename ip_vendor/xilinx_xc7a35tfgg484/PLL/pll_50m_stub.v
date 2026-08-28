// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2024 Advanced Micro Devices, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2024.1 (lin64) Build 5076996 Wed May 22 18:36:09 MDT 2024
// Date        : Mon Jun 29 10:23:43 2026
// Host        : huamingh-XT12-Pro running 64-bit Ubuntu 26.04 LTS
// Command     : write_verilog -force -mode synth_stub
//               /home/huamingh/work/fpga_webserver/webserver_xilinx_xc7a35tfgg484_v0001_20260629_095848/ip_vendor/xilinx_xc7a35tfgg484/PLL/pll_50m_stub.v
// Design      : pll_50m
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7a35tfgg484-2
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
module pll_50m(c0, c1, c2, locked, inclk0)
/* synthesis syn_black_box black_box_pad_pin="locked,inclk0" */
/* synthesis syn_force_seq_prim="c0" */
/* synthesis syn_force_seq_prim="c1" */
/* synthesis syn_force_seq_prim="c2" */;
  output c0 /* synthesis syn_isclock = 1 */;
  output c1 /* synthesis syn_isclock = 1 */;
  output c2 /* synthesis syn_isclock = 1 */;
  output locked;
  input inclk0;
endmodule
