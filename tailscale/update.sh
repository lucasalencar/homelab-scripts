#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib.sh" || { echo "Error: failed to load tailscale/lib.sh" >&2; exit 1; }

require_root

ROUTER_NAME="${TAILSCALE_ROUTER_NAME:-tailscale-router}"
LXC_CONF_DIR="${TAILSCALE_LXC_CONF_DIR:-/etc/pve/lxc}"

container_id=$(get_exact_container_id_by_name "$ROUTER_NAME" || true)
if [ -z "$container_id" ]; then
    log_error "Could not find container '$ROUTER_NAME'. Run tailscale/install.sh first."
    exit 1
fi
log_info "Router container: $container_id"

BRIDGE=$(detect_pve_bridge)
if [ -n "${TAILSCALE_LAN_CIDR:-}" ]; then
    LAN_CIDR="$TAILSCALE_LAN_CIDR"
else
    LAN_CIDR=$(detect_lan_cidr "$BRIDGE" || true)
    if [ -z "$LAN_CIDR" ]; then
        log_error "Could not determine the LAN CIDR on $BRIDGE."
        log_error "Re-run with an explicit value: TAILSCALE_LAN_CIDR='192.168.15.0/24' bash tailscale/update.sh"
        exit 1
    fi
fi
if ! validate_ipv4_cidr "$LAN_CIDR"; then
    log_error "Invalid LAN CIDR '$LAN_CIDR' (expected e.g. 192.168.15.0/24)."
    exit 1
fi

# Re-converge the invariants install.sh creates, so update also repairs drift.
log_step "Re-converging TUN passthrough and IP forwarding..."
tailscale_ensure_tun "$container_id" "$LXC_CONF_DIR" || exit 1
tailscale_ensure_forwarding "$container_id" || exit 1

log_step "Updating packages inside container $container_id..."
pct exec "$container_id" -- apt update
pct exec "$container_id" -- apt install -y --only-upgrade tailscale

log_step "Re-asserting advertised routes ($LAN_CIDR)..."
pct exec "$container_id" -- tailscale set --advertise-routes="$LAN_CIDR"

pct exec "$container_id" -- tailscale status >/dev/null 2>&1 \
    || { log_error "tailscale status failed — router is not on the tailnet"; exit 1; }

log_success "Tailscale update process complete!"
