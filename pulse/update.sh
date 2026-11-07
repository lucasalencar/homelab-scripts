#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

log_step "Checking for Pulse updates..."

container_id=$(get_exact_container_id_by_name "pulse" || true)

if [ -z "$container_id" ]; then
    log_error "Could not find container 'pulse'. Run install.sh first."
    exit 1
fi

log_info "Container ID: $container_id"

log_step "Running apt update and upgrade inside container $container_id..."
pct exec "$container_id" -- bash -c 'apt update && apt upgrade -y'

log_step "Updating Pulse container (docker compose pull + up)..."
if ! exec_script_in_container "$container_id" "$SCRIPT_DIR/container/update.sh"; then
    log_error "Pulse update failed inside container $container_id"
    exit 1
fi

log_success "Pulse update complete!"

container_ip=$(get_container_ip "$container_id" 2>/dev/null || echo "")
if [ -n "$container_ip" ]; then
    log_info "Access: http://${container_ip}:7655"
fi
