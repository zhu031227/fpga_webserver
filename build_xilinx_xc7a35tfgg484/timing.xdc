#===================================================================
# timing.xdc — Xilinx XC7A35T-FGG484 timing constraints
#===================================================================
#
# Clock architecture:
#   clk_50m_in   (50MHz,  input) → MMCM → c0_pll_50m  (50MHz,  system)
#                                        → c1_pll_50m  (125MHz, MAC/pkt)
#                                        → c2_pll_50m  (200MHz, IDELAY)
#   rgmii_rxc    (125MHz, input, RGMII RX clock)
#   rgmii_txc    (125MHz, output, RGMII TX clock)
#
# All clock domains use CDC FIFOs (dual_clock_fifo) for crossing.
# Declare all groups asynchronous — no static timing analysis
# between domains.  Timing within each domain is still checked.

# --- Input clocks ---
create_clock -period 20.000 -name clk_50m_in [get_ports clk_50m_in]
create_clock -period 8.000  -name rgmii_rxc  [get_ports rgmii_rxc]
create_clock -period 8.000  -name rgmii_txc  [get_ports rgmii_txc]

# --- Async clock groups ---
# Each group is independent; crossings between groups are
# handled by CDC FIFOs and NOT analyzed for static timing.
set_clock_groups -asynchronous \
    -group [get_clocks clk_50m_in] \
    -group [get_clocks -include_generated_clocks \
            -of_objects [get_pins g_clk_pll.u_pll/inst/mmcm_adv_inst/CLKOUT0]] \
    -group [get_clocks -include_generated_clocks \
            -of_objects [get_pins g_clk_pll.u_pll/inst/mmcm_adv_inst/CLKOUT1]] \
    -group [get_clocks -include_generated_clocks \
            -of_objects [get_pins g_clk_pll.u_pll/inst/mmcm_adv_inst/CLKOUT2]] \
    -group [get_clocks rgmii_rxc] \
    -group [get_clocks rgmii_txc]

# --- RGMII TX output delay ---
# rgmii_txc is a forwarded clock; constrain output data relative to it.
set_output_delay -clock rgmii_txc -max 1.000 [get_ports {rgmii_txd[*] rgmii_tx_ctl}]
set_output_delay -clock rgmii_txc -min 0.000 [get_ports {rgmii_txd[*] rgmii_tx_ctl}]

# --- RGMII RX input delay ---
# rgmii_rxc is the source-synchronous RX clock from the PHY.
set_input_delay -clock rgmii_rxc -max 2.000 [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
set_input_delay -clock rgmii_rxc -min 1.000 [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
