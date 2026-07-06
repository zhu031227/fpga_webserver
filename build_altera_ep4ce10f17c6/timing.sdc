#===================================================================
# timing.sdc — EP4CE10F17C6 timing constraints (Quartus SDC format)
#===================================================================

# --- Input clock 50 MHz (period 20 ns) ---
create_clock -period 20.000 -name clk_50m_in [get_ports clk_50m_in]

# --- PLL output clocks ---
# PLL hierarchy: g_clk_pll.u_pll|altpll_component|auto_generated|pll1
# NOTE: fit report shows clk[1] = 100.0 MHz, NOT 125 MHz.
#       Check pll_50m megafunction config if 125 MHz is required.
create_generated_clock -name clk_50m  -source [get_ports clk_50m_in] -multiply_by 1 -divide_by 1 [get_pins {g_clk_pll.u_pll|altpll_component|auto_generated|pll1|clk[0]}]
create_generated_clock -name clk_125m -source [get_ports clk_50m_in] -multiply_by 5 -divide_by 2 [get_pins {g_clk_pll.u_pll|altpll_component|auto_generated|pll1|clk[1]}]

# --- GMII RX clock 125 MHz (period 8 ns) ---
create_clock -period 8.000 -name eth0_rxc [get_ports eth0_rxc]

# --- MDIO clock 1 MHz (derived from 50 MHz / 50) ---
create_generated_clock -name mdio_clk -source [get_ports clk_50m_in] -divide_by 50 [get_nets {webserver_wrapper:u_webserver|lcpu_mdio:u_lcpu_mdio_eth0|clock_frequency_divider:u_clock_frequency_divider|clk_out}]

# --- Clock uncertainty ---
derive_clock_uncertainty

set_false_path -from [get_clocks {eth0_rxc}] -to [get_clocks {clk_50m_in}]; set_false_path -from [get_clocks {eth0_rxc}] -to [get_clocks {clk_50m_in}]


