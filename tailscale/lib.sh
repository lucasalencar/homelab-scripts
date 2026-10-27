#!/bin/bash
# Shared Tailscale router converge helpers.
# Sourced by install.sh / update.sh AFTER common/functions.sh.
# Not executed directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

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
