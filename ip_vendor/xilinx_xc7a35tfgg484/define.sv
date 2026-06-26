// Platform configuration — Xilinx XC7A35T-FGG484
// Included before rtl/define.sv to override defaults for Xilinx

`ifndef PLATFORM_DEFINE_SV
`define PLATFORM_DEFINE_SV

// ── Device vendor ─────────────────────────────────────
`define DEVICE_VENDOR "xilinx"
`define IS_XILINX

// ── RAM type ──────────────────────────────────────────
`define LARGER_RAM  "block"        // ≥128bit storage: block RAM
`define SMALL_RAM   "distributed"  // <128bit storage: distributed RAM

`endif
