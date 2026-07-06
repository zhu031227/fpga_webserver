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

# --- CDC false paths (async FIFO / synchronizer handles these) ---
# eth0_rxc ↔ clk_125m (gmii2mac dual_clock_fifo)
set_false_path -from [get_clocks {eth0_rxc}] -to [get_clocks {clk_125m}]
set_false_path -from [get_clocks {clk_125m}] -to [get_clocks {eth0_rxc}]
# eth0_rxc ↔ clk_50m (GMII stats CDC)
set_false_path -from [get_clocks {eth0_rxc}] -to [get_clocks {clk_50m}]
set_false_path -from [get_clocks {clk_50m}] -to [get_clocks {eth0_rxc}]
# clk_125m ↔ clk_50m (cpu_channel CDC)
set_false_path -from [get_clocks {clk_125m}] -to [get_clocks {clk_50m}]
set_false_path -from [get_clocks {clk_50m}] -to [get_clocks {clk_125m}]
# clk_50m ↔ mdio_clk (MDIO CDC)
set_false_path -from [get_clocks {clk_50m}] -to [get_clocks {mdio_clk}]
set_false_path -from [get_clocks {mdio_clk}] -to [get_clocks {clk_50m}]
# clk_50m_in ↔ clk_125m (PLL input vs internal, reset CDC)
set_false_path -from [get_clocks {clk_50m_in}] -to [get_clocks {clk_125m}]
set_false_path -from [get_clocks {clk_125m}] -to [get_clocks {clk_50m_in}]


