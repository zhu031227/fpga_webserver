# ============================================================================
# Makefile — FPGA WebServer simulation
# ============================================================================
# Usage:
#   make sim SIM=icarus      — Icarus Verilog simulation
#   make sim SIM=verilator   — Verilator simulation
#   make wave                — Open GTKWave viewer
#   make clean               — Remove build artifacts
#
# Default simulator: icarus
SIM ?= icarus

# ---- Paths ----
RTL_DIR  = ../rtl
SIM_DIR  = .
OUT_DIR  = out

# DUT RTL files (project-specific)
DUT_RTL  = $(RTL_DIR)/webserver_wrapper.v \
           $(RTL_DIR)/reg_webserver.v \
           $(RTL_DIR)/cpu_channel.v \
           $(RTL_DIR)/xilinx_xc7a35tfgg484_webserver_top.v

# Simulation-only files
SIM_SRC  = $(SIM_DIR)/tb_webserver.sv \
           $(SIM_DIR)/define.sv \
           $(SIM_DIR)/pll_bypass.v \
           $(SIM_DIR)/InstructRAM.v \
           $(SIM_DIR)/lcpu_bfm.sv

# External IP paths (relative — populated by build_fpga.sh or manual clone)
IP_LCPU   = ../ip_lcpu/rtl
IP_RISCV  = ../ip_riscv/rtl
IP_COMMON = ../ip_common/rtl

IP_RTL   = $(IP_LCPU)/lcpu_top.v \
           $(IP_LCPU)/jtag_cpu_xilinx.v \
           $(IP_RISCV)/picorv32.v \
           $(IP_RISCV)/riscv32_top.v \
           $(IP_RISCV)/riscv32_localbus.v \
           $(IP_RISCV)/riscv_reg.v \
           $(IP_RISCV)/riscv32intfbridge.v \
           $(IP_COMMON)/lcpu_merge.v \
           $(IP_COMMON)/gmii2mac.v \
           $(IP_COMMON)/rgmii2gmii.v \
           $(IP_COMMON)/lcpu_mdio.v \
           $(IP_COMMON)/ram2pktfifo_int.v \
           $(IP_COMMON)/pktfifo2ram_int_v2.v \
           $(IP_COMMON)/package_fifo_v2.v \
           $(IP_COMMON)/sop_eop_gen.v \
           $(IP_COMMON)/dual_clock_fifo.v \
           $(IP_COMMON)/fifo2pktfifo_int.v \
           $(IP_COMMON)/eth_presemble.v \
           $(IP_COMMON)/crc.v \
           $(IP_COMMON)/mac_rx.v \
           $(IP_COMMON)/mac_top.v \
           $(IP_COMMON)/ramintf.v

# ---- Icarus Verilog ----
ifeq ($(SIM),icarus)
IVL       = iverilog
VVP       = vvp
IVL_FLAGS = -g2012 -Wall -DIVL_SIM -I$(SIM_DIR) -I$(RTL_DIR)

TOP_VVP   = $(OUT_DIR)/tb_webserver.vvp
VCD_FILE  = $(OUT_DIR)/tb_webserver.vcd
VENDOR_STUB = $(SIM_DIR)/vendor_stubs.v

sim: $(TOP_VVP)
	@echo "Running simulation..."
	$(VVP) -n $(TOP_VVP) -vcd
	@echo "Waveform: $(VCD_FILE)"

$(TOP_VVP): $(DUT_RTL) $(SIM_SRC) $(VENDOR_STUB) | $(OUT_DIR)
	@echo "Compiling with Icarus Verilog..."
	$(IVL) $(IVL_FLAGS) -o $@ \
	    $(VENDOR_STUB) \
	    $(IP_RTL) \
	    $(DUT_RTL) \
	    $(SIM_SRC)
endif

# ---- Verilator ----
ifeq ($(SIM),verilator)
VERILATOR = verilator
VL_FLAGS  = --timing -Wall -Wno-fatal -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND \
            -Wno-IMPLICIT -Wno-UNOPTFLAT \
            +define+VERILATOR +define+IVL_SIM -I$(SIM_DIR) -I$(RTL_DIR)

VL_OBJ_DIR = $(OUT_DIR)/obj_dir
VL_BIN     = $(VL_OBJ_DIR)/Vtb_webserver
VENDOR_STUB = $(SIM_DIR)/vendor_stubs.sv

sim: $(VL_BIN)
	@echo "Running simulation..."
	$(VL_BIN)

$(VL_BIN): $(DUT_RTL) $(SIM_SRC) $(VENDOR_STUB) | $(OUT_DIR)
	@echo "Compiling with Verilator..."
	$(VERILATOR) --cc --exe --build -j \
	    $(VL_FLAGS) \
	    $(VENDOR_STUB) \
	    $(IP_RTL) \
	    $(DUT_RTL) \
	    $(SIM_SRC) \
	    --Mdir $(VL_OBJ_DIR) \
	    --top-module tb_webserver
endif

# ---- Output directory ----
$(OUT_DIR):
	mkdir -p $(OUT_DIR)

# ---- Waveform viewer ----
wave:
ifeq ($(SIM),verilator)
	gtkwave $(OUT_DIR)/simx.vcd $(SIM_DIR)/top_wave.gtkw 2>/dev/null || \
	gtkwave $(OUT_DIR)/simx.vcd
else
	gtkwave $(VCD_FILE) $(SIM_DIR)/top_wave.gtkw 2>/dev/null || \
	gtkwave $(VCD_FILE)
endif

# ---- Clean ----
clean:
	rm -rf $(OUT_DIR)

.PHONY: sim wave clean
