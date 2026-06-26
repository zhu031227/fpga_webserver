#===================================================================
# pins.xdc — Xilinx XC7A35T-FGG484 pin assignments (ACX750 dev board)
#===================================================================

# --- 50 MHz clock input ---
set_property PACKAGE_PIN W19 [get_ports clk_50m_in]

# --- Reset (active low) ---
set_property PACKAGE_PIN D21 [get_ports reset_l]

# --- UART ---
set_property PACKAGE_PIN L21 [get_ports uart_rx]
set_property PACKAGE_PIN M21 [get_ports uart_tx]

# --- LED ---
set_property PACKAGE_PIN U22 [get_ports {led_o[0]}]
set_property PACKAGE_PIN V22 [get_ports {led_o[1]}]
set_property PACKAGE_PIN W21 [get_ports {led_o[2]}]
set_property PACKAGE_PIN W22 [get_ports {led_o[3]}]

# --- RGMII interface ---
set_property PACKAGE_PIN AB21 [get_ports rgmii_txc]
set_property PACKAGE_PIN P14  [get_ports rgmii_reset_l]
set_property PACKAGE_PIN Y18  [get_ports rgmii_rxc]
set_property PACKAGE_PIN P20  [get_ports {rgmii_rxd[0]}]
set_property PACKAGE_PIN N15  [get_ports {rgmii_rxd[1]}]
set_property PACKAGE_PIN AA18 [get_ports {rgmii_rxd[2]}]
set_property PACKAGE_PIN AB18 [get_ports {rgmii_rxd[3]}]
set_property PACKAGE_PIN T20  [get_ports rgmii_rx_ctl]
set_property PACKAGE_PIN AB20 [get_ports {rgmii_txd[0]}]
set_property PACKAGE_PIN Y19  [get_ports {rgmii_txd[1]}]
set_property PACKAGE_PIN AB22 [get_ports {rgmii_txd[2]}]
set_property PACKAGE_PIN W20  [get_ports {rgmii_txd[3]}]
set_property PACKAGE_PIN AA19 [get_ports rgmii_tx_ctl]

# --- MDIO ---
set_property PACKAGE_PIN R14 [get_ports eth0_mdc]
set_property PACKAGE_PIN U21 [get_ports eth0_mdio]

#===================================================================
# I/O Standards
#===================================================================

set_property IOSTANDARD LVCMOS33 [get_ports clk_50m_in]
set_property IOSTANDARD LVCMOS33 [get_ports reset_l]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_reset_l]
set_property IOSTANDARD LVCMOS33 [get_ports eth0_mdc]
set_property IOSTANDARD LVCMOS33 [get_ports eth0_mdio]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_txc]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_rxc]
set_property IOSTANDARD LVCMOS33 [get_ports {rgmii_rxd[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_rx_ctl]
set_property IOSTANDARD LVCMOS33 [get_ports {rgmii_txd[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports rgmii_tx_ctl]
