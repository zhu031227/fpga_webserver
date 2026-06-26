#!/bin/bash
#=============================================================================
# build_fpga.sh — Xilinx XC7A35T-FGG484 FPGA WebServer build script
#=============================================================================
# Usage:
#   cd fpga_webserver
#   ./build_xilinx_xc7a35tfgg484/build_fpga.sh <version>
#
# Creates a self-contained versioned project directory at the same level
# as rtl/ sim/ c/ etc.  All external IP (fpga_cpu, ip_lcpu, ip_riscv,
# ip_common) are cloned directly into the project so the entire directory
# can be archived and rebuilt on any machine with zero external dependencies.
#=============================================================================

set -euo pipefail

#--------------------------------------------------------------------
# 1. Version check
#--------------------------------------------------------------------
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

#--------------------------------------------------------------------
# 2. Paths
#--------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"       # .../build_xilinx_xc7a35tfgg484
REPO_ROOT="$(dirname "$SCRIPT_DIR")"              # .../fpga_webserver  (git clone root)

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PROJ_NAME="xilinx_xc7a35tfgg484_v${VERSION}_${TIMESTAMP}"
PROJ_DIR="${REPO_ROOT}/${PROJ_NAME}"              # sibling of rtl/ sim/ etc.

# GitHub organisation
GH_BASE="https://github.com/HuanghmBuck"

echo "============================================"
echo " FPGA WebServer Build (Xilinx XC7A35T)"
echo " Repo    : ${REPO_ROOT}"
echo " Project : ${PROJ_NAME}"
echo "          ${PROJ_DIR}"
echo " Version : ${VERSION}"
echo "============================================"

#--------------------------------------------------------------------
# 3. Create project directory
#--------------------------------------------------------------------
mkdir -p "${PROJ_DIR}"
echo "[STEP 1/8] Project directory created."

#--------------------------------------------------------------------
# 4. Parse filelist.cfg — classify source files by origin
#--------------------------------------------------------------------
echo "[STEP 2/8] Analyzing filelist.cfg..."

FILELIST_SRC="${SCRIPT_DIR}/filelist.cfg"

declare -a FILES_OWN_RTL=()
declare -a FILES_OWN_IPVENDOR=()
declare -a FILES_FPGA_CPU=()
declare -a FILES_IP_LCPU=()
declare -a FILES_IP_RISCV=()
declare -a FILES_IP_COMMON=()

while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [ -z "$line" ] && continue

    case "$line" in
        ../rtl/*)
            FILES_OWN_RTL+=("${line#../rtl/}")
            ;;
        ../ip_vendor/*)
            FILES_OWN_IPVENDOR+=("${line#../ip_vendor/}")
            ;;
        ../../fpga_cpu/rtl/*)
            FILES_FPGA_CPU+=("${line#../../fpga_cpu/rtl/}")
            ;;
        ../../ip_lcpu/rtl/*)
            FILES_IP_LCPU+=("${line#../../ip_lcpu/rtl/}")
            ;;
        ../../ip_riscv/rtl/*)
            FILES_IP_RISCV+=("${line#../../ip_riscv/rtl/}")
            ;;
        ../../ip_common/rtl/*)
            FILES_IP_COMMON+=("${line#../../ip_common/rtl/}")
            ;;
        fpga_build_time.v)
            ;;  # auto-generated, not copied
        *)
            echo "  WARN: unrecognized: $line"
            ;;
    esac
done < "${FILELIST_SRC}"

echo "  Own rtl       : ${#FILES_OWN_RTL[@]} files"
echo "  Own ip_vendor : ${#FILES_OWN_IPVENDOR[@]} files"
echo "  fpga_cpu/rtl  : ${#FILES_FPGA_CPU[@]} files"
echo "  ip_lcpu/rtl   : ${#FILES_IP_LCPU[@]} files"
echo "  ip_riscv/rtl  : ${#FILES_IP_RISCV[@]} files"
echo "  ip_common/rtl : ${#FILES_IP_COMMON[@]} files"
echo "[STEP 2/8] Done."

#--------------------------------------------------------------------
# 5. Clone external IP repos into project directory
#--------------------------------------------------------------------
echo "[STEP 3/8] Cloning external IP from GitHub..."

clone_repo_rtl() {
    local repo_name="$1"          # e.g. fpga_cpu
    local dst="${PROJ_DIR}/${repo_name}"
    shift
    local files=("$@")

    if [ ${#files[@]} -eq 0 ]; then
        echo "  ${repo_name}: no files needed, skipping."
        return
    fi

    local url="${GH_BASE}/${repo_name}.git"
    echo -n "  Cloning ${repo_name} (${#files[@]} files) from GitHub... "

    # Shallow clone with sparse-checkout for rtl/ only
    git clone --filter=blob:none --no-checkout --depth 1 "${url}" "${dst}" > /dev/null 2>&1 || {
        echo "FAILED"
        echo "  ERROR: Could not clone ${url}"
        echo "  Make sure the repo exists and is accessible."
        exit 1
    }

    cd "${dst}"
    local patterns=()
    for f in "${files[@]}"; do
        patterns+=("rtl/${f}")
    done

    git sparse-checkout set --no-cone "${patterns[@]}" > /dev/null 2>&1
    git checkout > /dev/null 2>&1
    cd - > /dev/null
    echo "done  -> ${PROJ_DIR}/${repo_name}/rtl/"
}

clone_repo_rtl "fpga_cpu"  "${FILES_FPGA_CPU[@]}"
clone_repo_rtl "ip_lcpu"   "${FILES_IP_LCPU[@]}"
clone_repo_rtl "ip_riscv"  "${FILES_IP_RISCV[@]}"
clone_repo_rtl "ip_common" "${FILES_IP_COMMON[@]}"

echo "[STEP 3/8] Done."

#--------------------------------------------------------------------
# 6. Copy project's own files into project directory
#--------------------------------------------------------------------
echo "[STEP 4/8] Copying project source files..."

# Own RTL files
if [ ${#FILES_OWN_RTL[@]} -gt 0 ]; then
    mkdir -p "${PROJ_DIR}/rtl"
    for f in "${FILES_OWN_RTL[@]}"; do
        src="${REPO_ROOT}/rtl/${f}"
        if [ -f "${src}" ]; then
            cp "${src}" "${PROJ_DIR}/rtl/${f}"
        else
            echo "  ERROR: missing ${src}"
            exit 1
        fi
    done
    echo "  rtl/          -> ${PROJ_DIR}/rtl/  (${#FILES_OWN_RTL[@]} files)"
fi

# Own ip_vendor (copy entire IP directories)
if [ ${#FILES_OWN_IPVENDOR[@]} -gt 0 ]; then
    declare -A ip_vendor_dirs
    for f in "${FILES_OWN_IPVENDOR[@]}"; do
        ip_vendor_dirs["$(dirname "$f")"]=1
    done
    for d in "${!ip_vendor_dirs[@]}"; do
        src="${REPO_ROOT}/ip_vendor/${d}"
        dst="${PROJ_DIR}/ip_vendor/${d}"
        mkdir -p "$(dirname "${dst}")"
        if [ -d "${src}" ]; then
            cp -r "${src}" "$(dirname "${dst}")/"
            echo "  ip_vendor/${d}/ -> ${PROJ_DIR}/ip_vendor/${d}/"
        else
            echo "  ERROR: missing ip_vendor/${d}"
            exit 1
        fi
    done
fi

# Constraints
cp "${SCRIPT_DIR}/pins.xdc"   "${PROJ_DIR}/pins.xdc"
cp "${SCRIPT_DIR}/timing.xdc" "${PROJ_DIR}/timing.xdc"
echo "  pins.xdc, timing.xdc copied"

echo "[STEP 4/8] Done."

#--------------------------------------------------------------------
# 7. Generate project filelist.cfg (paths relative to PROJ_DIR)
#--------------------------------------------------------------------
echo "[STEP 5/8] Generating project filelist.cfg..."

CFG="${PROJ_DIR}/filelist.cfg"
cat > "${CFG}" << EOF
#===================================================================
# filelist.cfg — auto-generated for ${PROJ_NAME}
# All paths are relative to this project directory.
# This project is fully self-contained: zip it, copy it anywhere,
# open with Vivado and run — no external dependencies.
#===================================================================

# -- FPGA Webserver RTL --
EOF
for f in "${FILES_OWN_RTL[@]}"; do echo "rtl/${f}" >> "${CFG}"; done

cat >> "${CFG}" << EOF

# -- Vendor IP --
EOF
for f in "${FILES_OWN_IPVENDOR[@]}"; do echo "ip_vendor/${f}" >> "${CFG}"; done

cat >> "${CFG}" << EOF

# -- FPGA CPU RTL --
EOF
for f in "${FILES_FPGA_CPU[@]}"; do echo "fpga_cpu/rtl/${f}" >> "${CFG}"; done

cat >> "${CFG}" << EOF

# -- IP: lcpu --
EOF
for f in "${FILES_IP_LCPU[@]}"; do echo "ip_lcpu/rtl/${f}" >> "${CFG}"; done

cat >> "${CFG}" << EOF

# -- IP: riscv --
EOF
for f in "${FILES_IP_RISCV[@]}"; do echo "ip_riscv/rtl/${f}" >> "${CFG}"; done

cat >> "${CFG}" << EOF

# -- IP: common --
EOF
for f in "${FILES_IP_COMMON[@]}"; do echo "ip_common/rtl/${f}" >> "${CFG}"; done

cat >> "${CFG}" << EOF

# -- Build time stamp (auto-generated) --
fpga_build_time.v
EOF

echo "[STEP 5/8] Done  -> ${CFG}"

#--------------------------------------------------------------------
# 8. Generate fpga_build_time.v
#--------------------------------------------------------------------
echo "[STEP 6/8] Generating fpga_build_time.v..."

BUILD_DATE=$(printf "32'h%04d%02d%02d" \
    "$((10#$(date +%Y)))" "$((10#$(date +%m)))" "$((10#$(date +%d)))")
BUILD_TIME=$(printf "32'h%02d%02d%04s" \
    "$((10#$(date +%H)))" "$((10#$(date +%M)))" "${VERSION}" | tr ' ' '0')

cat > "${PROJ_DIR}/fpga_build_time.v" << EOF
module fpga_build_time (
    output wire [31:0] build_date,
    output wire [31:0] build_time
);
    assign build_date = ${BUILD_DATE};
    assign build_time = ${BUILD_TIME};
endmodule
EOF
echo "[STEP 6/8] Done."

#--------------------------------------------------------------------
# 9. Generate Vivado TCL script
#--------------------------------------------------------------------
echo "[STEP 7/8] Generating Vivado TCL script..."

TCL_SCRIPT="${PROJ_DIR}/build.tcl"
TOP_MODULE="xilinx_xc7a35tfgg484_webserver_top"

cat > "${TCL_SCRIPT}" << TCL_EOF
#=============================================================================
# build.tcl — auto-generated Vivado build script
#=============================================================================
# This project is fully self-contained. All source files and IP are
# under the project directory.  No external paths are referenced.
#=============================================================================

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
    if {\$comment_idx >= 0} {
        set line [string trim [string range \$line 0 [expr {\$comment_idx - 1}]]]
    }
    if {\$line ne ""} {
        lappend file_list \$line
        if {[string match "*.xci" \$line]} { lappend xci_list \$line }
    }
}

puts "Found [llength \$file_list] source files"

# Add Verilog sources (all paths relative to proj_dir)
foreach f \$file_list {
    if {[string match "*.xci" \$f]} { continue }
    set resolved [file normalize "\$proj_dir/\$f"]
    if {[file exists \$resolved]} {
        add_files -norecurse \$resolved
    } else {
        puts "  [WARN] Not found: \$f  (resolved: \$resolved)"
    }
}

# XCI IP
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

# fpga_build_time.v
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

# Bitstream
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

echo "[STEP 7/8] Done."

#--------------------------------------------------------------------
# 10. Run Vivado
#--------------------------------------------------------------------
echo "[STEP 8/8] Launching Vivado..."
mkdir -p "${PROJ_DIR}/log"
cd "${PROJ_DIR}"

vivado -mode batch \
    -source build.tcl \
    -log    "${PROJ_DIR}/log/vivado.log" \
    -journal "${PROJ_DIR}/log/vivado.jou" \
    -tclargs "${PROJ_NAME}" "${PROJ_DIR}"

echo ""
echo "============================================"
echo " Build Complete"
echo " Project : ${PROJ_DIR}"
echo ""
echo " This project is self-contained."
echo " To rebuild: cd ${PROJ_DIR} && vivado -source build.tcl -tclargs ${PROJ_NAME} ${PROJ_DIR}"
echo "============================================"
