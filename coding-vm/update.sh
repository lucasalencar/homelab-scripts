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

log_step "Running apt update and upgrade inside VM $vm_id..."
qm guest exec "$vm_id" -- apt-get update
qm guest exec "$vm_id" -- apt-get upgrade -y
qm guest exec "$vm_id" -- snap refresh 2>/dev/null || log_warning "snap refresh skipped."

log_success "Coding VM update process complete!"
