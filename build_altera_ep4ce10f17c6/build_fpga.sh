#!/bin/bash
#=============================================================================
# build_fpga.sh — Altera EP4CE10F17C6 FPGA WebServer build script
#=============================================================================
# Usage:
#   ./build_fpga.sh <version>
#
# Creates a versioned Quartus II project, clones IP repos, runs full
# compilation (Analysis → Fitter → Assembler → STA).
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
PROJ_NAME="altera_ep4ce10f17c6_v${VERSION}_${TIMESTAMP}"
PROJ_DIR="${FPGA_WS_DIR}/${PROJ_NAME}"

echo "============================================"
echo " FPGA WebServer Build (Altera)"
echo " Target : EP4CE10F17C6"
echo " Version: ${VERSION}"
echo " Project: ${PROJ_NAME}"
echo "============================================"

# 3. Quartus toolchain
QUARTUS_ROOT="/home/huamingh/tools/altera/13.1/quartus"
QUARTUS_BIN="${QUARTUS_ROOT}/bin"
export QUARTUS_ROOTDIR="${QUARTUS_ROOT}"

if [ ! -x "${QUARTUS_BIN}/quartus_sh" ]; then
    echo "ERROR: Quartus II 13.1 not found at ${QUARTUS_ROOT}"
    exit 1
fi
echo "Quartus II : ${QUARTUS_ROOT}"

# 4. Create project dir
mkdir -p "${PROJ_DIR}"
echo "[STEP 1/8] Project directory created."

# 5. Clone IP repos
echo "[STEP 2/8] Cloning IP repositories..."

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

echo "[STEP 2/8] Done."

# 6. Generate corrected filelist.cfg
echo "[STEP 3/8] Generating filelist.cfg..."
sed -e 's|^rtl/|../rtl/|' \
    -e 's|^ip_vendor/|../ip_vendor/|' \
    -e 's|^\.\./ip_lcpu/|ip_lcpu/|' \
    -e 's|^\.\./ip_riscv/|ip_riscv/|' \
    -e 's|^\.\./ip_common/|ip_common/|' \
    "${SCRIPT_DIR}/filelist.cfg" > "${PROJ_DIR}/filelist.cfg"
echo "[STEP 3/8] Done."

# 7. Generate fpga_build_time.v
echo "[STEP 4/8] Generating fpga_build_time.v..."
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
echo "[STEP 4/8] Done."

# 8. Copy constraints
echo "[STEP 5/8] Copying constraints..."
cp "${SCRIPT_DIR}/pins.qsf"   "${PROJ_DIR}/pins.qsf"
cp "${SCRIPT_DIR}/timing.sdc" "${PROJ_DIR}/timing.sdc"
echo "[STEP 5/8] Done."

# 9. Generate Quartus II project files
echo "[STEP 6/8] Generating Quartus II project files..."

TOP_MODULE="altera_ep4ce10f17c6_webserver_top"

# .qpf
cat > "${PROJ_DIR}/${PROJ_NAME}.qpf" << QPF_EOF
QUARTUS_VERSION = "13.1"
DATE = "$(date +"%H:%M:%S  %B %d, %Y" | tr '[:lower:]' '[:upper:]')"
PROJECT_REVISION = ${PROJ_NAME}
QPF_EOF

# .qsf
qsf_source_assignment() {
    local f="$1"
    case "$f" in
        *.sv|*.svh) echo "set_global_assignment -name SYSTEMVERILOG_FILE $f" ;;
        *.vhd|*.vhdl) echo "set_global_assignment -name VHDL_FILE $f" ;;
        *.qip) echo "set_global_assignment -name QIP_FILE $f" ;;
        *.sdc) echo "set_global_assignment -name SDC_FILE $f" ;;
        *) echo "set_global_assignment -name VERILOG_FILE $f" ;;
    esac
}

SOURCE_ASSIGNMENTS=""
while IFS= read -r line; do
    line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line%%#*}"; line=$(echo "$line" | sed -e 's/[[:space:]]*$//')
    [[ -z "$line" ]] && continue
    SOURCE_ASSIGNMENTS+=$(qsf_source_assignment "$line")$'\n'
done < "${PROJ_DIR}/filelist.cfg"

cat > "${PROJ_DIR}/${PROJ_NAME}.qsf" << QSF_EOF
set_global_assignment -name FAMILY "Cyclone IV E"
set_global_assignment -name DEVICE EP4CE10F17C6
set_global_assignment -name TOP_LEVEL_ENTITY ${TOP_MODULE}
set_global_assignment -name ORIGINAL_QUARTUS_VERSION 13.1
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name MIN_CORE_JUNCTION_TEMP 0
set_global_assignment -name MAX_CORE_JUNCTION_TEMP 85
set_global_assignment -name NOMINAL_CORE_SUPPLY_VOLTAGE 1.2V
set_global_assignment -name STRATIX_DEVICE_IO_STANDARD "3.3-V LVTTL"
set_global_assignment -name ENABLE_SIGNALTAP OFF
set_global_assignment -name PARTITION_NETLIST_TYPE SOURCE -section_id Top
set_global_assignment -name PARTITION_FITTER_PRESERVATION_LEVEL PLACEMENT_AND_ROUTING -section_id Top
set_global_assignment -name PARTITION_COLOR 16764057 -section_id Top
set_instance_assignment -name PARTITION_HIERARCHY root_partition -to | -section_id Top
${SOURCE_ASSIGNMENTS}
set_global_assignment -name VERILOG_FILE fpga_build_time.v
$(cat "${PROJ_DIR}/pins.qsf")
set_global_assignment -name SDC_FILE timing.sdc
QSF_EOF

echo "[STEP 6/8] Done."

# 10. Run Quartus II compilation
echo "[STEP 7/8] Launching Quartus II compilation..."
export PATH="${QUARTUS_BIN}:$PATH"
cd "${PROJ_DIR}"
${QUARTUS_BIN}/quartus_sh --flow compile "${PROJ_NAME}"

# 11. Copy reports
echo "[STEP 8/8] Generating reports..."
[ -f "${PROJ_DIR}/output_files/${PROJ_NAME}.sta.rpt" ] && cp "${PROJ_DIR}/output_files/${PROJ_NAME}.sta.rpt" "${PROJ_DIR}/timing_summary.rpt"
[ -f "${PROJ_DIR}/output_files/${PROJ_NAME}.fit.rpt" ] && cp "${PROJ_DIR}/output_files/${PROJ_NAME}.fit.rpt" "${PROJ_DIR}/utilization.rpt"
[ -f "${PROJ_DIR}/output_files/${PROJ_NAME}.map.rpt" ] && cp "${PROJ_DIR}/output_files/${PROJ_NAME}.map.rpt" "${PROJ_DIR}/synthesis.rpt"
echo "[STEP 8/8] Done."

echo ""
echo "============================================"
echo " FPGA WebServer Build Finished"
echo " Project : ${PROJ_DIR}"
echo "============================================"
