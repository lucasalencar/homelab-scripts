#!/usr/bin/env bash
# Shared Pulse helpers.
# Sourced by install.sh AFTER common/functions.sh.
# Not executed directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

# Enables unprivileged ICMP probes for the pulse user inside the container.
# Applies immediately and persists across reboots. Idempotent.
# Usage: configure_pulse_unprivileged_ping <container_id>
configure_pulse_unprivileged_ping() {
    local container_id="${1:-}"
    if [ -z "$container_id" ]; then
        log_error "configure_pulse_unprivileged_ping: missing container_id"
        return 1
    fi

    local gid
    gid=$(pct exec "$container_id" -- id -g pulse 2>/dev/null | tr -d '[:space:]' || true)
    if [ -z "$gid" ] || ! [[ "$gid" =~ ^[0-9]+$ ]]; then
        log_error "Could not determine gid for user 'pulse' in container $container_id"
        return 1
    fi

    local conf
    conf="/etc/sysctl.d/99-pulse-unprivileged-ping.conf"
    local desired
    desired="net.ipv4.ping_group_range = 0 $gid"
    local current
    current=$(pct exec "$container_id" -- cat "$conf" 2>/dev/null || true)
    if [ "$current" != "$desired" ]; then
        log_info "Allowing ICMP echo sockets for gid $gid in container $container_id..."
        pct exec "$container_id" -- sh -c "printf '%s\n' '$desired' > '$conf'"
    fi
    pct exec "$container_id" -- sysctl -w "net.ipv4.ping_group_range=0 $gid" >/dev/null

    if pct exec "$container_id" -- su -s /bin/sh pulse -c 'ping -c1 -W2 127.0.0.1' >/dev/null 2>&1; then
        log_info "ICMP probe verified for user pulse in container $container_id."
    else
        log_warning "ICMP probe still blocked in container $container_id — check ping_group_range and container restrictions"
    fi
}
