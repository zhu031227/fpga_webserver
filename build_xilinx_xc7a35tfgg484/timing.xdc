#===================================================================
# timing.xdc — Xilinx XC7A35T-FGG484 timing constraints
#===================================================================

# --- Input clock ---
create_clock -period 20.000 -name clk_50m_in [get_ports clk_50m_in]

# --- RGMII clocks (125 MHz DDR) ---
create_clock -period 8.000 -name rgmii_rxc [get_ports rgmii_rxc]
create_clock -period 8.000 -name rgmii_txc [get_ports rgmii_txc]

# --- Clock domain crossings ---
set_false_path -from [get_clocks rgmii_rxc] -to [get_clocks rgmii_txc]
set_false_path -from [get_clocks rgmii_txc] -to [get_clocks rgmii_rxc]

# --- PLL output clocks (async crossings) ---
set_false_path -from [get_clocks -of_objects [get_pins pll_inst_gen.U_PLL/inst/mmcm_adv_inst/CLKOUT0]] \
               -to   [get_clocks -of_objects [get_pins pll_inst_gen.U_PLL/inst/mmcm_adv_inst/CLKOUT1]]
set_false_path -from [get_clocks -of_objects [get_pins pll_inst_gen.U_PLL/inst/mmcm_adv_inst/CLKOUT1]] \
               -to   [get_clocks -of_objects [get_pins pll_inst_gen.U_PLL/inst/mmcm_adv_inst/CLKOUT0]]
set_false_path -from [get_clocks rgmii_rxc] \
               -to   [get_clocks -of_objects [get_pins pll_inst_gen.U_PLL/inst/mmcm_adv_inst/CLKOUT0]]
set_false_path -from [get_clocks rgmii_rxc] \
               -to   [get_clocks -of_objects [get_pins pll_inst_gen.U_PLL/inst/mmcm_adv_inst/CLKOUT1]]
