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
#
# External IP repos are cloned via SSH.  Each user must have:
#   (1) An SSH key added to their GitHub account.
#   (2) Collaborator access to fpga_cpu, ip_lcpu, ip_riscv, ip_common.
#=============================================================================

set -euo pipefail

#--------------------------------------------------------------------
# 1. Verify SSH access
#--------------------------------------------------------------------
SSH_OUTPUT=$(ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1) || true
if ! echo "$SSH_OUTPUT" | grep -qE 'successfully authenticated|Hu|HuanghmBuck'; then
    echo "ERROR: SSH key not configured or no GitHub access."
    echo "  Generate a key:  ssh-keygen -t ed25519 -C \"your@email.com\""
    echo "  Add public key:  https://github.com/settings/keys"
    exit 1
fi

#--------------------------------------------------------------------
# 2. Version check
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
# 3. Paths
#--------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PROJ_NAME="webserver_xilinx_xc7a35tfgg484_v${VERSION}_${TIMESTAMP}"
PROJ_DIR="${REPO_ROOT}/${PROJ_NAME}"
IP_CACHE="${HOME}/.cache/fpga_webserver_ip"   # 外部 IP 本地缓存(2026-08-31), mkdir 在 STEP3 前
mkdir -p "${IP_CACHE}"

GH_REMOTE="git@github.com:HuanghmBuck"

echo "============================================"
echo " FPGA WebServer Build (Xilinx XC7A35T)"
echo " Repo    : ${REPO_ROOT}"
echo " Project : ${PROJ_NAME}"
echo "          ${PROJ_DIR}"
echo " Version : ${VERSION}"
echo "============================================"

#--------------------------------------------------------------------
# 4. Create project directory
#--------------------------------------------------------------------
mkdir -p "${PROJ_DIR}"
echo "[STEP 1/8] Project directory created."

#--------------------------------------------------------------------
# 5. Parse filelist.cfg
#--------------------------------------------------------------------
echo "[STEP 2/8] Analyzing filelist.cfg..."

FILELIST_SRC="${SCRIPT_DIR}/filelist.cfg"

declare -a FILES_OWN_RTL=()
declare -a FILES_OWN_IPVENDOR=()
declare -a FILES_FPGA_CPU=()
declare -a FILES_IP_LCPU=()
declare -a FILES_IP_RISCV=()
declare -a FILES_IP_COMMON=()
declare -a FILES_FPGA_ILA=()

while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [ -z "$line" ] && continue

    case "$line" in
        ../rtl/*)            FILES_OWN_RTL+=("${line#../rtl/}") ;;
        ../ip_vendor/*)      FILES_OWN_IPVENDOR+=("${line#../ip_vendor/}") ;;
        ../../fpga_cpu/rtl/*) FILES_FPGA_CPU+=("${line#../../fpga_cpu/rtl/}") ;;
        ../../ip_lcpu/rtl/*)  FILES_IP_LCPU+=("${line#../../ip_lcpu/rtl/}") ;;
        ../../ip_riscv/rtl/*) FILES_IP_RISCV+=("${line#../../ip_riscv/rtl/}") ;;
        ../../ip_common/rtl/*)FILES_IP_COMMON+=("${line#../../ip_common/rtl/}") ;;
        ../../fpga_ila/rtl/*)FILES_FPGA_ILA+=("${line#../../fpga_ila/rtl/}") ;;
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
echo "  fpga_ila/rtl  : ${#FILES_FPGA_ILA[@]} files"
echo "[STEP 2/8] Done."

#--------------------------------------------------------------------
# 6. Clone external IP repos into project directory
#--------------------------------------------------------------------
echo "[STEP 3/8] Cloning external IP from GitHub..."

clone_repo_rtl() {
    local repo_name="$1"; local dst="${PROJ_DIR}/${repo_name}"
    shift; local files=("$@")
    [ ${#files[@]} -eq 0 ] && return
    local url="${GH_REMOTE}/${repo_name}.git"
    # 2026-08-31: 本地缓存复用(~/.cache/fpga_webserver_ip)——首次克隆后续离线可用,
    # 规避管理 WiFi 网络抖动导致 5 连克隆随机失败; IP_CACHE_REFRESH=1 强制刷新
    local cached="${IP_CACHE}/${repo_name}"
    echo -n "  ${repo_name} (${#files[@]} files)... "
    if [ -d "${cached}/.git" ] && [ "${IP_CACHE_REFRESH:-}" != "1" ]; then
        echo -n "cache hit, "
    else
        echo -n "cloning... "
        rm -rf "${cached}"
        if ! git clone --filter=blob:none --no-checkout --depth 1 "${url}" "${cached}" 2>/tmp/gh_clone_err; then
            echo "FAILED"
            echo "  ERROR: Could not clone ${repo_name}."
            if grep -qE 'Could not resolve host|Connection refused|timed out|Network is unreachable' /tmp/gh_clone_err 2>/dev/null; then
                echo "  Network is unreachable. Make sure your proxy/VPN is on."
            elif grep -qE 'Permission denied|Could not read from remote' /tmp/gh_clone_err 2>/dev/null; then
                echo "  SSH access denied. Make sure your SSH key is added to GitHub."
                echo "    Generate: ssh-keygen -t ed25519 -C \"your@email.com\""
                echo "    Add key:  https://github.com/settings/keys"
            elif grep -qE 'Repository not found|not found' /tmp/gh_clone_err 2>/dev/null; then
                echo "  Repository not found or no access. Ask the repo owner to add you as a collaborator."
            else
                echo "  git error: $(head -1 /tmp/gh_clone_err 2>/dev/null)"
            fi
            rm -f /tmp/gh_clone_err
            exit 1
        fi
        rm -f /tmp/gh_clone_err
        (
            cd "${cached}" || exit 1
            local patterns=(); for f in "${files[@]}"; do patterns+=("rtl/${f}"); done
            git sparse-checkout set --no-cone "${patterns[@]}" > /dev/null 2>&1
            git checkout > /dev/null 2>&1
        )
    fi
    rm -rf "${dst}"; cp -a "${cached}" "${dst}"
    echo "done"
}

# Full clone for repos that also carry Python/tools (not just RTL)
clone_repo_full() {
    local repo_name="$1"; local dst="${PROJ_DIR}/${repo_name}"
    local url="${GH_REMOTE}/${repo_name}.git"
    local cached="${IP_CACHE}/${repo_name}"
    echo -n "  ${repo_name} (full)... "
    if [ -d "${cached}/.git" ] && [ "${IP_CACHE_REFRESH:-}" != "1" ]; then
        echo -n "cache hit, "
    else
        echo -n "cloning... "
        rm -rf "${cached}"
        if ! git clone --depth 1 "${url}" "${cached}" 2>/tmp/gh_clone_err; then
            echo "FAILED"
            echo "  ERROR: Could not clone ${repo_name}."
            rm -f /tmp/gh_clone_err
            exit 1
        fi
        rm -f /tmp/gh_clone_err
    fi
    rm -rf "${dst}"; cp -a "${cached}" "${dst}"
    echo "done"
}

clone_repo_rtl "fpga_cpu"  "${FILES_FPGA_CPU[@]}"
clone_repo_rtl "ip_lcpu"   "${FILES_IP_LCPU[@]}"
clone_repo_rtl "ip_riscv"  "${FILES_IP_RISCV[@]}"
clone_repo_rtl "ip_common" "${FILES_IP_COMMON[@]}"
clone_repo_full "fpga_ila"   # main branch (default), no extra checkout needed
echo "[STEP 3/8] Done."

#--------------------------------------------------------------------
# 7. Copy project files
#--------------------------------------------------------------------
echo "[STEP 4/8] Copying project source files..."

if [ ${#FILES_OWN_RTL[@]} -gt 0 ]; then
    mkdir -p "${PROJ_DIR}/rtl"
    for f in "${FILES_OWN_RTL[@]}"; do
        cp "${REPO_ROOT}/rtl/${f}" "${PROJ_DIR}/rtl/${f}"
    done
    echo "  rtl/ -> ${PROJ_DIR}/rtl/  (${#FILES_OWN_RTL[@]} files)"
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

cp "${SCRIPT_DIR}/pins.xdc"   "${PROJ_DIR}/pins.xdc"
cp "${SCRIPT_DIR}/timing.xdc" "${PROJ_DIR}/timing.xdc"
echo "[STEP 4/8] Done."

#--------------------------------------------------------------------
# 8. Generate project filelist.cfg
#--------------------------------------------------------------------
echo "[STEP 5/8] Generating project filelist.cfg..."

CFG="${PROJ_DIR}/filelist.cfg"
exec 3>"${CFG}"
cat >&3 << 'HEADER'
#===================================================================
# filelist.cfg — auto-generated, self-contained
# All paths relative to this project directory.
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
echo "" >&3; echo "# -- fpga_ila: soft logic analyzer --" >&3
for f in "${FILES_FPGA_ILA[@]}";     do echo "fpga_ila/rtl/${f}" >&3; done
echo "" >&3; echo "fpga_build_time.v" >&3
exec 3>&-
echo "[STEP 5/8] Done  -> ${CFG}"

#--------------------------------------------------------------------
# 9. Generate fpga_build_time.v
#--------------------------------------------------------------------
echo "[STEP 6/8] Generating fpga_build_time.v..."
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
echo "[STEP 6/8] Done."

#--------------------------------------------------------------------
# 7. Generate Vivado TCL
#--------------------------------------------------------------------
echo "[STEP 7/8] Generating Vivado TCL script..."
TOP_MODULE="xilinx_xc7a35tfgg484_webserver_top"
cat > "${PROJ_DIR}/build.tcl" << TCL_EOF
set proj_name [lindex \$argv 0]
set proj_dir  [lindex \$argv 1]
set top_module "${TOP_MODULE}"

puts "============================================"
puts " Vivado WebServer Build"
puts " Project : \$proj_name"
puts "============================================"

create_project -force \$proj_name \$proj_dir -part xc7a35tfgg484-2

# Enable XPM libraries for xpm_memory_sdpram etc.
set_property xpm_libraries {XPM_MEMORY XPM_CDC XPM_FIFO} [current_project]

set cfg_file [open "\$proj_dir/filelist.cfg" r]
set cfg_data [read \$cfg_file]
close \$cfg_file

set file_list {}; set xci_list {}
foreach line [split \$cfg_data "\n"] {
    set line [string trim \$line]
    if {\$line eq "" || [string match "#*" \$line]} { continue }
    set ci [string first "#" \$line]
    if {\$ci >= 0} { set line [string trim [string range \$line 0 [expr {\$ci - 1}]]] }
    if {\$line ne ""} {
        lappend file_list \$line
        if {[string match "*.xci" \$line]} { lappend xci_list \$line }
    }
}
puts "Found [llength \$file_list] source files"

foreach f \$file_list {
    if {[string match "*.xci" \$f]} { continue }
    set r [file normalize "\$proj_dir/\$f"]
    if {[file exists \$r]} { add_files -norecurse \$r } else { puts "  \\[WARN] Not found: \$f" }
}
foreach f \$xci_list {
    set r [file normalize "\$proj_dir/\$f"]
    if {[file exists \$r]} { read_ip \$r }
}
if {[llength \$xci_list] > 0} { upgrade_ip [get_ips]; generate_target all [get_ips] }

set bt_f "\$proj_dir/fpga_build_time.v"
if {[file exists \$bt_f]} { add_files -norecurse \$bt_f }

# Parse all .v files as SystemVerilog (many RTL files use SV constructs like 'int')
set sv_files [get_files -of_objects [current_fileset] -filter {FILE_TYPE == Verilog}]
if {[llength \$sv_files] > 0} {
    set_property file_type SystemVerilog \$sv_files
    puts "Set [llength \$sv_files] .v file(s) to SystemVerilog"
}
set_property include_dirs [list \
    [file normalize "\$proj_dir/rtl"] \
    [file normalize "\$proj_dir/ip_common/rtl"] \
    [file normalize "\$proj_dir/fpga_ila/rtl"] \
] [current_fileset]

set_property top \$top_module [current_fileset]
update_compile_order -fileset sources_1
add_files -fileset constrs_1 -norecurse "\$proj_dir/pins.xdc"
add_files -fileset constrs_1 -norecurse "\$proj_dir/timing.xdc"

puts "Running synthesis..."
launch_runs synth_1 -jobs 8
wait_on_run synth_1

	# fpga_ila: no mark_debug hooks needed (pure RTL, cross-vendor)

	puts "Running implementation..."
	# Suppress UCIO-1 for GT refclk pins (auto-placed by GTPE2_CHANNEL)
	set drc_hook "\$proj_dir/drc_waiver.tcl"
	set fh [open \$drc_hook w]
	puts \$fh {set_property SEVERITY {Warning} [get_drc_checks UCIO-1]}
	close \$fh
	set_property STEPS.WRITE_BITSTREAM.TCL.PRE \$drc_hook [get_runs impl_1]

	launch_runs impl_1 -to_step write_bitstream -jobs 8
	wait_on_run impl_1

	set bit_src "\$proj_dir/\$proj_name.runs/impl_1/\$top_module.bit"
	set bit_dst "\$proj_dir/\$proj_name.bit"
	if {[file exists \$bit_src]} { file copy -force \$bit_src \$bit_dst }

	# Generate update .bin（SPI x1 bit-swap）供 fpga_golden 恢复页上传烧到 0x400000
	set bin_dst "\$proj_dir/\$proj_name.bin"
	if {[file exists \$bit_dst]} {
		write_cfgmem -format bin -interface SPIx1 -size 4 \
			-loadbit [list up 0x00000000 \$bit_dst] \
			-force -file \$bin_dst
		puts "  update .bin : \$bin_dst"
	}

	# Timing / utilization reports (open the implemented design from the run)
	open_run impl_1
	report_timing_summary -file "\$proj_dir/timing_summary.rpt"
	report_utilization    -file "\$proj_dir/utilization.rpt"
	close_design

puts "============================================"
puts " Build Complete!  Bitstream: \$bit_dst"
puts "============================================"
TCL_EOF
echo "[STEP 7/8] Done."

#--------------------------------------------------------------------
# 9. Run Vivado
#--------------------------------------------------------------------
echo "[STEP 8/8] Launching Vivado..."
mkdir -p "${PROJ_DIR}/log"
cd "${PROJ_DIR}"
vivado -mode batch \
    -source build.tcl \
    -log    "${PROJ_DIR}/log/vivado.log" \
    -journal "${PROJ_DIR}/log/vivado.jou" \
    -tclargs "${PROJ_NAME}" "${PROJ_DIR}"

#--------------------------------------------------------------------
# Post-Build: generate webserver_signals.json from RTL
#--------------------------------------------------------------------
echo ""
echo "============================================"
echo " Post-Build: Generating ILA signal config..."
echo "============================================"

GEN_SIGNALS_PY="${PROJ_DIR}/fpga_ila/tools/gen_signals.py"
SIGNALS_JSON="${PROJ_DIR}/webserver_signals.json"
export PYTHONPATH="${PROJ_DIR}/fpga_ila/host:${PYTHONPATH:-}"

if [ -f "${GEN_SIGNALS_PY}" ]; then
    echo "  Scanning project for soft_ila_top instances..."
    python3 "${GEN_SIGNALS_PY}" "${PROJ_DIR}" "${SIGNALS_JSON}"
    if [ -f "${SIGNALS_JSON}" ]; then
        CORE_COUNT=$(python3 -c "import json; d=json.load(open('${SIGNALS_JSON}')); print(len(d.get('cores',[])))")
        echo "  ✓ ${SIGNALS_JSON}  (${CORE_COUNT} cores)"
    else
        echo "  [WARN] gen_signals.py ran but no output"
    fi
else
    echo "  [WARN] gen_signals.py not found (fpga_ila not cloned?)"
fi

echo ""
echo "============================================"
echo " Build Complete"
echo " Project : ${PROJ_DIR}"
echo " Bitfile : ${PROJ_DIR}/${PROJ_NAME}.bit"
echo " Binfile : ${PROJ_DIR}/${PROJ_NAME}.bin  (upload via fpga_golden recovery page -> update 0x400000)"
echo " Signals : ${PROJ_DIR}/webserver_signals.json"
echo ""
echo " Self-contained.  To rebuild:"
echo "   cd ${PROJ_DIR}"
echo "   vivado -mode batch -source build.tcl -tclargs ${PROJ_NAME} ${PROJ_DIR}"
echo "============================================"
