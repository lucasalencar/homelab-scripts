#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

log_step "Starting Caddy installation/configuration via LXC container..."

# shellcheck disable=SC2016  # evaluated later via 'bash -c'
CADDY_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/caddy.sh)"'
container_id=$(ensure_container_installed "caddy" "$CADDY_INSTALL_CMD") || exit 1

log_info "Identified Container ID: $container_id"

pct start "$container_id"
wait_container_ready "$container_id" || { log_error "Container not ready"; exit 1; }

CADDY_IP=$(get_container_ip "$container_id")
log_info "Caddy container IP: $CADDY_IP"

log_success "Installation completed for Caddy (ID: $container_id, IP: $CADDY_IP)."
log_info "Update AdGuard DNS wildcard *.marx.home to point to $CADDY_IP"
