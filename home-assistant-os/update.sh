#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

log_step "Checking for Home Assistant OS VM updates..."

vm_id=$(get_vm_id_by_name "haos")

if [ -z "$vm_id" ]; then
    log_error "Could not find VM 'haos'."
    exit 1
fi

log_info "Identified VM ID: $vm_id"

vm_status=$(qm status "$vm_id" | awk '{print $2}' || true)
if [ "$vm_status" != "running" ]; then
    log_warning "VM $vm_id is not running. Start it to apply updates."
    exit 0
fi

log_step "Attempting Home Assistant OS update via guest agent..."
qm guest exec "$vm_id" -- ha core update 2>/dev/null || echo "Could not run 'ha core update' via guest agent."
qm guest exec "$vm_id" -- ha supervisor update 2>/dev/null || echo "Could not run 'ha supervisor update' via guest agent."

log_success "Home Assistant OS update process complete!"
