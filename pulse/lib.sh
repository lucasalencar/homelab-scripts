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

# Prints the Pulse API base URL by discovering the pulse container IP.
# Usage: base=$(pulse_api_base [pulse_name])
pulse_api_base() {
    local pulse_name="${1:-${PULSE_CONTAINER_NAME:-pulse}}"
    local pulse_id pulse_ip
    pulse_id=$(get_container_id_by_name "$pulse_name" || true)
    if [ -z "$pulse_id" ]; then
        log_error "Could not find container '$pulse_name'."
        return 1
    fi
    pulse_ip=$(get_container_ip "$pulse_id" 2>/dev/null || true)
    if [ -z "$pulse_ip" ]; then
        log_error "Could not determine IP of container '$pulse_name' ($pulse_id)."
        return 1
    fi
    echo "http://${pulse_ip}:7655"
}

# Creates a 0600 curl header file carrying the API token; prints its path.
# The caller owns cleanup (trap). The token never appears in argv.
# Usage: header=$(pulse_api_header "$token"); trap 'rm -f "$header"' EXIT
pulse_api_header() {
    local token="${1:-}"
    if [ -z "$token" ]; then
        log_error "pulse_api_header: missing token"
        return 1
    fi
    local header
    header=$(mktemp)
    chmod 600 "$header"
    printf 'X-API-Token: %s\n' "$token" > "$header"
    echo "$header"
}

# GETs availability targets as a normalized JSON array (both API shapes).
# Usage: list=$(pulse_availability_list "$base" "$header")
pulse_availability_list() {
    local base="${1:-}"
    local header="${2:-}"
    local resp
    resp=$(curl -fsS -H @"$header" "$base/api/availability-targets" 2>/dev/null || true)
    if [ -z "$resp" ]; then
        resp="[]"
    fi
    printf '%s' "$resp" | jq -c 'if type == "array" then . elif type == "object" then (.targets // []) else [] end' 2>/dev/null || echo "[]"
}

# Prints the canonical JSON payload for one availability target.
# Port is included for tcp/udp, omitted for icmp.
# Usage: payload=$(pulse_availability_payload <name> <address> <protocol> [port] [poll] [timeout] [threshold])
pulse_availability_payload() {
    local name="${1:-}"
    local address="${2:-}"
    local protocol="${3:-icmp}"
    local port="${4:-}"
    local poll="${5:-60}"
    local timeout="${6:-2000}"
    local threshold="${7:-2}"
    if [ "$protocol" = "tcp" ] || [ "$protocol" = "udp" ]; then
        jq -n -c \
            --arg name "$name" \
            --arg address "$address" \
            --arg protocol "$protocol" \
            --argjson port "$port" \
            --argjson poll "$poll" \
            --argjson timeout "$timeout" \
            --argjson threshold "$threshold" \
            '{name: $name, targetKind: "service", address: $address, protocol: $protocol,
              port: $port, enabled: true, pollIntervalSeconds: $poll,
              timeoutMillis: $timeout, failureThreshold: $threshold,
              observationLocationIds: ["pulse:local"]}'
    else
        jq -n -c \
            --arg name "$name" \
            --arg address "$address" \
            --arg protocol "$protocol" \
            --argjson poll "$poll" \
            --argjson timeout "$timeout" \
            --argjson threshold "$threshold" \
            '{name: $name, targetKind: "machine", address: $address, protocol: $protocol,
              enabled: true, pollIntervalSeconds: $poll,
              timeoutMillis: $timeout, failureThreshold: $threshold,
              observationLocationIds: ["pulse:local"]}'
    fi
}

# POSTs one availability target. Usage: pulse_availability_create <base> <header> <payload>
pulse_availability_create() {
    curl -fsS -X POST -H @"$2" -H 'Content-Type: application/json' \
        -d "$3" "$1/api/availability-targets" >/dev/null
}

# PUTs one availability target. Usage: pulse_availability_update <base> <header> <id> <payload>
pulse_availability_update() {
    curl -fsS -X PUT -H @"$2" -H 'Content-Type: application/json' \
        -d "$4" "$1/api/availability-targets/$3" >/dev/null
}

# DELETEs one availability target. Usage: pulse_availability_delete <base> <header> <id>
pulse_availability_delete() {
    curl -fsS -X DELETE -H @"$2" "$1/api/availability-targets/$3" >/dev/null
}
