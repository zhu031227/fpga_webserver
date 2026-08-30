#===================================================================
# pins.xdc — Xilinx XC7A35T-FGG484 pin assignments (ACX750 dev board)
#===================================================================

# --- 配置模式：SPI x1 + MultiBoot Fallback ---
# 本工程作为 fpga_golden 的 update 镜像，被 golden 经 ICAP IPROG 跳到 0x400000 自举。
# 必须与 fpga_golden 的 pins.xdc 一致（XAPP1247：fallback 只走 x1）：
#   - SPIx1：golden 把 update 位流按 x1 bit-swap 写进 flash，update 自身也要 x1 读回。
#   - CONFIGFALLBACK：update 位流本身坏/缺失时，硬件弹回 0x0 的 golden。
set_property CONFIG_MODE SPIx1 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.CONFIGFALLBACK Enable [current_design]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# --- 50 MHz clock input ---
set_property PACKAGE_PIN W19 [get_ports clk_50m_in]

# --- Reset (active low) ---
set_property PACKAGE_PIN D21 [get_ports reset_l]

# --- GT 125MHz 差分参考时钟 (MGT_CLK1/DIFCLK125M = MGTREFCLK1P/N_216) ---
# 依据：ACX750_CB_PIN.xdc 行 85/86 + Vivado 封装库 xc7a35tfgg484-2 查询结果
set_property PACKAGE_PIN F10 [get_ports gtrefclk_p]
set_property PACKAGE_PIN E10 [get_ports gtrefclk_n]

# --- UART ---
set_property PACKAGE_PIN L21 [get_ports uart_rx]
set_property PACKAGE_PIN M21 [get_ports uart_tx]

# --- LED ---
set_property PACKAGE_PIN U22 [get_ports {led_o[0]}]
set_property PACKAGE_PIN V22 [get_ports {led_o[1]}]
set_property PACKAGE_PIN W21 [get_ports {led_o[2]}]
set_property PACKAGE_PIN W22 [get_ports {led_o[3]}]

# --- RGMII interface (eth0) ---
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

# --- eth0 MDIO ---
set_property PACKAGE_PIN R14 [get_ports eth0_mdc]
set_property PACKAGE_PIN U21 [get_ports eth0_mdio]

# --- SFP1 (eth1, GTPE2_CHANNEL X0Y0) ---
# GT serial pins auto-placed by GTPE2_CHANNEL LOC constraint in timing.xdc
set_property PACKAGE_PIN R17 [get_ports sfp1_tx_disable]

# --- SFP2 (eth2, GTPE2_CHANNEL X0Y1) ---
set_property PACKAGE_PIN V18 [get_ports sfp2_tx_disable]

# --- GT Reference Clock (125MHz differential, MGT_CLK1) ---
# Pins auto-assigned by Vivado; no manual LOC needed for MGT_CLK1_P/N

# --- QSPI Flash (MX25L12845) ---
set_property PACKAGE_PIN T19 [get_ports flash_cs_n]
set_property PACKAGE_PIN P22 [get_ports flash_mosi]
set_property PACKAGE_PIN R22 [get_ports flash_miso]
set_property PACKAGE_PIN P21 [get_ports flash_wp_n]
set_property PACKAGE_PIN R21 [get_ports flash_rst_n]

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

# SFP control
set_property IOSTANDARD LVCMOS33 [get_ports sfp1_tx_disable]
set_property IOSTANDARD LVCMOS33 [get_ports sfp2_tx_disable]

# QSPI Flash
set_property IOSTANDARD LVCMOS33 [get_ports flash_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports flash_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports flash_miso]
set_property IOSTANDARD LVCMOS33 [get_ports flash_wp_n]
set_property IOSTANDARD LVCMOS33 [get_ports flash_rst_n]
