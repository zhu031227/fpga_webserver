#!/bin/bash
#=============================================================================
# build_fpga.sh — Altera EP4CE10F17C6 FPGA WebServer build script
#=============================================================================
# Usage:
#   cd fpga_webserver
#   ./build_altera_ep4ce10f17c6/build_fpga.sh <version>
#
# Creates a self-contained versioned project directory at the same level
# as rtl/ sim/ c/ etc.  All external IP are cloned directly into the
# project so the entire directory can be archived and rebuilt on any
# machine with zero external dependencies.
#
# GitHub credentials are prompted once at the start and cached locally.
#=============================================================================

set -euo pipefail

#--------------------------------------------------------------------
# 1. Version check
#--------------------------------------------------------------------
if [ $# -lt 1 ]; then
    echo "Usage: $0 <version>"
    echo "  version : 1~4 hex digits"
    exit 1
fi

VERSION_RAW="$1"
if [[ ! "${VERSION_RAW}" =~ ^[0-9a-fA-F]{1,4}$ ]]; then
    echo "ERROR: Version must be 1~4 hex digits"
    exit 1
fi
VERSION=$(printf '%04s' "$(echo "${VERSION_RAW}" | tr '[:upper:]' '[:lower:]')" | tr ' ' '0')

#--------------------------------------------------------------------
# 2. GitHub credentials
#--------------------------------------------------------------------
CRED_FILE="${HOME}/.fpga_webserver_gh_creds"

if [ -f "${CRED_FILE}" ]; then
    echo "Found cached credentials: ${CRED_FILE}"
    echo -n "Reuse? [Y/n] "
    read -r REUSE < /dev/tty
    if [ "${REUSE}" != "n" ] && [ "${REUSE}" != "N" ]; then
        source "${CRED_FILE}"
        echo "  Using cached credentials for ${GH_USER}."
    fi
fi

if [ -z "${GH_USER:-}" ] || [ -z "${GH_TOKEN:-}" ]; then
    echo ""
    echo "=== GitHub Authentication ==="
    echo "External IP repos will be cloned from GitHub."
    echo "Enter your credentials once (classic PAT with 'repo' scope)."
    echo ""
    printf "  GitHub username: "
    read -r GH_USER < /dev/tty
    printf "  GitHub token:    "
    read -rs GH_TOKEN < /dev/tty
    echo ""
    if [ -z "${GH_USER}" ] || [ -z "${GH_TOKEN}" ]; then
        echo "ERROR: Username and token are required."; exit 1
    fi
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${GH_USER}:${GH_TOKEN}" "https://api.github.com/user" 2>/dev/null || echo "000")
    if [ "${HTTP_CODE}" != "200" ]; then
        echo "ERROR: GitHub authentication failed (HTTP ${HTTP_CODE})."
        exit 1
    fi
    echo "  Authentication OK."
    cat > "${CRED_FILE}" << EOF
# fpga_webserver GitHub credentials (auto-generated)
GH_USER='${GH_USER}'
GH_TOKEN='${GH_TOKEN}'
EOF
    chmod 600 "${CRED_FILE}"
    echo "  Credentials cached -> ${CRED_FILE}"
fi

#--------------------------------------------------------------------
# 3. Paths & toolchain
#--------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PROJ_NAME="altera_ep4ce10f17c6_v${VERSION}_${TIMESTAMP}"
PROJ_DIR="${REPO_ROOT}/${PROJ_NAME}"

GH_AUTH="https://${GH_USER}:${GH_TOKEN}@github.com/HuanghmBuck"

QUARTUS_ROOT="${QUARTUS_ROOT:-/home/huamingh/tools/altera/13.1/quartus}"
QUARTUS_BIN="${QUARTUS_ROOT}/bin"
export QUARTUS_ROOTDIR="${QUARTUS_ROOT}"

echo "============================================"
echo " FPGA WebServer Build (Altera EP4CE10)"
echo " Repo    : ${REPO_ROOT}"
echo " Project : ${PROJ_NAME}"
echo "          ${PROJ_DIR}"
echo " Version : ${VERSION}"
echo "============================================"

if [ ! -x "${QUARTUS_BIN}/quartus_sh" ]; then
    echo "ERROR: Quartus II not found at ${QUARTUS_ROOT}"
    exit 1
fi

#--------------------------------------------------------------------
# 4. Create project dir
#--------------------------------------------------------------------
mkdir -p "${PROJ_DIR}"
echo "[STEP 1/9] Project directory created."

#--------------------------------------------------------------------
# 5. Parse filelist.cfg
#--------------------------------------------------------------------
echo "[STEP 2/9] Analyzing filelist.cfg..."

FILELIST_SRC="${SCRIPT_DIR}/filelist.cfg"
declare -a FILES_OWN_RTL=() FILES_OWN_IPVENDOR=()
declare -a FILES_FPGA_CPU=() FILES_IP_LCPU=() FILES_IP_RISCV=() FILES_IP_COMMON=()

while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"
    [ -z "$line" ] && continue
    case "$line" in
        ../rtl/*)            FILES_OWN_RTL+=("${line#../rtl/}") ;;
        ../ip_vendor/*)      FILES_OWN_IPVENDOR+=("${line#../ip_vendor/}") ;;
        ../../fpga_cpu/rtl/*) FILES_FPGA_CPU+=("${line#../../fpga_cpu/rtl/}") ;;
        ../../ip_lcpu/rtl/*)  FILES_IP_LCPU+=("${line#../../ip_lcpu/rtl/}") ;;
        ../../ip_riscv/rtl/*) FILES_IP_RISCV+=("${line#../../ip_riscv/rtl/}") ;;
        ../../ip_common/rtl/*)FILES_IP_COMMON+=("${line#../../ip_common/rtl/}") ;;
        fpga_build_time.v)   ;;
        *) echo "  WARN: unrecognized: $line" ;;
    esac
done < "${FILELIST_SRC}"

echo "  Own rtl       : ${#FILES_OWN_RTL[@]} files"
echo "  Own ip_vendor : ${#FILES_OWN_IPVENDOR[@]} files"
echo "  fpga_cpu/rtl  : ${#FILES_FPGA_CPU[@]} files"
echo "  ip_lcpu/rtl   : ${#FILES_IP_LCPU[@]} files"
echo "  ip_riscv/rtl  : ${#FILES_IP_RISCV[@]} files"
echo "  ip_common/rtl : ${#FILES_IP_COMMON[@]} files"
echo "[STEP 2/9] Done."

#--------------------------------------------------------------------
# 6. Clone external IP repos
#--------------------------------------------------------------------
echo "[STEP 3/9] Cloning external IP from GitHub..."

clone_repo_rtl() {
    local repo_name="$1"; local dst="${PROJ_DIR}/${repo_name}"
    shift; local files=("$@")
    [ ${#files[@]} -eq 0 ] && return
    local url="${GH_AUTH}/${repo_name}.git"
    echo -n "  Cloning ${repo_name} (${#files[@]} files)... "
    git clone --filter=blob:none --no-checkout --depth 1 "${url}" "${dst}" > /dev/null 2>&1 || {
        echo "FAILED"; echo "  ERROR: Could not clone ${url}"; exit 1
    }
    cd "${dst}"
    local patterns=(); for f in "${files[@]}"; do patterns+=("rtl/${f}"); done
    git sparse-checkout set --no-cone "${patterns[@]}" > /dev/null 2>&1
    git checkout > /dev/null 2>&1
    cd - > /dev/null
    echo "done"
}

clone_repo_rtl "fpga_cpu"  "${FILES_FPGA_CPU[@]}"
clone_repo_rtl "ip_lcpu"   "${FILES_IP_LCPU[@]}"
clone_repo_rtl "ip_riscv"  "${FILES_IP_RISCV[@]}"
clone_repo_rtl "ip_common" "${FILES_IP_COMMON[@]}"
echo "[STEP 3/9] Done."

#--------------------------------------------------------------------
# 7. Copy project files
#--------------------------------------------------------------------
echo "[STEP 4/9] Copying project source files..."
if [ ${#FILES_OWN_RTL[@]} -gt 0 ]; then
    mkdir -p "${PROJ_DIR}/rtl"
    for f in "${FILES_OWN_RTL[@]}"; do
        cp "${REPO_ROOT}/rtl/${f}" "${PROJ_DIR}/rtl/${f}"
    done
    echo "  rtl/ -> ${PROJ_DIR}/rtl/"
fi
if [ ${#FILES_OWN_IPVENDOR[@]} -gt 0 ]; then
    declare -A ip_dirs
    for f in "${FILES_OWN_IPVENDOR[@]}"; do ip_dirs["$(dirname "$f")"]=1; done
    for d in "${!ip_dirs[@]}"; do
        mkdir -p "${PROJ_DIR}/ip_vendor/${d}"
        cp -r "${REPO_ROOT}/ip_vendor/${d}/"* "${PROJ_DIR}/ip_vendor/${d}/"
    done
    echo "  ip_vendor/ -> ${PROJ_DIR}/ip_vendor/"
fi
cp "${SCRIPT_DIR}/pins.qsf"   "${PROJ_DIR}/pins.qsf"
cp "${SCRIPT_DIR}/timing.sdc" "${PROJ_DIR}/timing.sdc"
echo "[STEP 4/9] Done."

#--------------------------------------------------------------------
# 8. Generate project filelist.cfg
#--------------------------------------------------------------------
echo "[STEP 5/9] Generating project filelist.cfg..."
CFG="${PROJ_DIR}/filelist.cfg"
exec 3>"${CFG}"
cat >&3 << 'HEADER'
#===================================================================
# filelist.cfg — auto-generated, self-contained
#===================================================================

HEADER
echo "# -- FPGA Webserver RTL --" >&3
for f in "${FILES_OWN_RTL[@]}";      do echo "rtl/${f}" >&3; done
echo "" >&3; echo "# -- Vendor IP --" >&3
for f in "${FILES_OWN_IPVENDOR[@]}"; do echo "ip_vendor/${f}" >&3; done
echo "" >&3; echo "# -- FPGA CPU RTL --" >&3
for f in "${FILES_FPGA_CPU[@]}";     do echo "fpga_cpu/rtl/${f}" >&3; done
echo "" >&3; echo "# -- IP: lcpu --" >&3
for f in "${FILES_IP_LCPU[@]}";      do echo "ip_lcpu/rtl/${f}" >&3; done
echo "" >&3; echo "# -- IP: riscv --" >&3
for f in "${FILES_IP_RISCV[@]}";     do echo "ip_riscv/rtl/${f}" >&3; done
echo "" >&3; echo "# -- IP: common --" >&3
for f in "${FILES_IP_COMMON[@]}";    do echo "ip_common/rtl/${f}" >&3; done
echo "" >&3; echo "fpga_build_time.v" >&3
exec 3>&-
echo "[STEP 5/9] Done."

#--------------------------------------------------------------------
# 9. Generate fpga_build_time.v
#--------------------------------------------------------------------
echo "[STEP 6/9] Generating fpga_build_time.v..."
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
echo "[STEP 6/9] Done."

#--------------------------------------------------------------------
# 10. Generate Quartus II project files
#--------------------------------------------------------------------
echo "[STEP 7/9] Generating Quartus II project files..."
TOP_MODULE="altera_ep4ce10f17c6_webserver_top"

cat > "${PROJ_DIR}/${PROJ_NAME}.qpf" << QPF_EOF
QUARTUS_VERSION = "13.1"
DATE = "$(date +"%H:%M:%S  %B %d, %Y" | tr '[:lower:]' '[:upper:]')"
PROJECT_REVISION = ${PROJ_NAME}
QPF_EOF

qsf_source_assignment() {
    case "$1" in
        *.sv|*.svh) echo "set_global_assignment -name SYSTEMVERILOG_FILE $1" ;;
        *.vhd|*.vhdl) echo "set_global_assignment -name VHDL_FILE $1" ;;
        *.qip)       echo "set_global_assignment -name QIP_FILE $1" ;;
        *.sdc)       echo "set_global_assignment -name SDC_FILE $1" ;;
        *)           echo "set_global_assignment -name VERILOG_FILE $1" ;;
    esac
}

SOURCE_ASSIGNMENTS=""
while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"
    [ -z "$line" ] && continue
    SOURCE_ASSIGNMENTS+=$(qsf_source_assignment "$line")$'\n'
done < "${CFG}"

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
echo "[STEP 7/9] Done."

#--------------------------------------------------------------------
# 11. Run Quartus II compilation
#--------------------------------------------------------------------
echo "[STEP 8/9] Launching Quartus II compilation..."
export PATH="${QUARTUS_BIN}:$PATH"
cd "${PROJ_DIR}"
${QUARTUS_BIN}/quartus_sh --flow compile "${PROJ_NAME}"

[ -f "output_files/${PROJ_NAME}.sta.rpt" ] && cp "output_files/${PROJ_NAME}.sta.rpt" "timing_summary.rpt"
[ -f "output_files/${PROJ_NAME}.fit.rpt" ] && cp "output_files/${PROJ_NAME}.fit.rpt" "utilization.rpt"

echo ""
echo "============================================"
echo " Build Complete"
echo " Project : ${PROJ_DIR}"
echo ""
echo " Self-contained.  To rebuild:"
echo "   cd ${PROJ_DIR} && quartus_sh --flow compile ${PROJ_NAME}"
echo "============================================"
