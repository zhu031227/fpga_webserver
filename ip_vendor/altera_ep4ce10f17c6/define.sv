// Platform configuration — Altera EP4CE10F17C6
// Included before rtl/define.sv to override defaults for Intel

`ifndef PLATFORM_DEFINE_SV
`define PLATFORM_DEFINE_SV

// ── Device vendor ─────────────────────────────────────
`define DEVICE_VENDOR "intel"

// ── RAM type ──────────────────────────────────────────
`define LARGER_RAM  "M9K"        // ≥128bit storage: block RAM (M9K)
`define SMALL_RAM   "registers"  // <128bit storage: distributed (registers)

`endif
