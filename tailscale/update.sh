#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib.sh" || { echo "Error: failed to load tailscale/lib.sh" >&2; exit 1; }

require_root

ROUTER_NAME="${TAILSCALE_ROUTER_NAME:-tailscale-router}"
LXC_CONF_DIR="${TAILSCALE_LXC_CONF_DIR:-/etc/pve/lxc}"

container_id=""
resolve_rc=0
container_id=$(get_exact_container_id_by_name "$ROUTER_NAME" 2>/dev/null) || resolve_rc=$?
if [ "$resolve_rc" -eq 2 ]; then
    log_error "Multiple containers named '$ROUTER_NAME' exist."
    log_error "Remove or rename the duplicates instead of updating blindly."
    exit 1
fi
if [ -z "$container_id" ]; then
    log_error "Could not find container '$ROUTER_NAME'. Run tailscale/install.sh first."
    exit 1
fi
log_info "Router container: $container_id"

tailscale_require_host_tun || exit 1

LAN_CIDR=$(tailscale_resolve_lan_cidr "bash tailscale/update.sh") || exit 1

# Re-converge the invariants install.sh creates, so update also repairs drift.
log_step "Re-converging TUN passthrough and IP forwarding..."
tailscale_ensure_tun "$container_id" "$LXC_CONF_DIR" || exit 1
tailscale_ensure_forwarding "$container_id" || exit 1

log_step "Updating packages inside container $container_id..."
pct exec "$container_id" -- apt update
pct exec "$container_id" -- apt install -y --only-upgrade tailscale

tailscale_set_routes "$container_id" "$LAN_CIDR" || exit 1
tailscale_verify_online "$container_id" || exit 1

log_success "Tailscale update process complete!"
