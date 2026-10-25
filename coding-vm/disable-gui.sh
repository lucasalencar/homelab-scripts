#!/bin/bash
#
# Re-provisions an existing coding VM back to headless mode.
# Disables the desktop services and system RDP; SSH access is untouched.
# Pair script of enable-gui.sh — run whichever matches current needs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

VM_NAME="${CODING_VM_NAME:-code}"
WAIT_TIMEOUT="${CODING_VM_WAIT_TIMEOUT:-300}"
PROVISION_KEY_FILE="${CODING_VM_PROVISION_KEY_FILE:-/root/.ssh/coding-vm-$VM_NAME}"

if [ ! -f "$PROVISION_KEY_FILE" ]; then
    log_error "Provisioning key $PROVISION_KEY_FILE not found (created by install.sh on first run)."
    exit 1
fi

log_step "Disabling desktop + RDP on coding VM ($VM_NAME)..."

vmid=$(get_vm_id_by_name "$VM_NAME" || true)
if [ -z "$vmid" ]; then
    log_error "Could not find VM '$VM_NAME'."
    exit 1
fi
log_info "Identified VM ID: $vmid"

vm_status=$(qm status "$vmid" | awk '{print $2}' || true)
if [ "$vm_status" != "running" ]; then
    log_step "Starting VM $vmid..."
    qm start "$vmid"
    # wait_vm_ready polls every WAIT_SLEEP_S seconds; attempts cover WAIT_TIMEOUT
    WAIT_SLEEP_S=5
    wait_vm_ready "$vmid" "$(( (WAIT_TIMEOUT + WAIT_SLEEP_S - 1) / WAIT_SLEEP_S ))" "$WAIT_SLEEP_S" || exit 1
fi

vm_ip=$(get_vm_ip "$vmid")
if [ -z "$vm_ip" ]; then
    log_error "Could not determine IP for VM $vmid."
    exit 1
fi
log_info "VM IP: $vm_ip"

CI_USER=$(qm config "$vmid" 2>/dev/null | awk -F': ' '/^ciuser:/ {print $2}' || true)
if [ -z "$CI_USER" ]; then
    CI_USER=$(get_primary_user) || exit 1
fi

ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$PROVISION_KEY_FILE")
log_step "Pushing guest provision script..."
scp "${ssh_opts[@]}" "$SCRIPT_DIR/provision.sh" "$CI_USER@$vm_ip:/tmp/coding-vm-provision.sh"

guest_env=("CODING_VM_USER=$CI_USER" "CODING_VM_GUI=0")

log_step "Removing desktop services (guest stays reachable over SSH)..."
ssh "${ssh_opts[@]}" "$CI_USER@$vm_ip" sudo env "${guest_env[@]}" bash /tmp/coding-vm-provision.sh

log_step "Validating guest..."
ssh "${ssh_opts[@]}" "$CI_USER@$vm_ip" sudo env "${guest_env[@]}" bash /tmp/coding-vm-provision.sh --check-only

echo ""
log_success "Desktop + RDP disabled on '$VM_NAME' (ID: $vmid) — headless, SSH only."
