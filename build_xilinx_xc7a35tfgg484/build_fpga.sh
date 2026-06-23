#!/bin/bash
#=============================================================================
# build_fpga.sh — Xilinx XC7A35T-FGG484 FPGA WebServer build script
#=============================================================================
# Usage:
#   ./build_fpga.sh <version>
#
# Creates a versioned Vivado project, clones IP repos, runs full
# synthesis + implementation + bitstream generation.
#=============================================================================

set -euo pipefail

# 1. Version check
if [ $# -lt 1 ]; then
    echo "Usage: $0 <version>"
    echo "  version : 1~4 hex digits (e.g. 001, a, ff, ffff)"
    exit 1
fi

VERSION_RAW="$1"
if [[ ! "${VERSION_RAW}" =~ ^[0-9a-fA-F]{1,4}$ ]]; then
    echo "ERROR: Version must be 1~4 hex digits"
    exit 1
fi

VERSION=$(printf '%04s' "$(echo "${VERSION_RAW}" | tr '[:upper:]' '[:lower:]')" | tr ' ' '0')

# 2. Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FPGA_WS_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$(dirname "$FPGA_WS_DIR")"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PROJ_NAME="xilinx_xc7a35tfgg484_v${VERSION}_${TIMESTAMP}"
PROJ_DIR="${FPGA_WS_DIR}/${PROJ_NAME}"

echo "============================================"
echo " FPGA WebServer Build (Xilinx)"
echo " Target : XC7A35T-FGG484"
echo " Version: ${VERSION}"
echo " Project: ${PROJ_NAME}"
echo "============================================"

# 3. Create project dir
mkdir -p "${PROJ_DIR}"
echo "[STEP 1/7] Project directory created."

# 4. Clone IP repos
echo "[STEP 2/7] Cloning IP repositories..."

clone_repo() {
    local local_src="$1"; local remote_url="$2"; local dst="$3"; local label="$4"
    echo -n "  Cloning ${label} (rtl only)... "
    if [ -d "${local_src}" ]; then
        echo "from local cache"
        git clone --no-checkout "${local_src}" "${dst}" > /dev/null 2>&1
    else
        echo "from GitHub"
        git clone --no-checkout "${remote_url}" "${dst}" > /dev/null 2>&1
    fi
    (cd "${dst}"; git sparse-checkout set --no-cone 'rtl/*' > /dev/null 2>&1; git checkout > /dev/null 2>&1)
    echo "    -> ${dst}/rtl/"
}

clone_repo "${WORK_DIR}/ip_lcpu"   "git@github.com:HuanghmBuck/ip_lcpu.git"   "${PROJ_DIR}/ip_lcpu"   "ip_lcpu"
clone_repo "${WORK_DIR}/ip_riscv"  "git@github.com:HuanghmBuck/ip_riscv.git"  "${PROJ_DIR}/ip_riscv"  "ip_riscv"
clone_repo "${WORK_DIR}/ip_common" "git@github.com:HuanghmBuck/ip_common.git" "${PROJ_DIR}/ip_common" "ip_common"

echo "[STEP 2/7] Done."

# 5. Generate corrected filelist.cfg
echo "[STEP 3/7] Generating filelist.cfg..."
sed -e 's|^rtl/|../rtl/|' \
    -e 's|^ip_vendor/|../ip_vendor/|' \
    -e 's|^\.\./ip_lcpu/|ip_lcpu/|' \
    -e 's|^\.\./ip_riscv/|ip_riscv/|' \
    -e 's|^\.\./ip_common/|ip_common/|' \
    "${SCRIPT_DIR}/filelist.cfg" > "${PROJ_DIR}/filelist.cfg"
echo "[STEP 3/7] Done."

# 6. Generate fpga_build_time.v
echo "[STEP 4/7] Generating fpga_build_time.v..."
BUILD_DATE=$(printf "32'h%04d%02d%02d" "$((10#$(date +%Y)))" "$((10#$(date +%m)))" "$((10#$(date +%d)))")
BUILD_TIME=$(printf "32'h%02d%02d%04s" "$((10#$(date +%H)))" "$((10#$(date +%M)))" "${VERSION}" | tr ' ' '0')

cat > "${PROJ_DIR}/fpga_build_time.v" << EOF
module fpga_build_time (
    output wire [31:0] build_date,
    output wire [31:0] build_time
);
    assign build_date = ${BUILD_DATE};
    assign build_time = ${BUILD_TIME};
endmodule
EOF
echo "[STEP 4/7] Done."

# 7. Copy constraints
echo "[STEP 5/7] Copying constraints..."
cp "${SCRIPT_DIR}/pins.xdc"   "${PROJ_DIR}/pins.xdc"
cp "${SCRIPT_DIR}/timing.xdc" "${PROJ_DIR}/timing.xdc"
echo "[STEP 5/7] Done."

# 8. Generate Vivado TCL script and run
echo "[STEP 6/7] Generating Vivado TCL script..."

TCL_SCRIPT="${PROJ_DIR}/build.tcl"
TOP_MODULE="xilinx_xc7a35tfgg484_webserver_top"

cat > "${TCL_SCRIPT}" << TCL_EOF
set proj_name [lindex \$argv 0]
set proj_dir  [lindex \$argv 1]
set top_module "${TOP_MODULE}"

puts "============================================"
puts " Vivado WebServer Build"
puts " Project : \$proj_name"
puts "============================================"

create_project -force \$proj_name \$proj_dir -part xc7a35tfgg484-2

# Parse filelist.cfg
set cfg_file [open "\$proj_dir/filelist.cfg" r]
set cfg_data [read \$cfg_file]
close \$cfg_file

set file_list {}
set xci_list {}
foreach line [split \$cfg_data "\n"] {
    set line [string trim \$line]
    if {\$line eq "" || [string match "#*" \$line]} { continue }
    set comment_idx [string first "#" \$line]
    if {\$comment_idx >= 0} { set line [string trim [string range \$line 0 [expr {\$comment_idx - 1}]]] }
    if {\$line ne ""} {
        lappend file_list \$line
        if {[string match "*.xci" \$line]} { lappend xci_list \$line }
    }
}

puts "Found [llength \$file_list] source files"

# Add Verilog sources
foreach f \$file_list {
    if {[string match "*.xci" \$f]} { continue }
    set resolved [file normalize "\$proj_dir/\$f"]
    if {[file exists \$resolved]} {
        add_files -norecurse \$resolved
    } else {
        puts "  [WARN] Not found: \$f"
    }
}

# Add XCI IP
foreach f \$xci_list {
    set resolved [file normalize "\$proj_dir/\$f"]
    if {[file exists \$resolved]} {
        read_ip \$resolved
    }
}

if {[llength \$xci_list] > 0} {
    upgrade_ip [get_ips]
    generate_target all [get_ips]
    synth_ip [get_ips]
}

# Add fpga_build_time.v
set bt_f "\$proj_dir/fpga_build_time.v"
if {[file exists \$bt_f]} { add_files -norecurse \$bt_f }

# Top module
set_property top \$top_module [current_fileset]
update_compile_order -fileset sources_1

# Constraints
add_files -fileset constrs_1 -norecurse "\$proj_dir/pins.xdc"
add_files -fileset constrs_1 -norecurse "\$proj_dir/timing.xdc"

# Synthesis
puts "Running synthesis..."
launch_runs synth_1 -jobs 8
wait_on_run synth_1

# Implementation + Bitstream
puts "Running implementation..."
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

# Copy bitstream
set bit_src "\$proj_dir/\$proj_name.runs/impl_1/\$top_module.bit"
set bit_dst "\$proj_dir/\$proj_name.bit"
if {[file exists \$bit_src]} { file copy -force \$bit_src \$bit_dst }

# Reports
open_run impl_1
report_timing_summary -file "\$proj_dir/timing_summary.rpt"
report_utilization    -file "\$proj_dir/utilization.rpt"
close_design

puts "============================================"
puts " Build Complete!"
puts " Bitstream: \$bit_dst"
puts "============================================"
TCL_EOF

echo "[STEP 6/7] Done."

# 9. Run Vivado
echo "[STEP 7/7] Launching Vivado..."
mkdir -p "${PROJ_DIR}/log"
cd "${PROJ_DIR}"
vivado -mode batch \
    -source build.tcl \
    -log    "${PROJ_DIR}/log/vivado.log" \
    -journal "${PROJ_DIR}/log/vivado.jou" \
    -tclargs "${PROJ_NAME}" "${PROJ_DIR}"

echo ""
echo "============================================"
echo " FPGA WebServer Build Finished"
echo " Project : ${PROJ_DIR}"
echo "============================================"
