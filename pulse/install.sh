#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

PULSE_VERSION="${PULSE_VERSION:-latest}"

log_step "Starting Pulse monitoring installation (real-time Proxmox dashboard)..."

# --- 1. Create / find container ---
container_id=$(get_exact_container_id_by_name "pulse" || true)

if [ -z "$container_id" ]; then
    CT_CORES=2
    CT_MEMORY=2048
    CT_DISK=8
    CT_SWAP=512
    log_step "Container 'pulse' not found — creating new Debian 13 LXC (${CT_CORES} cores / ${CT_MEMORY} MB / ${CT_DISK}GB)..."

    CTID=$(get_pve_next_id) || exit 1
    log_info "Using CTID: $CTID"

    TEMPLATE_STORAGE=$(get_pve_template_storage)
    ROOTFS_STORAGE=$(get_pve_rootfs_storage)
    log_info "Template storage: $TEMPLATE_STORAGE | RootFS storage: $ROOTFS_STORAGE"

    BRIDGE=$(detect_pve_bridge)
    log_info "Network bridge: $BRIDGE"

    TEMPLATE=$(ensure_debian_template "13" "$TEMPLATE_STORAGE") || exit 1
    TEMPLATE_FILE=$(basename "$TEMPLATE")

    if ! create_lxc_container "$CTID" "pulse" "$TEMPLATE_STORAGE" "$TEMPLATE_FILE" "$ROOTFS_STORAGE" "$BRIDGE" "$CT_CORES" "$CT_MEMORY" "$CT_DISK" "$CT_SWAP" "pulse,monitoring" "Pulse: real-time Proxmox/Docker dashboard on :7655. Managed by proxmox-scripts/pulse."; then
        log_error "Failed to create pulse LXC"
        exit 1
    fi

    container_id="$CTID"
    log_success "Created container pulse (ID: $container_id)"
else
    log_info "Found existing pulse container (ID: $container_id) — reusing"
fi

# --- 2. Install Pulse inside container ---
log_step "Installing Pulse ${PULSE_VERSION} inside container $container_id..."

if ! exec_script_in_container "$container_id" "$SCRIPT_DIR/container/provision.sh" "$PULSE_VERSION"; then
    log_error "Failed to install Pulse inside container $container_id"
    exit 1
fi

log_success "Pulse installed inside container $container_id"

# --- 3. Report ---
container_ip=$(get_container_ip "$container_id")
if [ -n "$container_ip" ]; then
    log_success "──────────────────────────────────────────────────────"
    log_success "  Pulse: http://${container_ip}:7655"
    log_success "──────────────────────────────────────────────────────"
    echo ""
    log_info "First run:"
    log_info "  1. Get the setup token: pct exec $container_id -- docker exec pulse /app/pulse bootstrap-token"
    log_info "  2. Open http://${container_ip}:7655 and paste the token to create the admin account."
    log_info "  3. In Proxmox, create a read-only monitor user + API token:"
    log_info "     Datacenter -> Access -> Users -> Add (e.g. pulse@pve), Group: PVEAuditor role on /"
    log_info "     Select user -> API Tokens -> Add, copy token ID + secret."
    log_info "  4. In Pulse: Settings -> Infrastructure -> Add Proxmox + paste host, user, token."
    echo ""
    log_info "Caddy (single port, TLS internal):"
    log_info "  pulse.marx.home { tls internal; reverse_proxy ${container_ip}:7655 }"
    log_info "  Run: bash caddy/generate-caddyfile.sh"
else
    log_success "Pulse installed (container $container_id) — could not determine IP, check: pct exec $container_id -- hostname -I"
fi

echo ""
log_info "Update later with: bash pulse/update.sh"
log_info "Pin version with: PULSE_VERSION=vX.Y.Z bash pulse/install.sh"
