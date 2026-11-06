#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

log_step "Installing jq on Proxmox host..."
apt install -y jq

log_step "Starting AdGuard Home installation/configuration via LXC container..."

# shellcheck disable=SC2016  # evaluated later via 'bash -c'
ADGUARD_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/adguard.sh)"'
container_id=$(ensure_container_installed "adguard" "$ADGUARD_INSTALL_CMD") || exit 1

log_info "Identified Container ID: $container_id"

# AdGuard must keep a stable IP: Caddy reverse_proxy entries and the
# *.marx.home rewrites point at it. Pin it (idempotent; restarts the CT
# only when the address changes). Other packages stay on DHCP.
pct start "$container_id" 2>/dev/null || true
ensure_static_ip "$container_id" "${ADGUARD_STATIC_IP:-192.168.31.22/24}" "${LAN_GATEWAY:-192.168.31.1}" || exit 1

log_success "Installation completed for AdGuard Home (ID: $container_id)."

echo ""
log_step "Running upstream DNS setup..."
bash "$SCRIPT_DIR/setup-upstream.sh"

echo ""
log_step "Running DNS rewrite setup..."
bash "$SCRIPT_DIR/setup-dns.sh"
