#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

VM_NAME="${CODING_VM_NAME:-code}"

log_step "Checking for coding VM updates..."

vm_id=$(get_vm_id_by_name "$VM_NAME")

if [ -z "$vm_id" ]; then
    log_error "Could not find VM '$VM_NAME'."
    exit 1
fi

log_info "Identified VM ID: $vm_id"

vm_status=$(qm status "$vm_id" | awk '{print $2}' || true)
if [ "$vm_status" != "running" ]; then
    log_warning "VM $vm_id is not running. Start it to apply updates."
    exit 0
fi

# Fail fast with a clear message when guest DNS is broken — apt would
# otherwise spew a resolution error per source and abort mid-script.
if ! guest_exec_wait "$vm_id" 60 6 -- getent hosts archive.ubuntu.com >/dev/null 2>&1; then
    log_error "VM $vm_id cannot resolve archive.ubuntu.com — guest DNS is broken. Inspect with 'qm guest cmd $vm_id network-get-interfaces' (missing DHCP lease? try netplan apply) and re-run."
    exit 1
fi

log_step "Running apt update and upgrade inside VM $vm_id..."
# Non-interactive frontend: with no tty, debconf falls back noisily and any
# prompt would hang the guest-side command indefinitely.
# guest_exec_wait survives the qm exec timeout by polling exec-status until
# the guest command exits, then mirrors its exit code.
guest_exec_wait "$vm_id" 120 30 -- env DEBIAN_FRONTEND=noninteractive apt-get update
guest_exec_wait "$vm_id" 600 180 -- env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
guest_exec_wait "$vm_id" 300 30 -- snap refresh 2>/dev/null || log_warning "snap refresh skipped."

log_success "Coding VM update process complete!"
