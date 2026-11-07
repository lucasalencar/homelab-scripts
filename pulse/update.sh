#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

log_step "Checking for Pulse container updates..."

container_id=$(get_container_id_by_name "pulse")

if [ -z "$container_id" ]; then
    log_error "Could not find container 'pulse'. Run install.sh first."
    exit 1
fi

log_info "Identified Container ID: $container_id"

# Re-running the community script updates Pulse in place when the
# container already exists (their documented update flow).
log_step "Re-running community Pulse script (updates in place)..."
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/pulse.sh)"

log_success "Pulse update process complete!"

container_ip=$(get_container_ip "$container_id" 2>/dev/null || echo "")
if [ -n "$container_ip" ]; then
    log_info "Access: http://${container_ip}:7655"
fi
