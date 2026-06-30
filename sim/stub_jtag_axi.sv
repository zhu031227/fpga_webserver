//-------------------------------------------------------------------
// stub_jtag_axi.sv — Minimal stub for Xilinx jtag_axi_0 IP
//
// This module is instantiated by jtag_cpu_xilinx.v which is only
// selected when sim_mod=0 (real hardware).  In simulation (sim_mod=1)
// this generate branch is unused, but Verilator still needs the module
// to exist for compilation.
//-------------------------------------------------------------------

module jtag_axi_0 (
    input         aclk,
    input         aresetn,
    input         m_axi_awready,
    output        m_axi_awvalid,
    output [31:0] m_axi_awaddr,
    output [2:0]  m_axi_awprot,
    input         m_axi_wready,
    output        m_axi_wvalid,
    output [31:0] m_axi_wdata,
    output [3:0]  m_axi_wstrb,
    input  [1:0]  m_axi_bresp,
    input         m_axi_bvalid,
    output        m_axi_bready,
    input         m_axi_arready,
    output        m_axi_arvalid,
    output [31:0] m_axi_araddr,
    output [2:0]  m_axi_arprot,
    input  [1:0]  m_axi_rresp,
    input         m_axi_rvalid,
    input  [31:0] m_axi_rdata,
    output        m_axi_rready
);

  assign m_axi_awvalid = 1'b0;
  assign m_axi_awaddr  = 32'h0;
  assign m_axi_awprot  = 3'h0;
  assign m_axi_wvalid  = 1'b0;
  assign m_axi_wdata   = 32'h0;
  assign m_axi_wstrb   = 4'h0;
  assign m_axi_bready  = 1'b0;
  assign m_axi_arvalid = 1'b0;
  assign m_axi_araddr  = 32'h0;
  assign m_axi_arprot  = 3'h0;
  assign m_axi_rready  = 1'b0;

endmodule
