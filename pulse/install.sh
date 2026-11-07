#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh" || { echo "Error: failed to load pulse/lib.sh" >&2; exit 1; }

require_root

log_step "Starting Pulse installation via community script..."

# shellcheck disable=SC2016  # evaluated later via 'bash -c'
PULSE_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/pulse.sh)"'
container_id=$(ensure_container_installed "pulse" "$PULSE_INSTALL_CMD") || exit 1

log_info "Identified Container ID: $container_id"

configure_pulse_unprivileged_ping "$container_id" || exit 1

container_ip=$(get_container_ip "$container_id")

if [ -n "$container_ip" ]; then
    log_success "Pulse installed! Web UI: http://${container_ip}:7655"
    echo ""
    log_info "First run:"
    log_info "  1. Open http://${container_ip}:7655 and create the admin account."
    log_info "  2. In Proxmox, create a read-only monitor user + API token:"
    log_info "     Datacenter -> Access -> Users -> Add (e.g. pulse@pve), Group: PVEAuditor role on /"
    log_info "     Select user -> API Tokens -> Add, copy token ID + secret."
    log_info "  3. In Pulse: Settings -> Infrastructure -> Add Proxmox + paste host, user, token."
    echo ""
    log_info "Caddy (single port, TLS internal):"
    log_info "  pulse.marx.home { tls internal; reverse_proxy ${container_ip}:7655 }"
    log_info "  Run: bash caddy/generate-caddyfile.sh"
else
    log_success "Pulse installed (container $container_id) — could not determine IP, check: pct exec $container_id -- hostname -I"
fi

echo ""
log_info "Update later with: bash pulse/update.sh"
