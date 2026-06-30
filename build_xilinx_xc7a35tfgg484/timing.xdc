#===================================================================
# timing.xdc — Xilinx XC7A35T-FGG484 timing constraints
#===================================================================
#
# Clock architecture:
#   clk_50m_in   (50MHz,  input) → MMCM → clk_50m   (50MHz,  system)
#                                        → clk_125m  (125MHz, MAC/pkt)
#                                        → clk_200m  (200MHz, IDELAY)
#   rgmii_rxc    (125MHz, input,  RGMII RX clock from PHY)
#   rgmii_txc    (125MHz, output, RGMII TX clock via ODDR, auto-derived)
#   mdio_clk     (2.5MHz, gen'd,  MDIO clock from 50MHz divider)
#
# All clock domains use CDC FIFOs (dual_clock_fifo) for crossing.
# Cross-domain paths are excluded from static timing analysis.
# Timing within each domain is still checked.

#-------------------------------------------------------------------
# Primary input clocks
#-------------------------------------------------------------------
create_clock -period 20.000 -name clk_50m_in [get_ports clk_50m_in]
create_clock -period 8.000  -name rgmii_rxc  [get_ports rgmii_rxc]

# rgmii_txc is an output driven by ODDR — Vivado auto-derives a
# generated clock from the ODDR primitive.  Do NOT manually create
# a clock on the port (avoids TIMING-4, TIMING-27).

#-------------------------------------------------------------------
# MDIO clock (2.5MHz, generated from 50MHz PLL via divider)
# Fixes TIMING-17 (non-clocked sequential cells).
#-------------------------------------------------------------------
create_generated_clock -name mdio_clk \
    -source [get_ports clk_50m_in] \
    -divide_by 20 \
    [get_pins u_webserver/u_lcpu_mdio_eth0/u_clock_frequency_divider/clk_out_reg/Q]

#-------------------------------------------------------------------
# Async clock groups
#-------------------------------------------------------------------
# Vivado auto-names PLL output clocks after the net names
# (clk_50m, clk_125m, clk_200m).  rgmii_txc is auto-derived.
# Gather all real clocks on these nets / ports.
set_clock_groups -asynchronous \
    -group [get_clocks clk_50m_in] \
    -group [get_clocks -include_generated_clocks -of_objects [get_nets clk_50m]] \
    -group [get_clocks -include_generated_clocks -of_objects [get_nets clk_125m]] \
    -group [get_clocks -include_generated_clocks -of_objects [get_nets clk_200m]] \
    -group [get_clocks rgmii_rxc] \
    -group [get_clocks -include_generated_clocks -of_objects [get_ports rgmii_txc]]

#-------------------------------------------------------------------
# RGMII TX output delay (relative to auto-derived rgmii_txc clock)
#-------------------------------------------------------------------
set_output_delay -clock [get_clocks -of_objects [get_ports rgmii_txc]] \
    -max 1.000 [get_ports {rgmii_txd[*] rgmii_tx_ctl}]
set_output_delay -clock [get_clocks -of_objects [get_ports rgmii_txc]] \
    -min 0.000 [get_ports {rgmii_txd[*] rgmii_tx_ctl}]

#-------------------------------------------------------------------
# RGMII RX input delay (relative to rgmii_rxc)
#-------------------------------------------------------------------
set_input_delay -clock rgmii_rxc -max 2.500 [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
set_input_delay -clock rgmii_rxc -min 2.500 [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]

#-------------------------------------------------------------------
# UART (115200 baud, ~8.68us per bit — generous constraints)
#-------------------------------------------------------------------
set_input_delay -clock [get_clocks -of_objects [get_nets clk_50m]] \
    -max 5.000 [get_ports uart_rx]
set_input_delay -clock [get_clocks -of_objects [get_nets clk_50m]] \
    -min 1.000 [get_ports uart_rx]
set_output_delay -clock [get_clocks -of_objects [get_nets clk_50m]] \
    -max 5.000 [get_ports uart_tx]
set_output_delay -clock [get_clocks -of_objects [get_nets clk_50m]] \
    -min 1.000 [get_ports uart_tx]

#-------------------------------------------------------------------
# MDIO (2.5MHz, relative to mdio_clk)
#-------------------------------------------------------------------
set_output_delay -clock mdio_clk -max 5.000 [get_ports eth0_mdc]
set_output_delay -clock mdio_clk -min 1.000 [get_ports eth0_mdc]
set_output_delay -clock mdio_clk -max 5.000 [get_ports eth0_mdio]
set_output_delay -clock mdio_clk -min 1.000 [get_ports eth0_mdio]
set_input_delay  -clock mdio_clk -max 5.000 [get_ports eth0_mdio]
set_input_delay  -clock mdio_clk -min 1.000 [get_ports eth0_mdio]

#-------------------------------------------------------------------
# Misc slow outputs (LEDs, PHY reset — no critical timing)
#-------------------------------------------------------------------
set_output_delay -clock [get_clocks -of_objects [get_nets clk_50m]] \
    -max 10.000 [get_ports {rgmii_reset_l led_o[*]}]
set_output_delay -clock [get_clocks -of_objects [get_nets clk_50m]] \
    -min 0.000 [get_ports {rgmii_reset_l led_o[*]}]

#-------------------------------------------------------------------
# Async reset — no input delay needed
#-------------------------------------------------------------------
set_false_path -through [get_ports reset_l]

#-------------------------------------------------------------------
# CDC false paths (MDIO ↔ 50MHz system clock)
#-------------------------------------------------------------------
set_false_path -from [get_clocks mdio_clk] \
    -to [get_clocks -of_objects [get_nets clk_50m]]
set_false_path -from [get_clocks -of_objects [get_nets clk_50m]] \
    -to [get_clocks mdio_clk]
