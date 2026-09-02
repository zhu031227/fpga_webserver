# ============================================================================
# Makefile — Verilator simulation for FPGA WebServer
# ============================================================================
# Usage:
#   make            — compile + run (fast, no waveform)
#   make wave       — compile + run with waveform VCD
#   make clean      — remove build artifacts
# ============================================================================

VERILATOR = verilator

# ---- Paths ----
IP_COMMON = $(HOME)/work/ip_common
IP_RISCV  = $(HOME)/work/ip_riscv
IP_LCPU   = $(HOME)/work/ip_lcpu
FPGA_CPU  = $(HOME)/work/fpga_cpu
RTL       = $(HOME)/work/fpga_webserver/rtl
SIM       = $(HOME)/work/fpga_webserver/sim

# ---- Top module ----
TOP = tb_webserver
EXE = V$(TOP)

# ---- FPGA Webserver RTL (use OLD single-port versions for Verilator sim) ----
# The current rtl/ has 3-port + SFP modules with Xilinx primitives.
# For ARP/HTTP simulation we only need eth0 RGMII, so use the old RTL.
OLD_RTL = $(HOME)/work/fpga_webserver/webserver_xilinx_xc7a35tfgg484_v0052_20260707_112204/rtl
WEB_RTL = \
	$(OLD_RTL)/xilinx_xc7a35tfgg484_webserver_top.v \
	$(OLD_RTL)/webserver_wrapper.v \
	$(OLD_RTL)/reg_webserver.v \
	$(OLD_RTL)/cpu_channel.v

# ---- FPGA CPU shared ----
FPGA_CPU_RTL = $(FPGA_CPU)/rtl/lcpu_riscv_wrapper.v

# ---- IP common RTL (exclude rgmii* — behavioral in vendor_stubs.sv) ----
IP_COMMON_RTL = \
	$(IP_COMMON)/rtl/async_signal_sync.v \
	$(IP_COMMON)/rtl/cdc_bus_sync.sv \
	$(IP_COMMON)/rtl/cdc_bus_sync_vec.sv \
	$(IP_COMMON)/rtl/clk_rst_ctrl.sv \
	$(IP_COMMON)/rtl/clock_frequency_divider.v \
	$(IP_COMMON)/rtl/crc.v \
	$(IP_COMMON)/rtl/dual_clock_fifo.v \
	$(IP_COMMON)/rtl/dual_clock_simple_dual_port_ram.v \
	$(IP_COMMON)/rtl/dual_clock_true_dual_port_ram.v \
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
	$(IP_COMMON)/rtl/single_clock_stack.v \
	$(IP_COMMON)/rtl/single_clock_true_dual_port_ram.v \
	$(IP_COMMON)/rtl/sop_eop_gen.v \
	$(IP_COMMON)/rtl/tod.v \
	$(IP_COMMON)/rtl/uart.v \
	$(IP_COMMON)/rtl/uart_rx.v \
	$(IP_COMMON)/rtl/uart_tx.v

# ---- IP riscv RTL ----
IP_RISCV_RTL = \
	$(IP_RISCV)/rtl/picorv32.v \
	$(IP_RISCV)/rtl/riscv32intfbridge.v \
	$(IP_RISCV)/rtl/riscv32_localbus.v \
	$(IP_RISCV)/rtl/riscv32_top.v \
	$(IP_RISCV)/rtl/riscv_reg.v

# ---- IP LCPU RTL ----
IP_LCPU_RTL = \
	$(IP_LCPU)/rtl/lcpu_top.v \
	$(IP_LCPU)/rtl/uart_lcpu_top.v \
	$(IP_LCPU)/rtl/uart_lcpu.v \
	$(IP_LCPU)/rtl/jtag_cpu_xilinx.v

# ---- LCPU BFM (local copy, Verilator-compatible $fgetc parser) ----
LCPU_BFM = $(SIM)/lcpu_bfm.sv

# ---- Simulation support ----
SIM_SUPPORT = \
	$(SIM)/vendor_stubs.sv \
	$(SIM)/pll_50m_bypass.v \
	$(SIM)/fpga_build_time_sim.v \
	$(SIM)/stub_jtag_axi.sv \
	$(SIM)/stub_xpm_memory.sv

# ---- Testbench ----
TB_SV  = $(SIM)/tb_webserver.sv
TB_CPP = $(SIM)/tb_webserver.cpp

# ---- All Verilog sources ----
VERILOG_SRCS = \
	$(TB_SV) \
	$(WEB_RTL) \
	$(FPGA_CPU_RTL) \
	$(IP_COMMON_RTL) \
	$(IP_RISCV_RTL) \
	$(IP_LCPU_RTL) \
	$(LCPU_BFM) \
	$(SIM_SUPPORT)

# ---- Include paths ----
VERILATOR_INC = \
	+incdir+$(RTL) \
	+incdir+$(FPGA_CPU)/rtl \
	+incdir+$(IP_LCPU)/rtl \
	+incdir+$(IP_COMMON)/rtl \
	+incdir+$(IP_RISCV)/rtl

# ---- Verilator flags ----
VERILATOR_BASE = \
	--timing \
	--timescale-override 1ns/1ps \
	--public-depth 8 \
	-Wno-fatal \
	-Wno-lint \
	-Wno-style \
	-Wno-COMBDLY \
	-Wno-INITIALDLY \
	-O3 \
	-CFLAGS "-O2" \
	$(VERILATOR_INC)

# ---- Output ----
VCD = $(TOP)_verilator.vcd
LOCAL_TCL = $(SIM)/InstructRAM_local.tcl

# ============================================================================
# Targets
# ============================================================================
.PHONY: all wave clean arp arp_wave

all: $(LOCAL_TCL) run

$(LOCAL_TCL): ../tcl/InstructRAM.tcl patch_tcl.py
	@echo "== Patching TCL: BSS zeroing =="
	@python3 patch_tcl.py

# ---- Fast mode (no waveform) ----
run: obj_dir/$(EXE)
	@echo "== Running simulation (fast, no VCD) =="
	./obj_dir/$(EXE)
	@echo "== Done =="

obj_dir/$(EXE): obj_dir/V$(TOP).mk
	@echo "== Building C++ executable (fast) =="
	$(MAKE) -C obj_dir -f V$(TOP).mk $(EXE)
	@echo "== Build done =="

obj_dir/V$(TOP).mk: $(VERILOG_SRCS) $(TB_CPP)
	@echo "== Verilator: compiling $(TOP) (fast, no trace) =="
	$(VERILATOR) $(VERILATOR_BASE) \
		--cc --exe $(TB_CPP) \
		--top-module $(TOP) \
		-Mdir obj_dir \
		$(VERILOG_SRCS)
	@echo "== Verilog -> C++ done =="

# ---- Wave mode (with VCD) ----
wave: $(LOCAL_TCL) obj_dir_wave/$(EXE)
	@echo "== Running simulation with waveform =="
	./obj_dir_wave/$(EXE)
	@echo "== Done: $(VCD) =="

obj_dir_wave/$(EXE): obj_dir_wave/V$(TOP).mk
	@echo "== Building C++ executable (wave) =="
	$(MAKE) -C obj_dir_wave -f V$(TOP).mk $(EXE)
	@echo "== Build done =="

obj_dir_wave/V$(TOP).mk: $(VERILOG_SRCS) $(TB_CPP)
	@echo "== Verilator: compiling $(TOP) (trace enabled) =="
	$(VERILATOR) $(VERILATOR_BASE) --trace \
		--cc --exe $(TB_CPP) \
		--top-module $(TOP) \
		-Mdir obj_dir_wave \
		$(VERILOG_SRCS)
	@echo "== Verilog -> C++ done =="

# ---- ARP test (fast, no waveform) ----
ARP_EXE = V$(TOP)
ARP_CPP  = $(SIM)/tb_webserver_arp.cpp

arp: $(LOCAL_TCL) obj_dir_arp/$(ARP_EXE)
	@echo "== Running ARP simulation (fast, no VCD) =="
	./obj_dir_arp/$(ARP_EXE)
	@echo "== ARP Done =="

obj_dir_arp/$(ARP_EXE): obj_dir_arp/V$(TOP).mk
	@echo "== Building C++ executable (ARP) =="
	$(MAKE) -C obj_dir_arp -f V$(TOP).mk $(ARP_EXE)
	@echo "== Build done =="

obj_dir_arp/V$(TOP).mk: $(VERILOG_SRCS) $(ARP_CPP)
	@echo "== Verilator: compiling $(TOP) for ARP test =="
	$(VERILATOR) $(VERILATOR_BASE) \
		--cc --exe $(ARP_CPP) \
		--top-module $(TOP) \
		-Mdir obj_dir_arp \
		$(VERILOG_SRCS)
	@echo "== Verilog -> C++ done =="

# ---- ARP test with waveform ----
arp_wave: $(LOCAL_TCL) obj_dir_arp_wave/$(ARP_EXE)
	@echo "== Running ARP simulation with waveform =="
	./obj_dir_arp_wave/$(ARP_EXE)
	@echo "== ARP Done: tb_webserver_arp.vcd =="

obj_dir_arp_wave/$(ARP_EXE): obj_dir_arp_wave/V$(TOP).mk
	@echo "== Building C++ executable (ARP wave) =="
	$(MAKE) -C obj_dir_arp_wave -f V$(TOP).mk $(ARP_EXE)
	@echo "== Build done =="

obj_dir_arp_wave/V$(TOP).mk: $(VERILOG_SRCS) $(ARP_CPP)
	@echo "== Verilator: compiling $(TOP) for ARP test (trace) =="
	$(VERILATOR) $(VERILATOR_BASE) --trace \
		--cc --exe $(ARP_CPP) \
		--top-module $(TOP) \
		-Mdir obj_dir_arp_wave \
		$(VERILOG_SRCS)
	@echo "== Verilog -> C++ done =="

# ---- Clean ----
clean:
	rm -rf obj_dir/ obj_dir_wave/ obj_dir_arp/ obj_dir_arp_wave/ *.vcd $(LOCAL_TCL)
	@echo "== Cleaned =="
