#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib.sh" || { echo "Error: failed to load tailscale/lib.sh" >&2; exit 1; }

require_root

ROUTER_NAME="${TAILSCALE_ROUTER_NAME:-tailscale-router}"
DNS_ZONE="${TAILSCALE_DNS_ZONE:-marx.home}"
LXC_CONF_DIR="${TAILSCALE_LXC_CONF_DIR:-/etc/pve/lxc}"

tailscale_require_host_tun || exit 1

BRIDGE=$(detect_pve_bridge)
log_info "Network bridge: $BRIDGE"

LAN_CIDR=$(tailscale_resolve_lan_cidr "bash tailscale/install.sh") || exit 1
log_info "LAN CIDR to advertise: $LAN_CIDR"

# --- 1. Find (exact, duplicates are fatal) or create the dedicated router ---
container_id=""
resolve_rc=0
container_id=$(get_exact_container_id_by_name "$ROUTER_NAME" 2>/dev/null) || resolve_rc=$?
if [ "$resolve_rc" -eq 2 ]; then
    log_error "Multiple containers named '$ROUTER_NAME' exist."
    log_error "Remove or rename the duplicates before re-running — refusing to create another one."
    exit 1
fi

# A fresh router can never be logged in, so require the key before creating anything.
if [ -z "$container_id" ] && [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
    log_error "No '$ROUTER_NAME' container exists and TAILSCALE_AUTHKEY is not set."
    log_error "Create an auth key in the admin console (reusable, tagged, short expiry) and re-run:"
    log_error "  TAILSCALE_AUTHKEY='tskey-...' bash tailscale/install.sh"
    exit 1
fi

if [ -z "$container_id" ]; then
    log_step "Container '$ROUTER_NAME' not found — creating a dedicated router LXC (1 core / 512 MB)..."

    CTID=$(get_pve_next_id) || exit 1
    log_info "Using CTID: $CTID"

    TEMPLATE_STORAGE=$(get_pve_template_storage)
    ROOTFS_STORAGE=$(get_pve_rootfs_storage)
    log_info "Template storage: $TEMPLATE_STORAGE | RootFS storage: $ROOTFS_STORAGE"

    TEMPLATE=$(ensure_debian_template "13" "$TEMPLATE_STORAGE") || exit 1
    TEMPLATE_FILE=$(basename "$TEMPLATE")

    # The no-auto-proxy tag is a safety invariant (never Caddy-proxied), not a preference.
    if ! create_lxc_container "$CTID" "$ROUTER_NAME" "$TEMPLATE_STORAGE" "$TEMPLATE_FILE" "$ROOTFS_STORAGE" "$BRIDGE" \
        1 512 8 512 "no-auto-proxy" "Tailscale subnet router (advertises $LAN_CIDR). Managed by proxmox-scripts/tailscale. Never add a Caddy route for it."; then
        log_error "Failed to create $ROUTER_NAME LXC"
        exit 1
    fi

    container_id="$CTID"
    log_success "Created container $ROUTER_NAME (ID: $container_id)"
else
    log_info "Found existing $ROUTER_NAME container (ID: $container_id) — reusing"
fi

# --- 2. Converge TUN passthrough + IP forwarding ---
log_step "Ensuring TUN passthrough for container $container_id..."
tailscale_ensure_tun "$container_id" "$LXC_CONF_DIR" || exit 1
log_step "Enabling IPv4 forwarding inside container $container_id..."
tailscale_ensure_forwarding "$container_id" || exit 1

# --- 3. Install Tailscale (official script is idempotent; download first so a fetch failure surfaces here) ---
log_step "Installing Tailscale inside container $container_id..."
pct exec "$container_id" -- bash -c 'curl -fsSL --proto "=https" --tlsv1.2 -o /tmp/tailscale-install.sh https://tailscale.com/install.sh && sh /tmp/tailscale-install.sh'
pct exec "$container_id" -- systemctl enable --now tailscaled

# --- 4. Log in (only when needed) and assert routes ---
tailscale_login_with_key "$container_id" "$LAN_CIDR" || exit 1
tailscale_set_routes "$container_id" "$LAN_CIDR" || exit 1

# --- 5. Verify ---
tailscale_verify_online "$container_id" || exit 1
router_lan_ip=$(get_container_ip "$container_id")
log_success "Tailscale router ready (container $container_id, LAN IP: ${router_lan_ip:-unknown}, routes: $LAN_CIDR)."

# --- 6. Manual console steps (no API: stays explicit and reviewable) ---
adguard_ip="${TAILSCALE_DNS_IP:-}"
if [ -z "$adguard_ip" ]; then
    adguard_id=$(get_container_id_by_name "adguard" || true)
    if [ -n "$adguard_id" ]; then
        adguard_ip=$(get_container_ip "$adguard_id" || true)
    fi
fi
echo ""
log_step "Manual follow-ups in the Tailscale admin console:"
log_info "  1. Approve the route $LAN_CIDR for $ROUTER_NAME; disable key expiry for it."
log_info "  2. DNS: add a split-DNS entry for $DNS_ZONE pointing at ${adguard_ip:-<AdGuard-IP>} (must be inside $LAN_CIDR)."
log_info "  3. On your devices: install Tailscale with the same identity; run 'tailscale set --accept-routes' on Linux."
log_info "  4. From off-LAN with VPN on: ping a LAN IP, then open the usual $DNS_ZONE URLs (fail-closed with VPN off)."
echo ""
log_warning "Caddy: '$ROUTER_NAME' carries the 'no-auto-proxy' tag — skip it when running caddy/generate-caddyfile.sh."
log_info "A re-run restarts the router briefly whenever TUN/forwarding converge; plan accordingly."
log_info "Colleague access stays manual for now: no grants are created by this script (deny by default)."
