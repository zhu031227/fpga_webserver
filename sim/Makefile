# ============================================================================
# Makefile — Verilator simulation for xilinx_xc7a35tfgg484_webserver_top
# ============================================================================
# Usage:
#   make          — compile + run
#   make wave     — open gtkwave
#   make clean    — remove build artifacts
# ============================================================================

VERILATOR = verilator
GTKWAVE   = gtkwave

# ---- Paths ----
IP_COMMON = /home/huamingh/work/ip_common
IP_RISCV  = /home/huamingh/work/ip_riscv
IP_LCPU   = /home/huamingh/work/ip_lcpu
FPGA_CPU  = /home/huamingh/work/fpga_cpu
RTL       = /home/huamingh/work/fpga_webserver/rtl
SIM       = /home/huamingh/work/fpga_webserver/sim

# ---- Top module ----
TOP  = xilinx_xc7a35tfgg484_webserver_top
EXE  = V$(TOP)

# ---- FPGA Webserver RTL ----
WEB_RTL = \
	$(SIM)/xilinx_xc7a35tfgg484_webserver_top.v \
	$(SIM)/webserver_wrapper.v \
	$(RTL)/reg_webserver.v \
	$(RTL)/cpu_channel.v

# ---- FPGA CPU shared ----
FPGA_CPU_RTL = $(SIM)/lcpu_riscv_wrapper.v

# ---- IP common RTL (exclude real rgmii* — use behavioral stubs instead) ----
IP_COMMON_RTL = \
	$(IP_COMMON)/rtl/async_signal_sync.v \
	$(IP_COMMON)/rtl/cdc_bus_sync.v \
	$(IP_COMMON)/rtl/cdc_bus_sync_vec.v \
	$(IP_COMMON)/rtl/clk_rst_ctrl.v \
	$(IP_COMMON)/rtl/clock_frequency_divider.v \
	$(IP_COMMON)/rtl/crc.v \
	$(IP_COMMON)/rtl/dual_clock_fifo.v \
	$(IP_COMMON)/rtl/dual_clock_simple_dual_port_ram.v \
	$(IP_COMMON)/rtl/dynamic_delay.v \
	$(IP_COMMON)/rtl/eth_presemble.v \
	$(IP_COMMON)/rtl/fifo2pktfifo_int.v \
	$(IP_COMMON)/rtl/fix_delay.v \
	$(IP_COMMON)/rtl/gmii2mac.v \
	$(IP_COMMON)/rtl/interval_timer.v \
	$(IP_COMMON)/rtl/lcpu_clock_cross.v \
	$(IP_COMMON)/rtl/lcpu_mdio.v \
	$(IP_COMMON)/rtl/lcpu_merge.v \
	$(IP_COMMON)/rtl/mac_rx.v \
	$(IP_COMMON)/rtl/mac_top.v \
	$(IP_COMMON)/rtl/mac_tx.v \
	$(IP_COMMON)/rtl/mdio_ctrl.v \
	$(IP_COMMON)/rtl/package_analyzer.v \
	$(IP_COMMON)/rtl/package_fifo_v2.v \
	$(IP_COMMON)/rtl/package_generator.v \
	$(IP_COMMON)/rtl/packet_stat.v \
	$(IP_COMMON)/rtl/pktfifo2ram_int_v2.v \
	$(IP_COMMON)/rtl/pktfifo_nr21w_merge.v \
	$(IP_COMMON)/rtl/pulse_clock_region_pass.v \
	$(IP_COMMON)/rtl/ram2pktfifo_int.v \
	$(IP_COMMON)/rtl/ramintf.v \
	$(IP_COMMON)/rtl/single_clock_fifo.v \
	$(IP_COMMON)/rtl/single_clock_simple_dual_port_ram.v \
	$(IP_COMMON)/rtl/single_clock_true_dual_port_ram.v \
	$(IP_COMMON)/rtl/sop_eop_gen.v \
	$(IP_COMMON)/rtl/tod.v

# ---- IP riscv RTL ----
IP_RISCV_RTL = \
	$(IP_RISCV)/rtl/picorv32.v \
	$(IP_RISCV)/rtl/riscv32intfbridge.v \
	$(IP_RISCV)/rtl/riscv32_localbus.v \
	$(IP_RISCV)/rtl/riscv32_top.v \
	$(IP_RISCV)/rtl/riscv_reg.v

# ---- LCPU BFM (simulation-only, local copy with reduced string width) ----
LCPU_BFM = $(SIM)/lcpu_bfm.sv

# ---- Simulation stubs (behavioral models) ----
SIM_STUBS = \
	$(SIM)/pll_50m_bypass.v \
	$(SIM)/fpga_build_time_sim.v \
	$(SIM)/vendor_stubs.sv

# ---- Testbench (C++) ----
TB_CPP = $(SIM)/tb_webserver.cpp

# ---- All Verilog/SystemVerilog sources ----
VERILOG_SRCS = \
	$(WEB_RTL) \
	$(FPGA_CPU_RTL) \
	$(IP_COMMON_RTL) \
	$(IP_RISCV_RTL) \
	$(LCPU_BFM) \
	$(SIM_STUBS)

# ---- Verilator flags ----
VERILATOR_FLAGS = \
	--timing \
	--trace \
	--public-depth 2 \
	-Wno-fatal \
	-Wno-lint \
	-Wno-style \
	-Wno-COMBDLY \
	-Wno-INITIALDLY \
	-O3 \
	-CFLAGS "-O2"

# ---- Targets ----
.PHONY: all compile run wave clean

all: run

compile: obj_dir/$(EXE)

obj_dir/V$(TOP).mk: $(VERILOG_SRCS) $(TB_CPP)
	@echo "== Verilator: compiling $(TOP) =="
	$(VERILATOR) $(VERILATOR_FLAGS) \
		--cc --exe $(TB_CPP) \
		--top-module $(TOP) \
		$(VERILOG_SRCS)
	@echo "== Verilog → C++ done =="

obj_dir/$(EXE): obj_dir/V$(TOP).mk
	@echo "== Building C++ executable =="
	$(MAKE) -C obj_dir -f V$(TOP).mk $(EXE)
	@echo "== Build done: $@ =="

run: obj_dir/$(EXE)
	@echo "== Running simulation =="
	./obj_dir/$(EXE)
	@echo "== Simulation complete =="

wave:
	@if [ -f xilinx_xc7a35tfgg484_webserver_top_verilator.vcd ]; then \
		echo "Opening gtkwave..."; \
		$(GTKWAVE) xilinx_xc7a35tfgg484_webserver_top_verilator.vcd & \
	else \
		echo "No VCD found. Run 'make run' first."; \
		exit 1; \
	fi

clean:
	rm -rf obj_dir/ *.vcd *.vvp
	@echo "== Cleaned =="
