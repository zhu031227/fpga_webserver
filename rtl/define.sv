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
