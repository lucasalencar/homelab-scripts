#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

ROUTER_NAME="${TAILSCALE_ROUTER_NAME:-tailscale-router}"
ROUTER_TAGS="${TAILSCALE_ROUTER_TAGS:-no-auto-proxy}"
DNS_ZONE="${TAILSCALE_DNS_ZONE:-marx.home}"
LXC_CONF_DIR="${TAILSCALE_LXC_CONF_DIR:-/etc/pve/lxc}"

if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
    log_error "TAILSCALE_AUTHKEY is required (Tailscale auth key for the router node)."
    log_error "Create one in the admin console (reusable, tagged, short expiry) and re-run:"
    log_error "  TAILSCALE_AUTHKEY='tskey-...' bash tailscale/install.sh"
    exit 1
fi

# Resolves the LAN CIDR to advertise: explicit env wins, otherwise the
# connected route on the Proxmox bridge.
resolve_lan_cidr() {
    if [ -n "${TAILSCALE_LAN_CIDR:-}" ]; then
        echo "$TAILSCALE_LAN_CIDR"
        return 0
    fi
    local bridge="$1"
    ip -o route show dev "$bridge" scope link 2>/dev/null \
        | awk '{print $1}' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' \
        | head -1 || true
}

BRIDGE=$(detect_pve_bridge)
log_info "Network bridge: $BRIDGE"

LAN_CIDR=$(resolve_lan_cidr "$BRIDGE")
if [ -z "$LAN_CIDR" ]; then
    log_error "Could not detect the LAN CIDR on $BRIDGE."
    log_error "Re-run with an explicit value: TAILSCALE_LAN_CIDR='192.168.15.0/24' bash tailscale/install.sh"
    exit 1
fi
if ! [[ "$LAN_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    log_error "Invalid LAN CIDR '$LAN_CIDR' (expected e.g. 192.168.15.0/24)."
    exit 1
fi
log_info "LAN CIDR to advertise: $LAN_CIDR"

# --- 1. Create / find the dedicated router container ---
container_id=$(get_exact_container_id_by_name "$ROUTER_NAME" || true)

if [ -z "$container_id" ]; then
    log_step "Container '$ROUTER_NAME' not found — creating a dedicated router LXC (1 core / 512 MB)..."

    CTID=$(get_pve_next_id) || exit 1
    log_info "Using CTID: $CTID"

    TEMPLATE_STORAGE=$(get_pve_template_storage)
    ROOTFS_STORAGE=$(get_pve_rootfs_storage)
    log_info "Template storage: $TEMPLATE_STORAGE | RootFS storage: $ROOTFS_STORAGE"

    TEMPLATE=$(ensure_debian_template "13" "$TEMPLATE_STORAGE") || exit 1
    TEMPLATE_FILE=$(basename "$TEMPLATE")

    if ! create_lxc_container "$CTID" "$ROUTER_NAME" "$TEMPLATE_STORAGE" "$TEMPLATE_FILE" "$ROOTFS_STORAGE" "$BRIDGE" \
        1 512 8 512 "$ROUTER_TAGS" "Tailscale subnet router (advertises $LAN_CIDR). Managed by proxmox-scripts/tailscale. Never add a Caddy route for it."; then
        log_error "Failed to create $ROUTER_NAME LXC"
        exit 1
    fi

    container_id="$CTID"
    log_success "Created container $ROUTER_NAME (ID: $container_id)"
else
    log_info "Found existing $ROUTER_NAME container (ID: $container_id) — reusing"
fi

# --- 2. TUN passthrough (Tailscale needs /dev/net/tun inside the LXC) ---
log_step "Ensuring TUN passthrough for container $container_id..."
if [ ! -c /dev/net/tun ]; then
    log_warning "/dev/net/tun is missing on the host — Tailscale cannot start without it."
fi
mkdir -p "$LXC_CONF_DIR"
conf_file="$LXC_CONF_DIR/${container_id}.conf"
touch "$conf_file"
tun_changed=0
if ! grep -qxF "lxc.cgroup2.devices.allow: c 10:200 rwm" "$conf_file"; then
    echo "lxc.cgroup2.devices.allow: c 10:200 rwm" >> "$conf_file"
    tun_changed=1
fi
if ! grep -qxF "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" "$conf_file"; then
    echo "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file" >> "$conf_file"
    tun_changed=1
fi
if [ "$tun_changed" = "1" ]; then
    log_info "TUN config changed — restarting container to apply..."
    pct stop "$container_id" 2>/dev/null || true
    pct start "$container_id"
    wait_container_ready "$container_id" || { log_error "Container not ready after TUN change"; exit 1; }
else
    pct start "$container_id" 2>/dev/null || true
    wait_container_ready "$container_id" || { log_error "Container not ready"; exit 1; }
fi

# --- 3. IP forwarding inside the router ---
log_step "Enabling IPv4 forwarding inside container $container_id..."
pct exec "$container_id" -- sysctl -w net.ipv4.ip_forward=1
pct exec "$container_id" -- sh -c 'echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-tailscale.conf'

# --- 4. Install Tailscale (official script is idempotent) ---
log_step "Installing Tailscale inside container $container_id..."
pct exec "$container_id" -- bash -c 'curl -fsSL -o /tmp/tailscale-install.sh https://tailscale.com/install.sh && sh /tmp/tailscale-install.sh'
pct exec "$container_id" -- systemctl enable --now tailscaled

# --- 5. Log in only when needed; always re-assert the advertised routes ---
if pct exec "$container_id" -- tailscale status >/dev/null 2>&1; then
    log_info "Router already logged in — skipping 'tailscale up'"
else
    log_step "Logging the router into the tailnet (auth key via pushed file, never argv)..."
    key_file=$(mktemp)
    chmod 600 "$key_file"
    # shellcheck disable=SC2064  # expanded now: trap must capture this file
    trap "rm -f '$key_file'" EXIT
    printf '%s' "$TAILSCALE_AUTHKEY" > "$key_file"
    pct push "$container_id" "$key_file" /tmp/ts-authkey
    # $() runs inside the container's bash, not ours
    # shellcheck disable=SC2016
    pct exec "$container_id" -- bash -c 'tailscale up --auth-key="$(cat /tmp/ts-authkey)" --advertise-routes='"$LAN_CIDR"' --accept-dns=false; rc=$?; rm -f /tmp/ts-authkey; exit $rc' \
        || { log_error "tailscale up failed — check the key and re-run"; exit 1; }
    rm -f "$key_file"
    trap - EXIT
fi
log_step "Asserting advertised routes ($LAN_CIDR)..."
pct exec "$container_id" -- tailscale set --advertise-routes="$LAN_CIDR"

# --- 6. Verify ---
pct exec "$container_id" -- tailscale status >/dev/null 2>&1 \
    || { log_error "tailscale status failed — router is not on the tailnet"; exit 1; }
router_ip=$(get_container_ip "$container_id")
log_success "Tailscale router ready (container $container_id, IP: ${router_ip:-unknown}, routes: $LAN_CIDR)."

# --- 7. Manual console steps (no API: stays explicit and reviewable) ---
dns_ip="${TAILSCALE_DNS_IP:-}"
if [ -z "$dns_ip" ]; then
    adguard_id=$(get_container_id_by_name "adguard" || true)
    if [ -n "$adguard_id" ]; then
        dns_ip=$(get_container_ip "$adguard_id" || true)
    fi
fi
echo ""
log_step "Manual follow-ups in the Tailscale admin console:"
log_info "  1. Approve the route $LAN_CIDR for $ROUTER_NAME; disable key expiry for it."
log_info "  2. DNS: add a split-DNS entry for $DNS_ZONE pointing at ${dns_ip:-<AdGuard-IP>} (must be inside $LAN_CIDR)."
log_info "  3. On your devices: install Tailscale with the same identity; run 'tailscale set --accept-routes' on Linux."
log_info "  4. From off-LAN with VPN on: ping a LAN IP, then open the usual $DNS_ZONE URLs (fail-closed with VPN off)."
echo ""
log_warning "Caddy: '$ROUTER_NAME' carries the '$ROUTER_TAGS' tag — skip it when running caddy/generate-caddyfile.sh."
log_info "Colleague access stays manual for now: no grants are created by this script (deny by default)."
