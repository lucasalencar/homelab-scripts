#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

ROUTER_NAME="${TAILSCALE_ROUTER_NAME:-tailscale-router}"
BRIDGE=$(detect_pve_bridge)

container_id=$(get_exact_container_id_by_name "$ROUTER_NAME" || true)
if [ -z "$container_id" ]; then
    log_error "Could not find container '$ROUTER_NAME'. Run tailscale/install.sh first."
    exit 1
fi
log_info "Router container: $container_id"

log_step "Updating packages inside container $container_id..."
pct exec "$container_id" -- apt update
pct exec "$container_id" -- apt install -y --only-upgrade tailscale

if [ -n "${TAILSCALE_LAN_CIDR:-}" ]; then
    LAN_CIDR="$TAILSCALE_LAN_CIDR"
else
    LAN_CIDR=$(ip -o route show dev "$BRIDGE" scope link 2>/dev/null \
        | awk '{print $1}' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
        | head -1 || true)
fi
if [ -n "${LAN_CIDR:-}" ]; then
    log_step "Re-asserting advertised routes ($LAN_CIDR)..."
    pct exec "$container_id" -- tailscale set --advertise-routes="$LAN_CIDR"
else
    log_warning "LAN CIDR not detected — skipping route re-assertion (set TAILSCALE_LAN_CIDR to force it)."
fi

pct exec "$container_id" -- tailscale status >/dev/null 2>&1 \
    || { log_error "tailscale status failed — router is not on the tailnet"; exit 1; }

log_success "Tailscale update process complete!"
