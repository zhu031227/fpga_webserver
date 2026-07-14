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
echo "[STEP 1/9] Project directory created."

#--------------------------------------------------------------------
# 5. Parse filelist.cfg
#--------------------------------------------------------------------
echo "[STEP 2/9] Analyzing filelist.cfg..."

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
# 6. Clone external IP repos into project directory
#--------------------------------------------------------------------
echo "[STEP 3/9] Cloning external IP from GitHub..."

clone_repo_rtl() {
    local repo_name="$1"; local dst="${PROJ_DIR}/${repo_name}"
    shift; local files=("$@")
    [ ${#files[@]} -eq 0 ] && return
    local url="${GH_REMOTE}/${repo_name}.git"
    echo -n "  Cloning ${repo_name} (${#files[@]} files)... "
    if ! git clone --filter=blob:none --no-checkout --depth 1 "${url}" "${dst}" 2>/tmp/gh_clone_err; then
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
echo "" >&3; echo "fpga_build_time.v" >&3
exec 3>&-
echo "[STEP 5/9] Done  -> ${CFG}"

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
# 10. Generate Vivado TCL
#--------------------------------------------------------------------
echo "[STEP 7/9] Generating Vivado TCL script..."
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
    if {[file exists \$r]} { add_files -norecurse \$r } else { puts "  [WARN] Not found: \$f" }
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
set_property include_dirs [file normalize "\$proj_dir/rtl"] [current_fileset]

set_property top \$top_module [current_fileset]
update_compile_order -fileset sources_1
add_files -fileset constrs_1 -norecurse "\$proj_dir/pins.xdc"
add_files -fileset constrs_1 -norecurse "\$proj_dir/timing.xdc"

puts "Running synthesis..."
launch_runs synth_1 -jobs 8
wait_on_run synth_1

	# ILA setup: register debug-core insertion as an OPT_DESIGN pre-hook so
	# the standard impl_1 run inserts the cores. This keeps impl_1 a real run
	# (GUI "Open Implemented Design" works) instead of an inline flow.
	set ila_tcl [file normalize "\$proj_dir/ila_setup.tcl"]
	set ila_modified 0
	if {[file exists \$ila_tcl]} {
	    puts "ILA: registering debug-core setup as impl_1 OPT_DESIGN pre-hook..."
	    set_property STEPS.OPT_DESIGN.TCL.PRE \$ila_tcl [get_runs impl_1]
	    set ila_modified 1
	}

	puts "Running implementation..."
	# Suppress UCIO-1 for GT refclk pins (auto-placed by GTPE2_CHANNEL)
	set drc_hook "\$proj_dir/drc_waiver.tcl"
	set fh [open \$drc_hook w]
	puts \$fh {set_property SEVERITY {Warning} [get_drc_checks UCIO-1]}
	close \$fh
	set_property STEPS.WRITE_BITSTREAM.TCL.PRE \$drc_hook [get_runs impl_1]

	# Emit the debug probes (.ltx) inside the run, right after bitstream.
	# Runs after route_design so the ILA core UUIDs are available.
	if {\$ila_modified} {
	    set ltx_hook "\$proj_dir/ltx_hook.tcl"
	    set fh [open \$ltx_hook w]
	    puts \$fh "write_debug_probes -force \\"[file normalize \$proj_dir/\$proj_name.ltx]\\""
	    close \$fh
	    set_property STEPS.WRITE_BITSTREAM.TCL.POST \$ltx_hook [get_runs impl_1]
	}

	launch_runs impl_1 -to_step write_bitstream -jobs 8
	wait_on_run impl_1

	set bit_src "\$proj_dir/\$proj_name.runs/impl_1/\$top_module.bit"
	set bit_dst "\$proj_dir/\$proj_name.bit"
	if {[file exists \$bit_src]} { file copy -force \$bit_src \$bit_dst }

	# Timing / utilization reports (open the implemented design from the run)
	open_run impl_1
	report_timing_summary -file "\$proj_dir/timing_summary.rpt"
	report_utilization    -file "\$proj_dir/utilization.rpt"
	close_design

puts "============================================"
puts " Build Complete!  Bitstream: \$bit_dst"
puts "============================================"
TCL_EOF
echo "[STEP 7/9] Done."

#--------------------------------------------------------------------
# 7b. Generate ILA setup TCL
#--------------------------------------------------------------------
echo "[STEP 7b/9] Generating ILA setup TCL..."
ILA_SETUP="${PROJ_DIR}/ila_setup.tcl"
cat > "${ILA_SETUP}" << 'ILA_EOF'
# ila_setup.tcl -- auto-generated ILA debug core configuration
# Runs after open_run synth_1. Groups mark_debug nets by ila_wrapper
# instance, creates one ILA core per instance with per-instance DATA_DEPTH.
#
# Net hierarchy produced by rtl/ila_wrapper.v:
#   top/.../u_ila_xxx/g_pN/dbgN         (1-bit probe)
#   top/.../u_ila_xxx/g_pN/dbgN[b]      (multi-bit probe, one net per bit)
#   top/.../u_ila_xxx/ila_clk           (clock, ILA_IS_CLK=1)

set all_nets [get_nets -hier -filter {MARK_DEBUG}]
if {[llength $all_nets] == 0} {
    puts "ILA: No mark_debug nets found, skipping."
    return
}

puts "ILA: Found [llength $all_nets] mark_debug nets"

# ------------------------------------------------------------------
# Parse every mark_debug net into (group, probe#, bit#) and separate
# clock nets. Multi-bit buses arrive as individual bit nets and must
# be re-assembled per probe, in bit order.
# ------------------------------------------------------------------
array set groups      {} ;# group -> 1 (set of groups seen)
array set probe_bits  {} ;# "group|probe" -> list of {bit netobj}
array set group_clk   {} ;# group -> clock net object
array set group_depth {} ;# group -> C_DATA_DEPTH

foreach net $all_nets {
    set name [get_property NAME $net]

    # Identify the ILA instance (grandparent) this net belongs to.
    set grp ""
    foreach part [split $name "/"] {
        if {[string match "u_ila_*" $part]} { set grp $part; break }
    }
    if {$grp eq ""} { continue }

    # Clock net?
    set is_clk 0
    catch { set is_clk [get_property ILA_IS_CLK $net] }
    if {$is_clk == 1} {
        set group_clk($grp) $net
        continue
    }

    # Data net: leaf is dbgN or dbgN[bit]
    set leaf [lindex [split $name "/"] end]
    set bit 0
    if {[regexp {^(.*)\[(\d+)\]$} $leaf -> base bit]} {
        set leaf $base
    }
    if {![regexp {dbg(\d+)$} $leaf -> pidx]} { continue }

    set key "$grp|$pidx"
    lappend probe_bits($key) [list $bit $net]

    # Track depth from any data net in the group.
    if {![info exists group_depth($grp)]} {
        set d 1024
        catch { set d [get_property ILA_DEPTH $net] }
        if {$d eq "" || $d == 0} { set d 1024 }
        set group_depth($grp) $d
    }
    set groups($grp) 1
}

# ------------------------------------------------------------------
# Create one ILA core per group and connect clk + every probe.
# ------------------------------------------------------------------
set core_idx 0
foreach grp [lsort [array names groups]] {
    # Collect this group's probe indices in numeric order.
    set pidxs {}
    foreach key [array names probe_bits "$grp|*"] {
        lappend pidxs [lindex [split $key "|"] 1]
    }
    set pidxs [lsort -integer -unique $pidxs]
    if {[llength $pidxs] == 0} { continue }

    set depth 1024
    if {[info exists group_depth($grp)]} { set depth $group_depth($grp) }

    set core_name "ila_auto_${core_idx}"
    puts "ILA: Creating core $core_name (group=$grp, depth=$depth, probes=[llength $pidxs])"
    set core [create_debug_core $core_name ila]
    set_property C_DATA_DEPTH $depth [get_debug_cores $core_name]

    # Clock connection (create_debug_core auto-creates the clk port).
    if {[info exists group_clk($grp)]} {
        set_property port_width 1 [get_debug_ports $core_name/clk]
        connect_debug_port $core_name/clk $group_clk($grp)
        puts "ILA:   clk = [get_property NAME $group_clk($grp)]"
    }

    # Probe connections. create_debug_core auto-creates probe0; any
    # further probe port must be added with create_debug_port.
    set port_num 0
    foreach pidx $pidxs {
        set key "$grp|$pidx"
        # Sort bit nets by bit index, then extract the net objects.
        set sorted [lsort -integer -index 0 $probe_bits($key)]
        set nets {}
        foreach pair $sorted { lappend nets [lindex $pair 1] }
        set width [llength $nets]

        if {$port_num > 0} { create_debug_port $core_name probe }
        set_property port_width $width [get_debug_ports $core_name/probe$port_num]
        set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports $core_name/probe$port_num]
        connect_debug_port $core_name/probe$port_num $nets
        puts "ILA:   probe$port_num <= dbg$pidx (width=$width)"
        incr port_num
    }
    incr core_idx
}

puts "ILA: Setup complete -- $core_idx ILA core(s) created"
ILA_EOF
echo "[STEP 7b/9] Done  -> ${ILA_SETUP}"


#--------------------------------------------------------------------
# 11. Run Vivado
#--------------------------------------------------------------------
echo "[STEP 8/9] Launching Vivado..."
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
echo " Self-contained.  To rebuild:"
echo "   cd ${PROJ_DIR}"
echo "   vivado -mode batch -source build.tcl -tclargs ${PROJ_NAME} ${PROJ_DIR}"
echo "============================================"
