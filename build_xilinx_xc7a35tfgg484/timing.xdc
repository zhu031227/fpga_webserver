#===================================================================
# timing.xdc — Xilinx XC7A35T-FGG484 timing constraints
#===================================================================
#
# Clock architecture:
#   clk_50m_in       (50MHz,  input) → MMCM → clk_50m   (50MHz,  system)
#                                            → clk_125m  (125MHz, MAC/pkt)
#                                            → clk_200m  (200MHz, IDELAY/SFP)
#   rgmii_rxc        (125MHz, input,  RGMII RX clock from PHY)
#   rgmii_txc        (125MHz, output, RGMII TX clock via ODDR)
#   gtrefclk_p/n     (125MHz, input,  GT reference clock)
#   sgmii_userclk2   (125MHz, gen'd,  SGMII core clock from GT MMCM)

#-------------------------------------------------------------------
# Primary input clocks
#-------------------------------------------------------------------
create_clock -period 20.000 -name clk_50m_in [get_ports clk_50m_in]
create_clock -period 8.000  -name rgmii_rxc  [get_ports rgmii_rxc]

# GT reference clock (125MHz differential)
create_clock -period 8.000 -name gtrefclk [get_ports gtrefclk_p]

#-------------------------------------------------------------------
# MDIO clock (2.5MHz, generated from 50MHz PLL via divider)
#-------------------------------------------------------------------
create_generated_clock -name mdio_clk_eth0 \
    -source [get_ports clk_50m_in] \
    -divide_by 20 \
    [get_pins u_webserver/u_lcpu_mdio_eth0/u_clock_frequency_divider/clk_out_reg/Q]

#-------------------------------------------------------------------
# GTPE2_CHANNEL placement constraints
#-------------------------------------------------------------------
# SFP1 (eth1) uses MGT_RX0/TX0 → GTPE2_CHANNEL_X0Y0
set_property LOC GTPE2_CHANNEL_X0Y0 [get_cells -hier -filter {NAME =~ *u_sfp_wrapper/pcs_pma_eth1/*/gtpe2_i}]

# SFP2 (eth2) uses MGT_RX1/TX1 → GTPE2_CHANNEL_X0Y1
set_property LOC GTPE2_CHANNEL_X0Y1 [get_cells -hier -filter {NAME =~ *u_sfp_wrapper/pcs_pma_eth2/*/gtpe2_i}]

#-------------------------------------------------------------------
# Async clock groups
#-------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks clk_50m_in] \
    -group [get_clocks -include_generated_clocks -of_objects [get_nets clk_50m]] \
    -group [get_clocks -include_generated_clocks -of_objects [get_nets clk_125m]] \
    -group [get_clocks -include_generated_clocks -of_objects [get_nets clk_200m]] \
    -group [get_clocks rgmii_rxc] \
    -group [get_clocks -include_generated_clocks -of_objects [get_ports rgmii_txc]] \
    -group [get_clocks gtrefclk]

#-------------------------------------------------------------------
# RGMII TX output delay
#-------------------------------------------------------------------
set_output_delay -clock [get_clocks -of_objects [get_ports rgmii_txc]] \
    -max 1.000 [get_ports {rgmii_txd[*] rgmii_tx_ctl}]
set_output_delay -clock [get_clocks -of_objects [get_ports rgmii_txc]] \
    -min 0.000 [get_ports {rgmii_txd[*] rgmii_tx_ctl}]

#-------------------------------------------------------------------
# RGMII RX input delay
#-------------------------------------------------------------------
set_input_delay -clock rgmii_rxc -max 2.500 [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]
set_input_delay -clock rgmii_rxc -min 2.500 [get_ports {rgmii_rxd[*] rgmii_rx_ctl}]

#-------------------------------------------------------------------
# UART
#-------------------------------------------------------------------
set_input_delay -clock [get_clocks -of_objects [get_nets clk_50m]] -max 5.000 [get_ports uart_rx]
set_input_delay -clock [get_clocks -of_objects [get_nets clk_50m]] -min 1.000 [get_ports uart_rx]
set_output_delay -clock [get_clocks -of_objects [get_nets clk_50m]] -max 5.000 [get_ports uart_tx]
set_output_delay -clock [get_clocks -of_objects [get_nets clk_50m]] -min 1.000 [get_ports uart_tx]

#-------------------------------------------------------------------
# MDIO
#-------------------------------------------------------------------
set_output_delay -clock mdio_clk_eth0 -max 5.000 [get_ports eth0_mdc]
set_output_delay -clock mdio_clk_eth0 -min 1.000 [get_ports eth0_mdc]
set_output_delay -clock mdio_clk_eth0 -max 5.000 [get_ports eth0_mdio]
set_output_delay -clock mdio_clk_eth0 -min 1.000 [get_ports eth0_mdio]
set_input_delay  -clock mdio_clk_eth0 -max 5.000 [get_ports eth0_mdio]
set_input_delay  -clock mdio_clk_eth0 -min 1.000 [get_ports eth0_mdio]

#-------------------------------------------------------------------
# Misc slow outputs
#-------------------------------------------------------------------
set_output_delay -clock [get_clocks -of_objects [get_nets clk_50m]] \
    -max 10.000 [get_ports {rgmii_reset_l led_o[*] sfp1_tx_disable sfp2_tx_disable}]
set_output_delay -clock [get_clocks -of_objects [get_nets clk_50m]] \
    -min 0.000 [get_ports {rgmii_reset_l led_o[*] sfp1_tx_disable sfp2_tx_disable}]

#-------------------------------------------------------------------
# QSPI Flash (SPI mode, ~5MHz SCK from clock divider)
#-------------------------------------------------------------------
set_output_delay -clock [get_clocks -of_objects [get_nets clk_50m]] \
    -max 10.000 [get_ports {flash_cs_n flash_mosi flash_sclk flash_wp_n flash_rst_n}]
set_output_delay -clock [get_clocks -of_objects [get_nets clk_50m]] \
    -min 0.000 [get_ports {flash_cs_n flash_mosi flash_sclk flash_wp_n flash_rst_n}]
set_input_delay -clock [get_clocks -of_objects [get_nets clk_50m]] \
    -max 10.000 [get_ports flash_miso]
set_input_delay -clock [get_clocks -of_objects [get_nets clk_50m]] \
    -min 1.000 [get_ports flash_miso]

#-------------------------------------------------------------------
# Async reset
#-------------------------------------------------------------------
set_false_path -through [get_ports reset_l]

#-------------------------------------------------------------------
# CDC false paths (MDIO ↔ 50MHz)
#-------------------------------------------------------------------
set_false_path -from [get_clocks mdio_clk_eth0] \
    -to [get_clocks -of_objects [get_nets clk_50m]]
set_false_path -from [get_clocks -of_objects [get_nets clk_50m]] \
    -to [get_clocks mdio_clk_eth0]

#-------------------------------------------------------------------
# Cross-clock-domain false paths (SGMII ↔ system)
#-------------------------------------------------------------------
set_false_path -from [get_clocks gtrefclk] \
    -to [get_clocks -of_objects [get_nets clk_125m]]
set_false_path -from [get_clocks -of_objects [get_nets clk_125m]] \
    -to [get_clocks gtrefclk]
