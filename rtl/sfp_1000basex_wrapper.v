// sfp_1000basex_wrapper — 2-port 1000BASE-X SFP wrapper with shared GTPE2_COMMON
//
// Two gig_ethernet_pcs_pma_0 instances (Include_Shared_Logic_in_Example_Design mode)
// share one GTPE2_COMMON (CPLL) and one 125MHz reference clock.
//
// Architecture:
//   gtrefclk_p/n (125MHz) → IBUFDS_GTE2 → GTPE2_COMMON (CPLL)
//     → CPLL output drives both GTPE2_CHANNELs (eth1 @ X0Y0, eth2 @ X0Y1)
//   eth1 txoutclk → MMCM → userclk (62.5MHz) + userclk2 (125MHz) → both cores
//
// Port A (SFP1, eth1): GTPE2_CHANNEL_X0Y0, LAN port
// Port B (SFP2, eth2): GTPE2_CHANNEL_X0Y1, WAN port

module sfp_1000basex_wrapper (
    // shared
    input gtrefclk_p,              // 125MHz differential GT reference clock
    input gtrefclk_n,
    input independent_clock_bufg,  // 200MHz free-running clock (from PLL)
    input reset,                   // async reset (active high)

    // SFP1 (eth1, LAN)
    output        sfp1_txp,
    output        sfp1_txn,
    input         sfp1_rxp,
    input         sfp1_rxn,
    output        sfp1_tx_disable,
    // SFP1 GMII (to MAC)
    input  [ 7:0] gmii1_txd,
    input         gmii1_tx_en,
    input         gmii1_tx_er,
    output [ 7:0] gmii1_rxd,
    output        gmii1_rx_dv,
    output        gmii1_rx_er,
    output [15:0] sfp1_status_vector,

    // SFP2 (eth2, WAN)
    output        sfp2_txp,
    output        sfp2_txn,
    input         sfp2_rxp,
    input         sfp2_rxn,
    output        sfp2_tx_disable,
    // SFP2 GMII (to MAC)
    input  [ 7:0] gmii2_txd,
    input         gmii2_tx_en,
    input         gmii2_tx_er,
    output [ 7:0] gmii2_rxd,
    output        gmii2_rx_dv,
    output        gmii2_rx_er,
    output [15:0] sfp2_status_vector,

    // status
    output resetdone,
    output mmcm_locked_out,
    output cpll_lock_out,        // CPLL lock (shared GTPE2_COMMON)
    output pll0_refclklost_out   // CPLL reference-lost flag
);

  // --- internal wires ---
  wire gtrefclk;
  wire gtrefclk_bufg;
  wire txoutclk_eth1;
  wire rxoutclk_eth1;
  wire txoutclk_eth2;
  wire rxoutclk_eth2;
  wire mmcm_reset;
  wire recclk_mmcm_locked;
  wire mmcm_locked;
  wire userclk;
  wire userclk2;
  wire rxuserclk;
  wire rxuserclk2;
  wire pma_reset;

  // GTPE2_COMMON signals
  wire gt0_pll0outclk;
  wire gt0_pll0outrefclk;
  wire gt0_pll1outclk;
  wire gt0_pll1outrefclk;
  wire gt0_pll0lock;
  wire gt0_pll0refclklost;
  wire gt0_pll0reset_eth1;
  wire gt0_pll0reset_eth2;
  wire gt0_pll0reset;
  wire commonreset_i;

  wire resetdone_eth1, resetdone_eth2;
  wire cplllock_eth1, cplllock_eth2;
  wire mmcm_reset_eth1, mmcm_reset_eth2;

  wire sfp1_signal_detect, sfp2_signal_detect;

  // ============================================================
  // Shared Clocking: IBUFDS_GTE2 + MMCM (driven by eth1 txoutclk)
  // ============================================================
  wire mmcm_reset_combined;

  // --- SFP control ---
  assign sfp1_tx_disable = 1'b0;  // always enabled
  assign sfp2_tx_disable = 1'b0;
  assign sfp1_signal_detect = 1'b1;  // assume signal present
  assign sfp2_signal_detect = 1'b1;

  // --- Reset done (both cores must be done) ---
  assign resetdone = resetdone_eth1 && resetdone_eth2;

  // ============================================================
  // PCS/PMA Core: eth1 (SFP1) — GTPE2_CHANNEL X0Y0
  // ============================================================
  gig_ethernet_pcs_pma_0 pcs_pma_eth1 (
      .gtrefclk              (gtrefclk),
      .gtrefclk_bufg         (gtrefclk_bufg),
      .txp                   (sfp1_txp),
      .txn                   (sfp1_txn),
      .rxp                   (sfp1_rxp),
      .rxn                   (sfp1_rxn),
      .txoutclk              (txoutclk_eth1),
      .rxoutclk              (rxoutclk_eth1),
      .resetdone             (resetdone_eth1),
      .cplllock              (cplllock_eth1),
      .mmcm_reset            (mmcm_reset_eth1),
      .userclk               (userclk),
      .userclk2              (userclk2),
      .rxuserclk             (rxuserclk),
      .rxuserclk2            (rxuserclk2),
      .independent_clock_bufg(independent_clock_bufg),
      .pma_reset             (pma_reset),
      .mmcm_locked           (mmcm_locked),

      .gmii_txd    (gmii1_txd),
      .gmii_tx_en  (gmii1_tx_en),
      .gmii_tx_er  (gmii1_tx_er),
      .gmii_rxd    (gmii1_rxd),
      .gmii_rx_dv  (gmii1_rx_dv),
      .gmii_rx_er  (gmii1_rx_er),
      .gmii_isolate(),

      .configuration_vector(5'b10000),              // bit4=1: ANEG enable (canonical value from sgmii bridge)
      .an_interrupt        (),
      .an_adv_config_vector(16'b0000000001100001),  // selector=1000BASE-X, HD+FD advertised
      .an_restart_config   (1'b0),
      .status_vector       (sfp1_status_vector),
      .reset               (pma_reset),
      .signal_detect       (sfp1_signal_detect),

      .gt0_pll0outclk_in    (gt0_pll0outclk),
      .gt0_pll0outrefclk_in (gt0_pll0outrefclk),
      .gt0_pll1outclk_in    (gt0_pll1outclk),
      .gt0_pll1outrefclk_in (gt0_pll1outrefclk),
      .gt0_pll0lock_in      (gt0_pll0lock),
      .gt0_pll0refclklost_in(gt0_pll0refclklost),
      .gt0_pll0reset_out    (gt0_pll0reset_eth1)
  );

  // ============================================================
  // PCS/PMA Core: eth2 (SFP2) — GTPE2_CHANNEL X0Y1
  // ============================================================
  gig_ethernet_pcs_pma_0 pcs_pma_eth2 (
      .gtrefclk              (gtrefclk),
      .gtrefclk_bufg         (gtrefclk_bufg),
      .txp                   (sfp2_txp),
      .txn                   (sfp2_txn),
      .rxp                   (sfp2_rxp),
      .rxn                   (sfp2_rxn),
      .txoutclk              (txoutclk_eth2),
      .rxoutclk              (rxoutclk_eth2),
      .resetdone             (resetdone_eth2),
      .cplllock              (cplllock_eth2),
      .mmcm_reset            (mmcm_reset_eth2),
      .userclk               (userclk),                 // share eth1 MMCM clocks
      .userclk2              (userclk2),
      .rxuserclk             (rxuserclk),
      .rxuserclk2            (rxuserclk2),
      .independent_clock_bufg(independent_clock_bufg),
      .pma_reset             (pma_reset),
      .mmcm_locked           (mmcm_locked),

      .gmii_txd    (gmii2_txd),
      .gmii_tx_en  (gmii2_tx_en),
      .gmii_tx_er  (gmii2_tx_er),
      .gmii_rxd    (gmii2_rxd),
      .gmii_rx_dv  (gmii2_rx_dv),
      .gmii_rx_er  (gmii2_rx_er),
      .gmii_isolate(),

      .configuration_vector(5'b10000),              // bit4=1: ANEG enable (canonical value from sgmii bridge)
      .an_interrupt        (),
      .an_adv_config_vector(16'b0000000001100001),  // selector=1000BASE-X, HD+FD advertised
      .an_restart_config   (1'b0),
      .status_vector       (sfp2_status_vector),
      .reset               (pma_reset),
      .signal_detect       (sfp2_signal_detect),

      .gt0_pll0outclk_in    (gt0_pll0outclk),
      .gt0_pll0outrefclk_in (gt0_pll0outrefclk),
      .gt0_pll1outclk_in    (gt0_pll1outclk),
      .gt0_pll1outrefclk_in (gt0_pll1outrefclk),
      .gt0_pll0lock_in      (gt0_pll0lock),
      .gt0_pll0refclklost_in(gt0_pll0refclklost),
      .gt0_pll0reset_out    (gt0_pll0reset_eth2)
  );
  assign mmcm_reset_combined = mmcm_reset_eth1;  // eth1 drives MMCM reset

  sgmii2mac_clocking core_clocking_i (
      .gtrefclk_p        (gtrefclk_p),
      .gtrefclk_n        (gtrefclk_n),
      .txoutclk          (txoutclk_eth1),
      .rxoutclk          (rxoutclk_eth1),
      .mmcm_reset        (mmcm_reset_combined),
      .recclk_mmcm_reset (1'b0),
      .recclk_mmcm_locked(recclk_mmcm_locked),
      .gtrefclk          (gtrefclk),
      .gtrefclk_bufg     (gtrefclk_bufg),
      .mmcm_locked       (mmcm_locked),
      .userclk           (userclk),
      .userclk2          (userclk2),
      .rxuserclk         (rxuserclk),
      .rxuserclk2        (rxuserclk2)
  );

  assign mmcm_locked_out = mmcm_locked;
  assign cpll_lock_out = cplllock_eth1;  // eth1/eth2 share the same CPLL
  assign pll0_refclklost_out = gt0_pll0refclklost;

  // ============================================================
  // Shared PMA Reset
  // ============================================================
  sgmii2mac_resets core_resets_i (
      .reset                 (reset),
      .independent_clock_bufg(independent_clock_bufg),
      .pma_reset             (pma_reset)
  );

  // ============================================================
  // Shared GTPE2_COMMON (CPLL)
  // ============================================================

  // OR the two per-core reset requests
  assign gt0_pll0reset = gt0_pll0reset_eth1 || gt0_pll0reset_eth2 || commonreset_i;

  sgmii2mac_common_reset #(
      .STABLE_CLOCK_PERIOD(5)  // 200MHz = 5ns period
  ) core_gt_common_reset_i (
      .STABLE_CLOCK(independent_clock_bufg),
      .SOFT_RESET  (pma_reset),
      .COMMON_RESET(commonreset_i)
  );

  sgmii2mac_gt_common core_gt_common_i (
      .GTREFCLK1_IN      (gtrefclk),
      .GTREFCLK1_BUFG_IN (gtrefclk_bufg),
      .PLL0OUTCLK_OUT    (gt0_pll0outclk),
      .PLL0OUTREFCLK_OUT (gt0_pll0outrefclk),
      .PLL1OUTCLK_OUT    (gt0_pll1outclk),
      .PLL1OUTREFCLK_OUT (gt0_pll1outrefclk),
      .PLL0LOCK_OUT      (gt0_pll0lock),
      .PLL0LOCKDETCLK_IN (independent_clock_bufg),
      .PLL0REFCLKLOST_OUT(gt0_pll0refclklost),
      .PLL0RESET_IN      (gt0_pll0reset)
  );
endmodule
