#!/bin/bash
#
# Thin Pool Metadata Recovery Script
# Recovers corrupted thin pool metadata for Portworx VGs
#
# Usage: ./thin_pool_recovery.sh <vg_name>
# Example: ./thin_pool_recovery.sh pwx2
#

VERSION="1.0.0"

set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step() { echo -e "\n${BLUE}[STEP $1]${NC} $2"; }

AUTO_YES=0

confirm() {
    local msg="$1"
    local default="${2:-n}"

    # Auto-confirm if -y flag was passed
    if [[ "$AUTO_YES" -eq 1 ]]; then
        echo -e "${YELLOW}$msg [auto-yes]${NC}"
        return 0
    fi

    local prompt
    if [[ "$default" == "y" ]]; then
        prompt="[Y/n]"
    else
        prompt="[y/N]"
    fi

    echo -en "${YELLOW}$msg $prompt: ${NC}"
    read -r response
    response="${response:-$default}"
    [[ "$response" =~ ^[Yy]$ ]]
}

die() {
    log_error "$1"
    exit 1
}

# State tracking for crash recovery
RECOVERY_STATE=""
STATE_FILE=""

set_state() {
    RECOVERY_STATE="$1"
    if [[ -n "$STATE_FILE" ]]; then
        echo "$RECOVERY_STATE" > "$STATE_FILE"
    fi
    log_info "State: $RECOVERY_STATE"
}

cleanup_on_interrupt() {
    echo ""
    log_error "INTERRUPTED! Recovery incomplete."
    log_error "Current state: $RECOVERY_STATE"
    echo ""
    log_warn "The recovery was interrupted mid-way. Depending on the state:"
    log_warn "  - Before 'writing_metadata': Safe to restart, original data intact"
    log_warn "  - During 'writing_metadata': DANGEROUS - metadata may be corrupted"
    log_warn "  - After 'writing_metadata': Restart to complete remaining steps"
    echo ""
    if [[ -d "$TMPFS_DIR" ]]; then
        log_info "Repaired metadata preserved in: $TMPFS_DIR"
        log_info "To manually restore: dd if=$TMPFS_DIR/meta_repaired of=/dev/mapper/${VG_NAME}-${TMETA_LV}"
    fi
    log_info "State file: $STATE_FILE"
    exit 130
}

trap cleanup_on_interrupt SIGINT SIGTERM

# Globals - will be populated from lvmconfig
VG_NAME=""
# Pool name is always "pxpool" - one pool per VG
POOL_NAME="pxpool"
TMETA_LV="pxpool_tmeta"
TDATA_LV="pxpool_tdata"
TMPFS_DIR="/dev/shm/thinmeta_recovery"
LVM_BACKUP_DIR=""
RECOVERY_BACKUP_DIR=""

# Get a config value from lvmconfig
# Usage: get_lvm_config "section/key" [default_value]
get_lvm_config() {
    local key="$1"
    local default="$2"
    local value

    # lvmconfig outputs in format: key=value or key="value"
    value=$(lvmconfig --type current "$key" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d ' ')

    if [[ -z "$value" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Initialize paths from lvmconfig
init_lvm_config() {
    log_info "Reading LVM configuration from lvmconfig..."

    # Get backup directory from lvmconfig
    LVM_BACKUP_DIR=$(get_lvm_config "backup/backup_dir" "/etc/lvm/backup")

    # Create our recovery backup dir under the LVM backup location
    RECOVERY_BACKUP_DIR="${LVM_BACKUP_DIR}/recovery_$(date +%Y%m%d_%H%M%S)"

    log_info "LVM backup directory: $LVM_BACKUP_DIR"
    log_info "Recovery backup directory: $RECOVERY_BACKUP_DIR"
}

cleanup() {
    log_info "Cleaning up temporary devices..."
    dmsetup remove "${VG_NAME}_tmeta_recovery" 2>/dev/null || true
    # Don't remove tmpfs dir automatically - user might need it
}

trap cleanup EXIT

check_detached_session() {
    log_step 0 "Checking terminal session"

    # Check if running under screen, tmux, or nohup
    if [[ -n "$STY" ]]; then
        log_info "Running in screen session: $STY"
        return 0
    elif [[ -n "$TMUX" ]]; then
        log_info "Running in tmux session"
        return 0
    elif [[ $(ps -o comm= -p $PPID 2>/dev/null) == "nohup" ]]; then
        log_info "Running under nohup"
        return 0
    fi

    # Not in a detached session
    log_warn "Not running in screen/tmux/nohup!"
    log_warn "This recovery can take 1+ hours for large pools."
    log_warn "If your terminal disconnects, recovery will fail mid-way!"
    log_warn ""
    log_warn "Recommended: Run with nohup or screen:"
    log_warn "  nohup $0 $VG_NAME -y > /var/cores/recovery.log 2>&1 &"
    log_warn "  OR: screen -S recovery $0 $VG_NAME"
    echo ""

    if ! confirm "Continue in current terminal anyway?"; then
        die "Aborted - please run in screen/tmux/nohup"
    fi
}

check_px_container() {
    log_step 0 "Verifying PX container environment"

    # Check if PID 1 is supervisord (indicates we're inside PX container)
    local pid1_cmd=$(cat /proc/1/comm 2>/dev/null)
    if [[ "$pid1_cmd" != "supervisord" ]]; then
        log_error "This script must be run from inside the PX container!"
        log_error "PID 1 is '$pid1_cmd', expected 'supervisord'"
        log_info "To enter PX container:"
        log_info "  runc exec -t portworx bash"
        log_info "  OR: nsenter to portworx pod"
        die "Not running inside PX container"
    fi
    log_info "Running inside PX container (PID 1 = supervisord)"
}

check_maintenance_mode() {
    log_step 0 "Checking PX maintenance mode"

    local pxctl_path="/opt/pwx/bin/pxctl"
    if [[ ! -x "$pxctl_path" ]]; then
        pxctl_path="pxctl"
    fi

    # Parse Status line from pxctl status output
    # Expected: "Status: PX is in maintenance mode" when in maintenance
    # Normal: "Status: PX is operational"
    local status_output
    local status_line

    if status_output=$("$pxctl_path" status 2>&1); then
        status_line=$(echo "$status_output" | grep -i "^Status:" | head -1)
        log_info "PX status: $status_line"

        if echo "$status_line" | grep -qi "maintenance"; then
            log_info "PX is in maintenance mode"
            return 0
        fi
    fi

    # If we get here, either pxctl failed or not in maintenance mode
    log_warn "PX is NOT in maintenance mode!"
    log_warn "Current status: $status_line"
    log_warn ""
    log_warn "PX should be in maintenance mode before running this script."
    log_warn "To enter maintenance mode: pxctl service maintenance --enter"
    echo ""

    if ! confirm "Continue anyway? (DANGEROUS if PX is actively using the pool)"; then
        die "Aborted - please put PX in maintenance mode first"
    fi

    log_warn "Continuing without maintenance mode..."
}

check_prerequisites() {
    log_step 1 "Checking prerequisites"

    [[ -z "$VG_NAME" ]] && die "VG name is required. Usage: $0 <vg_name>"

    # Check if running in detached session (screen/tmux/nohup)
    check_detached_session

    # Check if we're inside PX container
    check_px_container

    # Check if PX is in maintenance mode
    check_maintenance_mode

    # Check for required tools
    for tool in thin_check thin_repair thin_dump dmsetup lvs vgs dd lvmconfig timeout; do
        command -v "$tool" &>/dev/null || die "Required tool '$tool' not found"
    done

    # Initialize LVM config paths
    init_lvm_config

    # Check if VG exists
    if ! vgs "$VG_NAME" &>/dev/null; then
        die "Volume group '$VG_NAME' not found"
    fi

    # Check available memory
    local free_mem=$(awk '/MemAvailable/ {print int($2/1024/1024)}' /proc/meminfo)
    log_info "Available memory: ${free_mem}GB"

    # Get metadata size
    local meta_size_bytes=$(lvs --noheadings -o lv_size --units b "$VG_NAME/$TMETA_LV" 2>/dev/null | tr -d ' B')
    local meta_size_gb=$((meta_size_bytes / 1024 / 1024 / 1024))
    log_info "Thin pool metadata size: ${meta_size_gb}GB"

    if [[ $free_mem -lt $((meta_size_gb * 3)) ]]; then
        log_warn "Low memory! Need ~${meta_size_gb}x3 GB for safe tmpfs recovery"
        confirm "Continue anyway?" || exit 1
    fi

    # Create recovery backup directory
    mkdir -p "$RECOVERY_BACKUP_DIR"
    log_info "Backup directory: $RECOVERY_BACKUP_DIR"

    log_info "Prerequisites check passed"
}

stop_lvm_processes() {
    log_step 2 "Stopping stuck LVM processes"

    # Use word boundary matching to avoid matching pwx2 when looking for pwx20, etc.
    # Match VG name as complete argument (preceded by space or start, followed by space, / or end)
    local lvm_pids=$(ps -eo pid,comm,args --no-headers | grep -E "vgchange|pvscan|lvcreate|thin_check|thin_repair" | grep -E "(^|[[:space:]])${VG_NAME}([[:space:]/]|$)" | awk '{print $1}')

    if [[ -n "$lvm_pids" ]]; then
        log_warn "Found LVM processes operating on $VG_NAME:"
        ps -eo pid,ppid,comm,args --no-headers | grep -E "vgchange|pvscan|lvcreate|thin_check|thin_repair" | grep -E "(^|[[:space:]])${VG_NAME}([[:space:]/]|$)"

        if confirm "Kill these processes?"; then
            for pid in $lvm_pids; do
                log_info "Killing PID $pid"
                kill -9 "$pid" 2>/dev/null || true
            done
            sleep 2
        fi
    else
        log_info "No stuck LVM processes found"
    fi
}

backup_lvm_config() {
    log_step 3 "Backing up LVM configuration"

    # Backup using vgcfgbackup
    vgcfgbackup "$VG_NAME" -f "$RECOVERY_BACKUP_DIR/${VG_NAME}_vgcfgbackup.conf"

    # Also copy the current backup file
    if [[ -f "$LVM_BACKUP_DIR/$VG_NAME" ]]; then
        cp "$LVM_BACKUP_DIR/$VG_NAME" "$RECOVERY_BACKUP_DIR/${VG_NAME}_backup.conf"
    fi

    # Also dump current lvmconfig for reference
    lvmconfig --type current > "$RECOVERY_BACKUP_DIR/lvmconfig_dump.txt" 2>/dev/null || true

    log_info "LVM config backed up to $RECOVERY_BACKUP_DIR"
}

deactivate_vg() {
    log_step 4 "Deactivating volume group"
    
    log_info "Current active devices:"
    # Match exact VG name prefix in device mapper names (format: VG_NAME-LV_NAME)
    dmsetup ls | awk '{print $1}' | grep -E "^${VG_NAME}-" || echo "  (none)"

    if confirm "Deactivate VG $VG_NAME?"; then
        # Use timeout to prevent hanging in failure modes
        timeout 30 vgchange -an "$VG_NAME" 2>/dev/null || true

        # Force remove any remaining devices - match exact VG prefix to avoid affecting unrelated VGs
        dmsetup ls | awk '{print $1}' | grep -E "^${VG_NAME}-" | while read dm; do
            dmsetup remove -f "$dm" 2>/dev/null || true
        done

        sleep 1
        local remaining=$(dmsetup ls | awk '{print $1}' | grep -E "^${VG_NAME}-" | wc -l)
        if [[ $remaining -gt 0 ]]; then
            log_warn "$remaining devices still active"
            dmsetup ls | awk '{print $1}' | grep -E "^${VG_NAME}-"
        else
            log_info "VG deactivated successfully"
        fi
    fi
}

copy_metadata_to_tmpfs() {
    log_step 5 "Copying metadata to tmpfs for fast processing"
    
    mkdir -p "$TMPFS_DIR"
    
    # Activate just the tmeta LV with timeout to prevent hanging
    log_info "Activating $VG_NAME/$TMETA_LV..."
    if ! timeout 30 lvchange -ay "$VG_NAME/$TMETA_LV" <<< "y" 2>/dev/null; then
        die "Failed to activate metadata LV (timed out or error)"
    fi

    local tmeta_dev="/dev/mapper/${VG_NAME}-${TMETA_LV}"
    if [[ ! -e "$tmeta_dev" ]]; then
        die "Cannot activate metadata LV: $tmeta_dev"
    fi
    
    log_info "Copying metadata to tmpfs..."
    if ! dd if="$tmeta_dev" of="$TMPFS_DIR/meta_original" bs=4M status=progress; then
        die "Failed to read metadata from $tmeta_dev - aborting to prevent data corruption"
    fi

    # Create output file for repair - must be same size as original
    # Use exact byte count to avoid truncation issues with non-4M-aligned sizes
    local meta_size=$(stat -c%s "$TMPFS_DIR/meta_original")
    log_info "Metadata size: $meta_size bytes"
    dd if=/dev/zero of="$TMPFS_DIR/meta_repaired" bs=1 count=0 seek="$meta_size" status=none

    # Deactivate with timeout to prevent hanging
    timeout 30 lvchange -an "$VG_NAME/$TMETA_LV" 2>/dev/null || true

    log_info "Metadata copied to $TMPFS_DIR"
}

run_thin_repair() {
    log_step 6 "Running thin_repair in tmpfs"

    log_info "This may take a while depending on pool size (e.g., ~1 hour for 5TB pool)"
    log_info "Running at 100% CPU in RAM - much faster than disk!"

    time thin_repair -i "$TMPFS_DIR/meta_original" -o "$TMPFS_DIR/meta_repaired"
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        die "thin_repair failed with exit code $rc"
    fi

    log_info "Verifying repaired metadata..."
    if thin_check "$TMPFS_DIR/meta_repaired"; then
        log_info "Repaired metadata passes thin_check!"

        # Get transaction ID from repaired metadata (first line has superblock with transaction)
        local txn_id=$(thin_dump "$TMPFS_DIR/meta_repaired" 2>/dev/null | head -1 | grep -o 'transaction="[0-9]*"' | grep -o '[0-9]*')
        log_info "Repaired metadata transaction_id: $txn_id"
        echo "$txn_id" > "$TMPFS_DIR/transaction_id"
    else
        die "Repaired metadata still fails thin_check!"
    fi
}

get_tmeta_table() {
    log_step 7 "Getting correct segment offsets for metadata LV"

    # Activate tmeta to get the dmsetup table (with timeout to prevent hanging)
    if ! timeout 30 lvchange -ay "$VG_NAME/$TMETA_LV" <<< "y" 2>/dev/null; then
        die "Failed to activate metadata LV for table extraction (timed out or error)"
    fi

    local table=$(dmsetup table "${VG_NAME}-${TMETA_LV}" 2>/dev/null)
    if [[ -z "$table" ]]; then
        die "Cannot get dmsetup table for ${VG_NAME}-${TMETA_LV}"
    fi

    echo "$table" > "$TMPFS_DIR/tmeta_table"
    log_info "Metadata LV table (${VG_NAME}-${TMETA_LV}):"
    cat "$TMPFS_DIR/tmeta_table"

    local segment_count=$(echo "$table" | wc -l)
    log_info "Found $segment_count segment(s)"

    # Deactivate with timeout to prevent hanging
    timeout 30 lvchange -an "$VG_NAME/$TMETA_LV" 2>/dev/null || true
}

copy_repaired_metadata() {
    log_step 8 "Copying repaired metadata back to disk"

    local table=$(cat "$TMPFS_DIR/tmeta_table")
    local temp_dev="${VG_NAME}_tmeta_recovery"

    # Create temp device with correct offsets
    log_info "Creating temporary device with correct segment mapping..."
    dmsetup create "$temp_dev" --table "$table"

    if [[ ! -e "/dev/mapper/$temp_dev" ]]; then
        die "Failed to create recovery device"
    fi

    echo ""
    log_warn "About to write repaired metadata to disk."
    log_warn "DO NOT INTERRUPT - partial write will corrupt metadata!"
    echo ""

    if ! confirm "Write repaired metadata to disk now?"; then
        dmsetup remove "$temp_dev"
        die "Aborted before writing metadata"
    fi

    set_state "writing_metadata"
    log_info "Copying repaired metadata..."

    if ! dd if="$TMPFS_DIR/meta_repaired" of="/dev/mapper/$temp_dev" bs=1M status=progress; then
        log_error "dd failed to write metadata!"
        log_error "State remains 'writing_metadata' - metadata may be corrupted"
        log_error "Repaired metadata still available at: $TMPFS_DIR/meta_repaired"
        dmsetup remove "$temp_dev" 2>/dev/null || true
        die "Failed to write metadata to disk"
    fi

    if ! sync; then
        log_error "sync failed after dd!"
        die "Failed to sync metadata to disk"
    fi

    set_state "metadata_written"

    log_info "Verifying copied metadata..."
    if thin_check "/dev/mapper/$temp_dev"; then
        log_info "Copied metadata passes thin_check!"
    else
        log_error "Copied metadata fails thin_check!"
        confirm "Continue anyway?" || die "Aborting"
    fi

    dmsetup remove "$temp_dev"
    log_info "Metadata copied successfully"
}

fix_transaction_id() {
    log_step 9 "Fixing transaction ID in LVM metadata"

    local repaired_txn=$(cat "$TMPFS_DIR/transaction_id" 2>/dev/null)
    if [[ -z "$repaired_txn" ]]; then
        log_warn "Could not determine repaired transaction ID"
        return 0
    fi

    # Use the LVM backup dir from lvmconfig
    local lvm_backup="$LVM_BACKUP_DIR/$VG_NAME"

    if [[ ! -f "$lvm_backup" ]]; then
        log_error "LVM backup file not found: $lvm_backup"
        return 1
    fi

    # Find transaction_id specifically for pxpool section
    # Structure: pxpool { segment1 { transaction_id = NNN } }
    # We need the transaction_id inside pxpool's segment, not the thin volumes
    local current_txn=$(awk '
        /^[[:space:]]*pxpool[[:space:]]*\{/ { in_pxpool=1 }
        in_pxpool && /transaction_id[[:space:]]*=/ {
            gsub(/[^0-9]/, "")
            print
            exit
        }
    ' "$lvm_backup")

    if [[ -z "$current_txn" ]]; then
        log_warn "Could not find pxpool transaction_id in LVM backup"
        return 1
    fi

    log_info "Current pxpool transaction_id: $current_txn"
    log_info "Repaired metadata transaction_id: $repaired_txn"

    if [[ "$current_txn" != "$repaired_txn" ]]; then
        log_warn "Transaction ID mismatch!"

        # Backup current config first
        local backup_file="$RECOVERY_BACKUP_DIR/lvm_backup_before_txn_fix"
        cp "$lvm_backup" "$backup_file"
        log_info "Backup saved: $backup_file"

        # Generate the modified file to show diff
        local tmp_file="$lvm_backup.proposed"
        awk -v old="$current_txn" -v new="$repaired_txn" '
            /^[[:space:]]*pxpool[[:space:]]*\{/ { in_pxpool=1 }
            in_pxpool && /transaction_id[[:space:]]*=[[:space:]]*/ && !replaced {
                # Use regex pattern that handles variable whitespace around = to match any formatting
                if (sub("transaction_id[[:space:]]*=[[:space:]]*" old, "transaction_id = " new)) {
                    replaced=1
                }
            }
            { print }
        ' "$lvm_backup" > "$tmp_file"

        # Show the diff
        log_info "Proposed change:"
        echo "---"
        diff "$lvm_backup" "$tmp_file" || true
        echo "---"

        if confirm "Apply this change to $lvm_backup?"; then
            mv "$tmp_file" "$lvm_backup"
            log_info "Updated pxpool transaction_id in $lvm_backup"

            # Restore with force
            log_info "Restoring VG configuration..."
            vgcfgrestore "$VG_NAME" --force
        else
            rm -f "$tmp_file"
            log_error "Transaction ID fix declined"
            log_error "VG activation will FAIL with mismatched transaction ID!"
            log_error "LVM expects transaction_id=$current_txn but metadata has transaction_id=$repaired_txn"
            die "Aborting recovery - transaction ID mismatch must be fixed"
        fi
    else
        log_info "Transaction IDs match, no update needed"
    fi
}

activate_and_verify() {
    log_step 10 "Activating volume group and verifying"

    if confirm "Activate VG $VG_NAME now?"; then
        vgchange -ay "$VG_NAME"
        local active=$(lvs --noheadings -o lv_active "$VG_NAME" | grep -c "active")
        log_info "Activated LVs: $active"

        # Verify thin pool
        local pool_status=$(dmsetup status "${VG_NAME}-${POOL_NAME}" 2>/dev/null)
        if [[ -n "$pool_status" ]]; then
            log_info "Thin pool status:"
            echo "$pool_status"
        fi

        if thin_check -q "/dev/mapper/${VG_NAME}-${TMETA_LV}" 2>/dev/null; then
            log_info "Thin pool metadata is healthy!"
        else
            log_warn "Thin pool metadata check failed"
        fi
    fi
}

cleanup_and_finish() {
    log_step 11 "Cleanup"

    log_info "Recovery files in: $TMPFS_DIR"
    log_info "Backup files in: $RECOVERY_BACKUP_DIR"

    if confirm "Remove tmpfs recovery files?"; then
        rm -rf "$TMPFS_DIR"
        log_info "Tmpfs files removed"
    fi

    echo ""
    log_info "========================================="
    log_info "Recovery complete!"
    log_info "========================================="
    echo ""
    log_info "Next steps:"
    echo "  1. Restart Portworx: supervisorctl restart pxcontroller_pxstorage"
    echo "  2. Monitor startup: journalctl -u portworx -f"
    echo "  3. Check pool health: pxctl status"
}

usage() {
    cat <<EOF
Thin Pool Metadata Recovery Script v${VERSION}

Usage: $0 <vg_name> [options]

REQUIREMENTS:
    - Must be run from INSIDE the PX container (PID 1 = supervisord)
    - PX should be in maintenance mode before running
      Enter maintenance: pxctl service maintenance --enter
    - Recommend running in screen/tmux/nohup (can take 1+ hours for large pools)

Arguments:
    vg_name         Volume group name (e.g., pwx2)

Options:
    -h, --help      Show this help message
    -v, --version   Show version
    -y, --yes       Auto-confirm all prompts (use with nohup)

Examples:
    # Interactive (short pools or when monitoring)
    $0 pwx2

    # Background with nohup (recommended for large pools)
    nohup $0 pwx2 -y > /var/cores/recovery.log 2>&1 &
    tail -f /var/cores/recovery.log

    # Using screen
    screen -S recovery $0 pwx2

Pool structure (fixed):
    VG: <vg_name>
    Pool: <vg_name>/pxpool
    Metadata: <vg_name>/pxpool_tmeta
    Data: <vg_name>/pxpool_tdata

Steps performed:
    0. Verify PX container and maintenance mode
    1. Check prerequisites (memory, tools)
    2. Stop stuck LVM processes
    3. Backup LVM configuration
    4. Deactivate volume group
    5. Copy metadata to tmpfs
    6. Run thin_repair in RAM
    7. Get correct segment offsets
    8. Copy repaired metadata back
    9. Fix transaction ID mismatch
   10. Activate and verify
   11. Cleanup

EOF
    exit 0
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -v|--version)
                echo "thin_pool_recovery.sh v${VERSION}"
                exit 0
                ;;
            -y|--yes)
                AUTO_YES=1
                shift
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                VG_NAME="$1"
                shift
                ;;
        esac
    done

    [[ -z "$VG_NAME" ]] && usage

    # Initialize state file
    STATE_FILE="/var/cores/recovery_${VG_NAME}_state"

    echo "========================================="
    echo "  Thin Pool Metadata Recovery Script v${VERSION}"
    echo "  VG: $VG_NAME"
    echo "  Pool: $VG_NAME/$POOL_NAME"
    echo "  Metadata: $VG_NAME/$TMETA_LV"
    echo "  $(date)"
    echo "========================================="
    echo ""

    # Check for previous incomplete recovery
    check_previous_recovery

    check_prerequisites

    # Check if VG is already healthy - makes script idempotent
    if check_vg_healthy; then
        log_info "VG $VG_NAME is already activated and pool is healthy"
        log_info "No recovery needed"
        # Clean up state file if exists
        rm -f "$STATE_FILE"
        exit 0
    fi

    log_warn "VG activation failed or pool is unhealthy - recovery needed"
    log_warn "This will attempt to recover corrupted thin pool metadata."
    log_warn "Make sure you have backups of important data!"
    echo ""
    confirm "Proceed with recovery of $VG_NAME?" || exit 0

    set_state "starting"
    stop_lvm_processes
    set_state "lvm_stopped"
    backup_lvm_config
    set_state "backup_done"
    check_and_remove_pxreserve
    set_state "pxreserve_checked"
    deactivate_vg
    set_state "vg_deactivated"
    copy_metadata_to_tmpfs
    set_state "metadata_copied_to_tmpfs"
    run_thin_repair
    set_state "repair_complete"
    get_tmeta_table
    set_state "table_obtained"
    copy_repaired_metadata
    set_state "txn_id_fixing"
    fix_transaction_id
    set_state "activating"
    activate_and_verify
    set_state "recreating_pxreserve"
    recreate_pxreserve
    set_state "complete"
    cleanup_and_finish

    # Remove state file on successful completion
    rm -f "$STATE_FILE"
}

check_previous_recovery() {
    # Check for previous incomplete recovery
    if [[ -f "$STATE_FILE" ]]; then
        local prev_state=$(cat "$STATE_FILE")
        log_warn "Previous incomplete recovery detected!"
        log_warn "State file: $STATE_FILE"
        log_warn "Previous state: $prev_state"
        echo ""

        case "$prev_state" in
            writing_metadata)
                log_error "CRITICAL: Previous recovery was interrupted during metadata write!"
                log_error "Metadata on disk may be corrupted."
                if [[ -f "$TMPFS_DIR/meta_repaired" ]]; then
                    log_info "Repaired metadata found in tmpfs - can attempt to continue"
                else
                    log_error "Repaired metadata NOT found in tmpfs!"
                    log_error "May need to recover from pmspare or backup"
                fi
                ;;
            metadata_written|txn_id_fixing|activating|recreating_pxreserve)
                log_info "Previous recovery completed the dangerous phase."
                log_info "Safe to restart and complete remaining steps."
                ;;
            *)
                log_info "Previous recovery stopped before writing to disk."
                log_info "Safe to restart - original data should be intact."
                ;;
        esac

        echo ""
        if ! confirm "Continue with recovery?"; then
            die "Aborted. Remove $STATE_FILE to start fresh."
        fi
    fi

    # Check for leftover tmpfs data
    if [[ -d "$TMPFS_DIR" ]] && [[ -f "$TMPFS_DIR/meta_repaired" ]]; then
        log_info "Found previous recovery data in $TMPFS_DIR"
        log_info "This will be overwritten if you continue."
    fi
}

check_vg_healthy() {
    log_step 0 "Checking if VG is already healthy"

    # Try to activate VG with timeout to prevent hanging in failure modes
    # that this script is meant to recover from
    if ! timeout 30 vgchange -ay "$VG_NAME" 2>/dev/null; then
        log_info "VG activation failed or timed out"
        return 1
    fi

    # Check if pool exists and is active
    local pool_status=$(lvs --noheadings -o lv_attr "$VG_NAME/$POOL_NAME" 2>/dev/null | tr -d ' ')
    if [[ -z "$pool_status" ]]; then
        log_info "Pool $VG_NAME/$POOL_NAME not found"
        return 1
    fi

    # Check if pool metadata is healthy (thin_check)
    local tmeta_dev="/dev/mapper/${VG_NAME}-${TMETA_LV}"
    if [[ -e "$tmeta_dev" ]]; then
        if thin_check "$tmeta_dev" 2>/dev/null; then
            log_info "Pool metadata passes thin_check"
            return 0
        else
            log_info "Pool metadata fails thin_check"
            return 1
        fi
    fi

    # Pool exists but can't verify metadata - assume unhealthy
    log_info "Cannot verify pool metadata"
    return 1
}

check_and_remove_pxreserve() {
    log_step 0 "Checking pxreserve volume"

    local reserve_lv="$VG_NAME/pxreserve"

    # Check if pxreserve exists
    if ! lvs "$reserve_lv" &>/dev/null; then
        log_info "pxreserve volume does not exist"
        return 0
    fi

    local reserve_size=$(lvs --noheadings -o lv_size --units g "$reserve_lv" 2>/dev/null | tr -d ' ')
    log_info "Found pxreserve: $reserve_size"

    # Check VG free space
    local vg_free=$(vgs --noheadings -o vg_free --units g "$VG_NAME" 2>/dev/null | tr -d ' ')
    log_info "VG free space: $vg_free"

    # If no/minimal free space and pxreserve exists, offer to remove it
    # Check for: "0", "0.00g", or "<X.XXg" (LVM uses < prefix for very small values)
    if [[ "$vg_free" == "0" ]] || [[ "$vg_free" == "0.00g" ]] || [[ "$vg_free" =~ ^\< ]]; then
        log_warn "No free space in VG - pxreserve may need to be removed for recovery"
        log_info "pxreserve size: $reserve_size"
        echo ""

        if confirm "Remove pxreserve to free up space for recovery?"; then
            log_info "Removing pxreserve..."
            lvremove -f "$reserve_lv"
            log_info "pxreserve removed"

            # Show new free space
            vg_free=$(vgs --noheadings -o vg_free --units g "$VG_NAME" 2>/dev/null | tr -d ' ')
            log_info "VG free space now: $vg_free"
        else
            log_warn "Continuing without removing pxreserve"
        fi
    fi
}

recreate_pxreserve() {
    log_step 0 "Recreating pxreserve volume"

    local reserve_lv="$VG_NAME/pxreserve"

    # Check VG free space
    local vg_free=$(vgs --noheadings -o vg_free --units g "$VG_NAME" 2>/dev/null | tr -d ' ')
    log_info "VG free space: $vg_free"

    # Check for no/minimal free space: "0", "0.00g", or "<X.XXg"
    if [[ "$vg_free" == "0" ]] || [[ "$vg_free" == "0.00g" ]] || [[ "$vg_free" =~ ^\< ]]; then
        log_info "No free space ($vg_free) - skipping pxreserve creation"
        return 0
    fi

    # Check if pxreserve already exists
    if lvs "$reserve_lv" &>/dev/null; then
        log_info "pxreserve already exists"
        return 0
    fi

    echo ""
    log_info "Creating pxreserve with remaining space ($vg_free) to ensure VG is 100% used"

    if confirm "Create pxreserve volume with $vg_free?"; then
        # Create pxreserve with all remaining free space, keep it deactivated
        lvcreate -n pxreserve -l 100%FREE -ky "$VG_NAME"

        if lvs "$reserve_lv" &>/dev/null; then
            local new_size=$(lvs --noheadings -o lv_size --units g "$reserve_lv" 2>/dev/null | tr -d ' ')
            log_info "pxreserve created: $new_size"

            # Verify VG is now 100% used
            vg_free=$(vgs --noheadings -o vg_free --units g "$VG_NAME" 2>/dev/null | tr -d ' ')
            log_info "VG free space now: $vg_free"
        else
            log_warn "Failed to create pxreserve"
        fi
    else
        log_info "Skipping pxreserve creation"
    fi
}

main "$@"

