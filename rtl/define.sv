// Interface mode selection for FPGA WebServer
// Xilinx platform: RGMII (with rgmii2gmii bridge to internal GMII)
// Altera platform:  GMII (direct connection)
//
// The platform-specific top modules handle the PHY interface conversion.
// The internal webserver_wrapper always uses GMII signaling.

`ifndef DEFINE_SV
`define DEFINE_SV

// ── Device vendor ─────────────────────────────────────
`define DEVICE_VENDOR "xilinx"

// ── RAM type (per platform) ───────────────────────────
`define LARGER_RAM  "block"        // ≥128bit storage: block RAM
`define SMALL_RAM   "distributed"  // <128bit storage: distributed RAM

`endif
