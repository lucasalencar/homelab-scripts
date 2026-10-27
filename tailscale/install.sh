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

# Tailscale needs the host TUN device; nothing downstream can succeed without it.
if [ ! -c /dev/net/tun ] && [ -z "${BATS_TEST_TMPDIR:-}" ]; then
    log_error "/dev/net/tun is missing on this host — Tailscale cannot run without it."
    log_error "Load it (modprobe tun) or reboot, then re-run."
    exit 1
fi

BRIDGE=$(detect_pve_bridge)
log_info "Network bridge: $BRIDGE"

if [ -n "${TAILSCALE_LAN_CIDR:-}" ]; then
    LAN_CIDR="$TAILSCALE_LAN_CIDR"
else
    LAN_CIDR=$(detect_lan_cidr "$BRIDGE" || true)
    if [ -z "$LAN_CIDR" ]; then
        log_error "Could not determine the LAN CIDR on $BRIDGE."
        log_error "Re-run with an explicit value: TAILSCALE_LAN_CIDR='192.168.15.0/24' bash tailscale/install.sh"
        exit 1
    fi
fi
if ! validate_ipv4_cidr "$LAN_CIDR"; then
    log_error "Invalid LAN CIDR '$LAN_CIDR' (expected e.g. 192.168.15.0/24)."
    exit 1
fi
if [ "$LAN_CIDR" = "0.0.0.0/0" ]; then
    log_error "Refusing to advertise 0.0.0.0/0: this router is a LAN subnet router, not an exit node."
    exit 1
fi
log_info "LAN CIDR to advertise: $LAN_CIDR"

# --- 1. Find (counting duplicates) or create the dedicated router ---
mapfile -t ROUTER_IDS < <(pct list 2>/dev/null | awk -v target="$ROUTER_NAME" 'NR > 1 && $NF == target { print $1 }' || true)
if [ "${#ROUTER_IDS[@]}" -gt 1 ]; then
    log_error "Multiple containers named '$ROUTER_NAME' exist (${ROUTER_IDS[*]})."
    log_error "Remove or rename the duplicates before re-running — refusing to create another one."
    exit 1
fi

container_id=""
if [ "${#ROUTER_IDS[@]}" -eq 1 ] && [ -n "${ROUTER_IDS[0]}" ]; then
    container_id="${ROUTER_IDS[0]}"
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

# --- 4. Log in only when needed; the key is read from a pushed file, never argv ---
if pct exec "$container_id" -- tailscale status >/dev/null 2>&1; then
    log_info "Router already logged in — skipping 'tailscale up'."
    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
        log_warning "TAILSCALE_AUTHKEY is set but unused (already logged in)."
        log_warning "To rotate identity, run 'pct exec $container_id -- tailscale logout' first."
    fi
    log_warning "Confirm the tailnet identity before approving routes: pct exec $container_id -- tailscale status"
else
    if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
        log_error "Router is not on the tailnet and TAILSCALE_AUTHKEY is not set."
        log_error "Create an auth key in the admin console (reusable, tagged, short expiry) and re-run:"
        log_error "  TAILSCALE_AUTHKEY='tskey-...' bash tailscale/install.sh"
        exit 1
    fi
    log_step "Logging the router into the tailnet (auth key via pushed file, never argv)..."
    key_file=$(mktemp)
    chmod 600 "$key_file"
    # shellcheck disable=SC2064
    trap "rm -f '$key_file'" EXIT
    printf '%s' "$TAILSCALE_AUTHKEY" > "$key_file"
    pct push "$container_id" "$key_file" /tmp/ts-authkey
    if ! pct exec "$container_id" -- tailscale up --auth-key=file:/tmp/ts-authkey --advertise-routes="$LAN_CIDR" --accept-dns=false; then
        log_error "tailscale up failed — check the key and re-run"
        pct exec "$container_id" -- rm -f /tmp/ts-authkey 2>/dev/null || true
        rm -f "$key_file"
        trap - EXIT
        exit 1
    fi
    pct exec "$container_id" -- rm -f /tmp/ts-authkey
    rm -f "$key_file"
    trap - EXIT
fi
log_step "Asserting advertised routes ($LAN_CIDR)..."
pct exec "$container_id" -- tailscale set --advertise-routes="$LAN_CIDR"

# --- 5. Verify ---
pct exec "$container_id" -- tailscale status >/dev/null 2>&1 \
    || { log_error "tailscale status failed — router is not on the tailnet"; exit 1; }
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
log_info "A re-run restarts the router briefly when TUN/forwarding converge; plan accordingly."
log_info "Colleague access stays manual for now: no grants are created by this script (deny by default)."
