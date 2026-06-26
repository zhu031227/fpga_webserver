# ============================================================================
# Makefile — RISC-V firmware build for FPGA WebServer
# ============================================================================
# Usage:
#   make            — full build (elf → bin → pads → tcl/hex/verilog)
#   make elf        — compile + link only (firmware.elf)
#   make bin        — firmware.bin
#   make pads       — firmware_pads.bin
#   make tcl        — generate ../tcl/InstructRAM.tcl
#   make verilog    — generate ../rtl/InstructRAM.v
#   make hex        — generate ../rtl/InstructRAM.hex
#   make clean      — remove all build outputs
#   make disasm     — disassemble firmware.elf
#   make info       — show toolchain info

# ---- Toolchain ----
CROSS     = riscv64-unknown-elf
CC        = $(CROSS)-gcc
OBJCOPY   = $(CROSS)-objcopy
OBJDUMP   = $(CROSS)-objdump
PYTHON    = python3

# ---- Build configuration ----
BIN_SIZE  = 16384
ARCH      = rv32ic
ABI       = ilp32

# Sysroot from system picolibc (provides stdlib.h, string.h, etc.)
SYSROOT   = /usr/lib/picolibc/riscv64-unknown-elf
SYS_INC   = -isystem $(SYSROOT)/include
SYS_LIB   = -L$(SYSROOT)/lib/rv32iac/ilp32

CFLAGS    = -march=$(ARCH) -mabi=$(ABI) -msmall-data-limit=0 -mno-save-restore \
            -O2 -ffunction-sections -fdata-sections -Wall -Wextra $(SYS_INC)
LDFLAGS   = -march=$(ARCH) -mabi=$(ABI) -nostdlib -Wl,--gc-sections $(SYS_LIB)

# ---- Paths ----
C_DIR     = ../c
INC_DIR   = $(C_DIR)/inc
RTL_DIR   = ../rtl
TCL_DIR   = ../tcl
OUT_DIR   = out
LINKER    = linker.ld
SCRIPTS   = .

# ---- Sources & objects ----
C_SRCS    = $(wildcard $(C_DIR)/*.c)
C_OBJS    = $(patsubst $(C_DIR)/%.c, $(OUT_DIR)/%.o, $(C_SRCS))

# ---- Outputs ----
ELF       = $(OUT_DIR)/firmware.elf
BIN       = $(OUT_DIR)/firmware.bin
PADS      = $(OUT_DIR)/firmware_pads.bin
DISASM    = $(OUT_DIR)/firmware.disasm
BUILD_TIME_H = $(OUT_DIR)/build_time.h
TCL_OUT   = $(TCL_DIR)/InstructRAM.tcl
VERILOG_OUT = $(RTL_DIR)/InstructRAM.v
HEX_OUT   = $(RTL_DIR)/InstructRAM.hex

# ---- Targets ----
.PHONY: all elf bin pads tcl verilog hex clean disasm info

# ---- Platform selection ----
# Usage: make PLATFORM=xilinx  (or PLATFORM=intel)
#        make                  (interactive prompt, default: xilinx)
# Skip prompt for non-build targets (clean, disasm, info, etc.)
NEED_PLATFORM := $(if $(filter clean disasm info,$(MAKECMDGOALS)),,1)
ifeq ($(NEED_PLATFORM),1)
  ifndef PLATFORM
    PLATFORM := $(shell bash -c 'read -p "Select platform [xilinx/intel] (default: xilinx): " p; echo $${p:-xilinx}')
  endif
else
  PLATFORM := none
endif

ifeq ($(PLATFORM),intel)
  INSTR_ADDR_DEPTH := $(shell grep -oP 'instr_addr_depth\s*=\s*\K[0-9 *]+' /home/huamingh/work/fpga_webserver/rtl/altera_ep4ce10f17c6_webserver_top.v 2>/dev/null | head -1 | sed 's/ //g')
else
  INSTR_ADDR_DEPTH := $(shell grep -oP 'instr_addr_depth\s*=\s*\K[0-9 *]+' /home/huamingh/work/fpga_webserver/rtl/xilinx_xc7a35tfgg484_webserver_top.v 2>/dev/null | head -1 | sed 's/ //g')
endif

ifeq ($(INSTR_ADDR_DEPTH),)
  INSTR_ADDR_DEPTH := 12288
else
  INSTR_ADDR_DEPTH := $(shell echo $$(($(INSTR_ADDR_DEPTH))))
endif

all: $(BUILD_TIME_H) $(PADS) $(VERILOG_OUT) $(HEX_OUT) $(TCL_OUT)
	@echo ""
	@echo "============================================"
	@echo "  Build Summary  (platform: $(PLATFORM))"
	@echo "============================================"
	@echo "  Instruction space : $(INSTR_ADDR_DEPTH) x 32-bit words ($(shell echo $$(($(INSTR_ADDR_DEPTH) * 4))) bytes)"
	@$(PYTHON) -c "import pathlib,os; \
	sz=pathlib.Path('$(BIN)').stat().st_size; \
	w=(sz+3)//4; \
	d=int('$(INSTR_ADDR_DEPTH)'); \
	pct=w*100//d; \
	print(f'  Firmware size     : {sz} bytes, {w} words ({pct}% of {d} words)')"
	@echo "  ELF  : $(ELF)"
	@echo "  BIN  : $(BIN)"
	@echo "  PADS : $(PADS)"
	@echo "  VERILOG: $(VERILOG_OUT)"
	@echo "  HEX  : $(HEX_OUT)"
	@echo "  TCL  : $(TCL_OUT)"

# ---- Generate build_time.h (no source stamp pollution) ----
$(OUT_DIR):
	mkdir -p $(OUT_DIR)

$(BUILD_TIME_H): | $(OUT_DIR)
	@echo "  GEN  $@"
	@echo "#ifndef _BUILD_TIME_H_" > $@
	@echo "#define _BUILD_TIME_H_" >> $@
	@echo "#define SW_BUILD_DATE 32'h$$(date +%Y)$$(date +%m)$$(date +%d)" >> $@
	@echo "#define SW_BUILD_TIME 32'h$$(date +%H)$$(date +%M)0000" >> $@
	@echo "#endif // _BUILD_TIME_H_" >> $@

# ---- Compile ----
$(OUT_DIR)/%.o: $(C_DIR)/%.c $(BUILD_TIME_H) | $(OUT_DIR)
	@echo "  CC   $<"
	$(CC) -c $< -I$(INC_DIR) -I$(OUT_DIR) $(CFLAGS) -o $@

# ---- Link ----
elf: $(ELF)
$(ELF): $(C_OBJS) $(LINKER) | $(OUT_DIR)
	@echo "  LD   $@"
	$(CC) $(C_OBJS) -T $(LINKER) $(LDFLAGS) -lc -lgcc -o $@

# ---- Binary ----
bin: $(BIN)
$(BIN): $(ELF)
	@echo "  OBJCOPY $@"
	$(OBJCOPY) -O binary $< $@

# ---- Pad ----
pads: $(PADS)
$(PADS): $(BIN)
	@echo "  PAD  $@ ($(BIN_SIZE) bytes)"
	$(PYTHON) -c "\
import pathlib, sys; \
BIN_SIZE=$(BIN_SIZE); \
src=pathlib.Path('$<').read_bytes(); \
src_len=len(src); \
print(f'  size: {src_len} bytes (limit {BIN_SIZE})'); \
assert src_len <= BIN_SIZE, f'Firmware too large: {src_len} > {BIN_SIZE}'; \
pathlib.Path('$@').write_bytes(src + b'\x00' * (BIN_SIZE - src_len)); \
print(f'  words: {(src_len+3)//4} used / {BIN_SIZE//4} total'); \
"

# ---- TCL JTAG load script ----
tcl: $(TCL_OUT)
$(TCL_OUT): $(PADS) $(SCRIPTS)/bin_to_tcl.py
	@echo "  TCL  $@"
	$(PYTHON) $(SCRIPTS)/bin_to_tcl.py $< $@ 0x00010000

# ---- Verilog RAM init ----
verilog: $(VERILOG_OUT)
$(VERILOG_OUT): $(PADS) $(SCRIPTS)/bin_to_verilog_para.py
	@echo "  VERILOG $@"
	$(PYTHON) $(SCRIPTS)/bin_to_verilog_para.py $< $@ $(BIN_SIZE)

# ---- Quartus HEX ----
hex: $(HEX_OUT)
$(HEX_OUT): $(PADS) $(SCRIPTS)/bin_to_quartus_hex.py
	@echo "  HEX  $@"
	$(PYTHON) $(SCRIPTS)/bin_to_quartus_hex.py $< $@ $(BIN_SIZE)

# ---- Disassemble ----
disasm: $(DISASM)
$(DISASM): $(ELF)
	@echo "  OBJDUMP $@"
	$(OBJDUMP) -d -M no-aliases $< > $@
	@echo "  Disassembly written to $@"

# ---- Clean ----
clean:
	rm -rf $(OUT_DIR)
	@echo "  Cleaned c_build/out/"

# ---- Info ----
info:
	@echo "Toolchain : $(CC)"
	@echo "  version : $$($(CC) --version | head -1)"
	@echo "Arch/ABI  : $(ARCH) / $(ABI)"
	@echo "ROM size  : $(BIN_SIZE) bytes"
	@echo "C sources : $(words $(C_SRCS)) files"
	@echo "Linker    : $(LINKER)"
	@$(foreach s,$(C_SRCS),echo "           $(notdir $s)";)
