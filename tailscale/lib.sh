#!/bin/bash
# Shared Tailscale router converge helpers.
# Sourced by install.sh / update.sh AFTER common/functions.sh.
# Not executed directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

# Fails fast when the host TUN device is missing — nothing downstream can
# succeed without it. Skipped under BATS_TEST_TMPDIR, mirroring the
# require_root test bypass (the device node cannot be mocked).
# Usage: tailscale_require_host_tun || exit 1
tailscale_require_host_tun() {
    if [ ! -c /dev/net/tun ] && [ -z "${BATS_TEST_TMPDIR:-}" ]; then
        log_error "/dev/net/tun is missing on this host — Tailscale cannot run without it."
        log_error "Load it (modprobe tun) or reboot, then re-run."
        return 1
    fi
}

# Resolves the LAN CIDR to advertise: explicit env wins, otherwise strict
# auto-detection (fails on zero or multiple connected routes). Also refuses
# 0.0.0.0/0: this router is a LAN subnet router, never an exit node.
# Usage: lan_cidr=$(tailscale_resolve_lan_cidr "bash tailscale/install.sh") || exit 1
tailscale_resolve_lan_cidr() {
    local rerun_hint="${1:-re-run with an explicit CIDR}"
    local cidr="${TAILSCALE_LAN_CIDR:-}"
    if [ -z "$cidr" ]; then
        local bridge
        bridge=$(detect_pve_bridge)
        cidr=$(detect_lan_cidr "$bridge" || true)
        if [ -z "$cidr" ]; then
            log_error "Could not determine the LAN CIDR on $bridge."
            log_error "Re-run with an explicit value: TAILSCALE_LAN_CIDR='192.168.15.0/24' $rerun_hint"
            return 1
        fi
    fi
    if ! validate_ipv4_cidr "$cidr"; then
        log_error "Invalid LAN CIDR '$cidr' (expected e.g. 192.168.15.0/24)."
        return 1
    fi
    if [ "$cidr" = "0.0.0.0/0" ]; then
        log_error "Refusing to advertise 0.0.0.0/0: this router is a LAN subnet router, not an exit node."
        return 1
    fi
    printf '%s\n' "$cidr"
}

# Ensures /dev/net/tun passthrough lines in the LXC config, restarting the
# container once when the config changed.
# Usage: tailscale_ensure_tun <container_id> [conf_dir]
tailscale_ensure_tun() {
    local container_id="${1:-}"
    local conf_dir="${2:-/etc/pve/lxc}"
    if [ -z "$container_id" ]; then
        log_error "tailscale_ensure_tun: missing container_id"
        return 1
    fi
    mkdir -p "$conf_dir"
    local conf_file="$conf_dir/${container_id}.conf"
    touch "$conf_file"
    local changed=0
    local line
    for line in "lxc.cgroup2.devices.allow: c 10:200 rwm" "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"; do
        if ! grep -qxF "$line" "$conf_file"; then
            echo "$line" >> "$conf_file"
            changed=1
        fi
    done
    if [ "$changed" = "1" ]; then
        log_info "TUN config changed — restarting container $container_id to apply..."
        pct stop "$container_id" 2>/dev/null || true
        pct start "$container_id"
    else
        pct start "$container_id" 2>/dev/null || true
    fi
    wait_container_ready "$container_id" || { log_error "Container $container_id not ready"; return 1; }
}

# Ensures IPv4 forwarding runtime + persisted inside the router.
# Usage: tailscale_ensure_forwarding <container_id>
tailscale_ensure_forwarding() {
    local container_id="${1:-}"
    if [ -z "$container_id" ]; then
        log_error "tailscale_ensure_forwarding: missing container_id"
        return 1
    fi
    pct exec "$container_id" -- sysctl -w net.ipv4.ip_forward=1
    pct exec "$container_id" -- sh -c 'echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-tailscale.conf'
}

# Logs the router into the tailnet when needed; skips when already online.
# The key travels via a pushed 0600 file read with --auth-key=file: —
# never in argv, logs, or the process list.
# Usage: tailscale_login_with_key <container_id> <lan_cidr> || exit 1
tailscale_login_with_key() {
    local container_id="${1:-}"
    local lan_cidr="${2:-}"
    if [ -z "$container_id" ] || [ -z "$lan_cidr" ]; then
        log_error "tailscale_login_with_key: missing container_id or lan_cidr"
        return 1
    fi
    if pct exec "$container_id" -- tailscale status >/dev/null 2>&1; then
        log_info "Router already logged in — skipping 'tailscale up'."
        if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
            log_warning "TAILSCALE_AUTHKEY is set but unused (already logged in)."
            log_warning "To rotate identity, run 'pct exec $container_id -- tailscale logout' first."
        fi
        log_warning "Confirm the tailnet identity before approving routes: pct exec $container_id -- tailscale status"
        return 0
    fi
    if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
        log_error "Router is not on the tailnet and TAILSCALE_AUTHKEY is not set."
        log_error "Create an auth key in the admin console (reusable, tagged, short expiry) and re-run:"
        log_error "  TAILSCALE_AUTHKEY='tskey-...' bash tailscale/install.sh"
        return 1
    fi
    log_step "Logging the router into the tailnet (auth key via pushed file, never argv)..."
    local key_file
    key_file=$(mktemp)
    chmod 600 "$key_file"
    # shellcheck disable=SC2064
    trap "rm -f '$key_file'" EXIT
    printf '%s' "$TAILSCALE_AUTHKEY" > "$key_file"
    pct push "$container_id" "$key_file" /tmp/ts-authkey
    pct exec "$container_id" -- chmod 600 /tmp/ts-authkey
    local up_rc=0
    pct exec "$container_id" -- tailscale up --auth-key=file:/tmp/ts-authkey --advertise-routes="$lan_cidr" --accept-dns=false || up_rc=$?
    # Cleanup must never fail the run — the login already happened (or not).
    pct exec "$container_id" -- rm -f /tmp/ts-authkey 2>/dev/null || true
    rm -f "$key_file"
    trap - EXIT
    if [ "$up_rc" -ne 0 ]; then
        log_error "tailscale up failed — check the key and re-run"
        return 1
    fi
}

# Replaces the whole advertised route set with the LAN CIDR (single-subnet
# ownership: extra manual routes are removed on the next run by design).
# Usage: tailscale_set_routes <container_id> <lan_cidr> || exit 1
tailscale_set_routes() {
    local container_id="${1:-}"
    local lan_cidr="${2:-}"
    if [ -z "$container_id" ] || [ -z "$lan_cidr" ]; then
        log_error "tailscale_set_routes: missing container_id or lan_cidr"
        return 1
    fi
    log_step "Asserting advertised routes ($lan_cidr)..."
    pct exec "$container_id" -- tailscale set --advertise-routes="$lan_cidr"
}

# Verifies the router is on the tailnet.
# Usage: tailscale_verify_online <container_id> || exit 1
tailscale_verify_online() {
    local container_id="${1:-}"
    if [ -z "$container_id" ]; then
        log_error "tailscale_verify_online: missing container_id"
        return 1
    fi
    pct exec "$container_id" -- tailscale status >/dev/null 2>&1 \
        || { log_error "tailscale status failed — router is not on the tailnet"; return 1; }
}
