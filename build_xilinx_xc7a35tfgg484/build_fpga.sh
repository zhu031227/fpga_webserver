#!/bin/bash
#=============================================================================
# build_fpga.sh — Xilinx XC7A35T-FGG484 FPGA WebServer build script
#=============================================================================
# Usage:
#   ./build_fpga.sh <version>
#
# Workflow:
#   1. Parse filelist.cfg → determine external repo files needed
#   2. Clone external repos with sparse-checkout (rtl files only)
#   3. Copy project's own rtl/ and ip_vendor/ into project dir
#   4. Generate fpga_build_time.v with version stamp
#   5. Run Vivado synthesis + implementation + bitstream
#
# All source files are gathered under the project directory so Vivado
# never references paths outside the build workspace.
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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FPGA_WS_DIR="$(dirname "$SCRIPT_DIR")"          # fpga_webserver/
WORK_DIR="$(dirname "$FPGA_WS_DIR")"            # parent of fpga_webserver

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PROJ_NAME="xilinx_xc7a35tfgg484_v${VERSION}_${TIMESTAMP}"
PROJ_DIR="${FPGA_WS_DIR}/${PROJ_NAME}"

# Repo root directories (assumed to be siblings of fpga_webserver)
REPO_FPGA_CPU="${WORK_DIR}/fpga_cpu"
REPO_IP_LCPU="${WORK_DIR}/ip_lcpu"
REPO_IP_RISCV="${WORK_DIR}/ip_riscv"
REPO_IP_COMMON="${WORK_DIR}/ip_common"

# GitHub remotes (fallback if local repos missing)
REMOTE_PREFIX="git@github.com:HuanghmBuck"

echo "============================================"
echo " FPGA WebServer Build (Xilinx)"
echo " Target : XC7A35T-FGG484"
echo " Version: ${VERSION}"
echo " Project: ${PROJ_NAME}"
echo "============================================"

#--------------------------------------------------------------------
# 3. Create project directory
#--------------------------------------------------------------------
mkdir -p "${PROJ_DIR}"
echo "[STEP 1/8] Project directory created."

#--------------------------------------------------------------------
# 4. Parse filelist.cfg → classify files by source repo
#--------------------------------------------------------------------
echo "[STEP 2/8] Analyzing filelist.cfg..."

FILELIST_CFG="${SCRIPT_DIR}/filelist.cfg"

declare -a FILES_RTL=()          # ../rtl/...
declare -a FILES_IP_VENDOR=()    # ../ip_vendor/...
declare -a FILES_FPGA_CPU=()     # ../fpga_cpu/rtl/...
declare -a FILES_IP_LCPU=()      # ../ip_lcpu/rtl/...
declare -a FILES_IP_RISCV=()     # ../ip_riscv/rtl/...
declare -a FILES_IP_COMMON=()    # ../ip_common/rtl/...
declare -a FILES_LOCAL=()        # fpga_build_time.v (local)

while IFS= read -r line; do
    # strip comments & whitespace
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [ -z "$line" ] && continue

    case "$line" in
        ../rtl/*)
            FILES_RTL+=("${line#../rtl/}")
            ;;
        ../ip_vendor/*)
            FILES_IP_VENDOR+=("${line#../ip_vendor/}")
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
            FILES_LOCAL+=("$line")
            ;;
        *)
            echo "  WARN: unrecognized path prefix: $line"
            ;;
    esac
done < "${FILELIST_CFG}"

echo "  rtl          : ${#FILES_RTL[@]} files"
echo "  ip_vendor    : ${#FILES_IP_VENDOR[@]} files"
echo "  fpga_cpu/rtl : ${#FILES_FPGA_CPU[@]} files"
echo "  ip_lcpu/rtl  : ${#FILES_IP_LCPU[@]} files"
echo "  ip_riscv/rtl : ${#FILES_IP_RISCV[@]} files"
echo "  ip_common/rtl: ${#FILES_IP_COMMON[@]} files"
echo "[STEP 2/8] Done."

#--------------------------------------------------------------------
# 5. Clone external repos (sparse-checkout: only needed rtl/*)
#--------------------------------------------------------------------
echo "[STEP 3/8] Cloning external repositories..."

clone_repo_with_files() {
    local local_src="$1"          # local cache path (or empty)
    local remote_url="$2"         # GitHub URL (fallback)
    local dst="$3"                # destination dir
    local label="$4"              # human-readable label
    shift 4
    local files=("$@")            # files to sparse-checkout (relative to repo root)

    if [ ${#files[@]} -eq 0 ]; then
        echo "  ${label}: no files needed, skipping."
        return
    fi

    echo -n "  Cloning ${label} (${#files[@]} files)... "

    local src_repo=""
    if [ -n "${local_src}" ] && [ -d "${local_src}/.git" ]; then
        src_repo="${local_src}"
        echo -n "from local cache... "
    else
        src_repo="${remote_url}"
        echo -n "from GitHub... "
    fi

    # Clone with no checkout, then sparse-checkout only needed files
    git clone --no-checkout --depth 1 "${src_repo}" "${dst}" > /dev/null 2>&1 || {
        echo "FAILED (clone)"
        return 1
    }

    cd "${dst}"

    # Build sparse-checkout pattern: "rtl/file1.v" "rtl/file2.v" ...
    local patterns=()
    for f in "${files[@]}"; do
        # Some repos may store files at different paths; assume rtl/ prefix
        patterns+=("rtl/${f}")
    done

    git sparse-checkout set --no-cone "${patterns[@]}" > /dev/null 2>&1 || {
        echo "FAILED (sparse-checkout)"
        cd - > /dev/null
        return 1
    }
    git checkout > /dev/null 2>&1 || {
        echo "FAILED (checkout)"
        cd - > /dev/null
        return 1
    }
    cd - > /dev/null
    echo "done -> ${dst}/rtl/"
}

clone_repo_with_files \
    "${REPO_FPGA_CPU}" \
    "${REMOTE_PREFIX}/fpga_cpu.git" \
    "${PROJ_DIR}/fpga_cpu" \
    "fpga_cpu" \
    "${FILES_FPGA_CPU[@]}"

clone_repo_with_files \
    "${REPO_IP_LCPU}" \
    "${REMOTE_PREFIX}/ip_lcpu.git" \
    "${PROJ_DIR}/ip_lcpu" \
    "ip_lcpu" \
    "${FILES_IP_LCPU[@]}"

clone_repo_with_files \
    "${REPO_IP_RISCV}" \
    "${REMOTE_PREFIX}/ip_riscv.git" \
    "${PROJ_DIR}/ip_riscv" \
    "ip_riscv" \
    "${FILES_IP_RISCV[@]}"

clone_repo_with_files \
    "${REPO_IP_COMMON}" \
    "${REMOTE_PREFIX}/ip_common.git" \
    "${PROJ_DIR}/ip_common" \
    "ip_common" \
    "${FILES_IP_COMMON[@]}"

echo "[STEP 3/8] Done."

#--------------------------------------------------------------------
# 6. Copy project files (rtl/, ip_vendor/, constraints)
#--------------------------------------------------------------------
echo "[STEP 4/8] Copying project files..."

# rtl/
if [ ${#FILES_RTL[@]} -gt 0 ]; then
    mkdir -p "${PROJ_DIR}/rtl"
    for f in "${FILES_RTL[@]}"; do
        src="${FPGA_WS_DIR}/rtl/${f}"
        if [ -f "${src}" ]; then
            cp "${src}" "${PROJ_DIR}/rtl/${f}"
        else
            echo "  WARN: missing rtl/${f}"
        fi
    done
    echo "  rtl/ -> ${PROJ_DIR}/rtl/"
fi

# ip_vendor/
# For .xci files, copy the entire containing directory so Vivado
# can find all generated support files (.dcp, .xml, .xdc, .vh, …).
if [ ${#FILES_IP_VENDOR[@]} -gt 0 ]; then
    declare -A ip_dirs
    for f in "${FILES_IP_VENDOR[@]}"; do
        ip_dirs["$(dirname "$f")"]=1
    done
    for d in "${!ip_dirs[@]}"; do
        src="${FPGA_WS_DIR}/ip_vendor/${d}"
        dst="${PROJ_DIR}/ip_vendor/${d}"
        mkdir -p "$(dirname "${dst}")"
        if [ -d "${src}" ]; then
            cp -r "${src}" "$(dirname "${dst}")/"
            echo "  ip_vendor/${d}/ -> ${PROJ_DIR}/ip_vendor/${d}/"
        else
            echo "  WARN: missing ip_vendor/${d}"
        fi
    done
fi

# constraints
cp "${SCRIPT_DIR}/pins.xdc"   "${PROJ_DIR}/pins.xdc"
cp "${SCRIPT_DIR}/timing.xdc" "${PROJ_DIR}/timing.xdc"
echo "  pins.xdc, timing.xdc -> ${PROJ_DIR}/"

echo "[STEP 4/8] Done."

#--------------------------------------------------------------------
# 7. Generate corrected filelist.cfg (paths relative to PROJ_DIR)
#--------------------------------------------------------------------
echo "[STEP 5/8] Generating project filelist.cfg..."

cat > "${PROJ_DIR}/filelist.cfg" << CFG_EOF
#===================================================================
# filelist.cfg — auto-generated for ${PROJ_NAME}
# All paths relative to: ${PROJ_DIR}
#===================================================================

# -- FPGA Webserver RTL --
CFG_EOF

for f in "${FILES_RTL[@]}"; do
    echo "rtl/${f}" >> "${PROJ_DIR}/filelist.cfg"
done

cat >> "${PROJ_DIR}/filelist.cfg" << CFG_EOF

# -- Vendor IP --
CFG_EOF

for f in "${FILES_IP_VENDOR[@]}"; do
    echo "ip_vendor/${f}" >> "${PROJ_DIR}/filelist.cfg"
done

cat >> "${PROJ_DIR}/filelist.cfg" << CFG_EOF

# -- FPGA CPU RTL --
CFG_EOF

for f in "${FILES_FPGA_CPU[@]}"; do
    echo "fpga_cpu/rtl/${f}" >> "${PROJ_DIR}/filelist.cfg"
done

cat >> "${PROJ_DIR}/filelist.cfg" << CFG_EOF

# -- IP: lcpu --
CFG_EOF

for f in "${FILES_IP_LCPU[@]}"; do
    echo "ip_lcpu/rtl/${f}" >> "${PROJ_DIR}/filelist.cfg"
done

cat >> "${PROJ_DIR}/filelist.cfg" << CFG_EOF

# -- IP: riscv --
CFG_EOF

for f in "${FILES_IP_RISCV[@]}"; do
    echo "ip_riscv/rtl/${f}" >> "${PROJ_DIR}/filelist.cfg"
done

cat >> "${PROJ_DIR}/filelist.cfg" << CFG_EOF

# -- IP: common --
CFG_EOF

for f in "${FILES_IP_COMMON[@]}"; do
    echo "ip_common/rtl/${f}" >> "${PROJ_DIR}/filelist.cfg"
done

cat >> "${PROJ_DIR}/filelist.cfg" << CFG_EOF

# -- Build time stamp (auto-generated) --
fpga_build_time.v
CFG_EOF

echo "[STEP 5/8] Done."

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
echo " FPGA WebServer Build Finished"
echo " Project : ${PROJ_DIR}"
echo "============================================"
