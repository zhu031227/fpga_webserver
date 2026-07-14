// Interface mode selection for FPGA WebServer
// Xilinx platform: RGMII (with rgmii2gmii bridge to internal GMII)
// Altera platform:  GMII (direct connection)
//
// The platform-specific top modules handle the PHY interface conversion.
// The internal webserver_wrapper always uses GMII signaling.

`ifndef DEFINE_SV
`define DEFINE_SV

// ── Platform selection ────────────────────────────────
// Define exactly ONE of the following before including this file:
//   `define FPGA_PLATFORM_XILINX
//   `define FPGA_PLATFORM_ALTERA
// If none defined, defaults to Xilinx.

// ── Device vendor ─────────────────────────────────────
`ifdef FPGA_PLATFORM_ALTERA
`define DEVICE_VENDOR "Intel"
`else
`define DEVICE_VENDOR "xilinx"
`define IS_XILINX
`define ILA_ENABLE 8'b0000_0111  // Xilinx ILA 使能向量, 每 bit 控一个 ILA:
                                 //   bit[0]=u_ila_wl_lookup(白名单查找)
                                 //   bit[1]=u_ila_wr(BRAM写口), bit[2]=u_ila_bram(BRAM读口)
                                 //   全 0 (或注释掉本行) = 关闭所有 ILA
`endif

// ── RAM type (per platform) ───────────────────────────
`ifdef FPGA_PLATFORM_ALTERA
`define LARGER_RAM "M9K"         // >=128bit storage: M9K block RAM
`define SMALL_RAM "registers"   // <128bit storage: registers (MLAB optional)
`else
`define LARGER_RAM "block"        // >=128bit storage: block RAM
`define SMALL_RAM "distributed"  // <128bit storage: distributed RAM
`endif

`endif
