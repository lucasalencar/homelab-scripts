#!/bin/bash
# Syncs Pulse ICMP availability checks from the Proxmox guest inventory.
# Creates one ping target per running CT/VM, updates stale IPs, optionally
# prunes orphaned prefixed targets. Idempotent.
# Usage: sync-ping-availability.sh [--dry-run] [--prune] [--prefix PREFIX]
#        [--only ct|vm] [--pulse-name NAME] [--poll-interval SEC]
#        [--timeout-ms MS] [--failure-threshold N]
# Env: PULSE_API_TOKEN or PULSE_API_TOKEN_FILE (Pulse API token with
#      admin + settings:read/write). See pulse/sync-ping-availability.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh" || { echo "Error: failed to load pulse/lib.sh" >&2; exit 1; }

DRY_RUN=0
PRUNE=0
PREFIX="ping-"
ONLY="all"
PULSE_NAME="${PULSE_CONTAINER_NAME:-pulse}"
POLL_INTERVAL=60
TIMEOUT_MS=2000
FAILURE_THRESHOLD=2

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Syncs Pulse availability checks (ICMP ping) from running Proxmox guests.

Options:
  --dry-run              Plan only, no POST/PUT/DELETE.
  --prune                Delete prefixed targets with no matching guest.
  --prefix PREFIX        Target name prefix (default: ping-).
  --only ct|vm           Sync only containers or only VMs (default: both).
  --pulse-name NAME      Pulse container name (default: pulse).
  --poll-interval SEC    Poll interval seconds, min 10 (default: 60).
  --timeout-ms MS        Probe timeout ms, min 250 (default: 2000).
  --failure-threshold N  Consecutive failures before alert (default: 2).
  -h, --help             Show this help.

Env:
  PULSE_API_TOKEN        Pulse API token (admin, settings:read/write).
  PULSE_API_TOKEN_FILE   File containing the token (alternative).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --prune) PRUNE=1; shift ;;
        --prefix) PREFIX="${2:-}"; shift 2 ;;
        --only) ONLY="${2:-}"; shift 2 ;;
        --pulse-name) PULSE_NAME="${2:-}"; shift 2 ;;
        --poll-interval) POLL_INTERVAL="${2:-}"; shift 2 ;;
        --timeout-ms) TIMEOUT_MS="${2:-}"; shift 2 ;;
        --failure-threshold) FAILURE_THRESHOLD="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown argument: $1 (see --help)"; exit 1 ;;
    esac
done

case "$ONLY" in
    all|ct|vm) ;;
    *) log_error "--only must be ct or vm"; exit 1 ;;
esac

TOKEN=""
if [ -n "${PULSE_API_TOKEN_FILE:-}" ]; then
    TOKEN=$(cat "$PULSE_API_TOKEN_FILE" 2>/dev/null || true)
elif [ -n "${PULSE_API_TOKEN:-}" ]; then
    TOKEN="$PULSE_API_TOKEN"
fi
if [ -z "$TOKEN" ]; then
    log_error "Missing Pulse API token: set PULSE_API_TOKEN or PULSE_API_TOKEN_FILE."
    log_error "Create it in Pulse Settings -> API Access (admin, settings:read/write)."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required but not installed."
    exit 1
fi

require_root

BASE=$(pulse_api_base "$PULSE_NAME") || exit 1
HEADER_FILE=$(pulse_api_header "$TOKEN") || exit 1
trap 'rm -f "$HEADER_FILE"' EXIT

existing_list=$(pulse_availability_list "$BASE" "$HEADER_FILE")

declare -A WANT_IP=()
if [ "$ONLY" = "all" ] || [ "$ONLY" = "ct" ]; then
    while read -r ctid cname; do
        [ -n "${ctid:-}" ] || continue
        if [ "${cname,,}" = "${PULSE_NAME,,}" ]; then
            continue
        fi
        ip=$(get_container_ip "$ctid" 2>/dev/null || true)
        if [ -z "$ip" ]; then
            log_warning "Skipping container $cname ($ctid): no IP found."
            continue
        fi
        WANT_IP["${PREFIX}${cname}"]="$ip"
    done < <(pct list 2>/dev/null | awk 'NR > 1 && tolower($2) == "running" { print $1, $NF }' || true)
fi
if [ "$ONLY" = "all" ] || [ "$ONLY" = "vm" ]; then
    while read -r vmid vname; do
        [ -n "${vmid:-}" ] || continue
        ip=$(get_vm_ip "$vmid" 2>/dev/null || true)
        if [ -z "$ip" ]; then
            log_warning "Skipping VM $vname ($vmid): no IP found."
            continue
        fi
        WANT_IP["${PREFIX}${vname}"]="$ip"
    done < <(qm list 2>/dev/null | awk 'NR > 1 && $3 == "running" { print $1, $2 }' || true)
fi

declare -A HAVE_ID=()
declare -A HAVE_ADDR=()
while IFS=$'\t' read -r tid tname taddr; do
    [ -n "${tname:-}" ] || continue
    HAVE_ID["$tname"]="$tid"
    HAVE_ADDR["$tname"]="$taddr"
done < <(printf '%s' "$existing_list" | jq -r '.[] | [.id, .name, .address] | @tsv' 2>/dev/null || true)

created=0
updated=0
skipped=0
deleted=0

for name in "${!WANT_IP[@]}"; do
    ip="${WANT_IP[$name]}"
    payload=$(pulse_availability_payload "$name" "$ip" "icmp" "" "$POLL_INTERVAL" "$TIMEOUT_MS" "$FAILURE_THRESHOLD")
    if [ -z "${HAVE_ID[$name]:-}" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log_info "DRY-RUN CREATE $name -> $ip"
        else
            log_info "CREATE $name -> $ip"
            pulse_availability_create "$BASE" "$HEADER_FILE" "$payload"
        fi
        created=$((created + 1))
    elif [ "${HAVE_ADDR[$name]:-}" != "$ip" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log_info "DRY-RUN UPDATE $name ${HAVE_ADDR[$name]} -> $ip"
        else
            log_info "UPDATE $name ${HAVE_ADDR[$name]} -> $ip"
            pulse_availability_update "$BASE" "$HEADER_FILE" "${HAVE_ID[$name]}" "$payload"
        fi
        updated=$((updated + 1))
    else
        skipped=$((skipped + 1))
    fi
done

if [ "$PRUNE" = "1" ]; then
    while IFS=$'\t' read -r tid tname _taddr; do
        [ -n "${tname:-}" ] || continue
        case "$tname" in
            "$PREFIX"*)
                if [ -z "${WANT_IP[$tname]:-}" ]; then
                    if [ "$DRY_RUN" = "1" ]; then
                        log_info "DRY-RUN DELETE $tname ($tid)"
                    else
                        log_info "DELETE $tname ($tid)"
                        pulse_availability_delete "$BASE" "$HEADER_FILE" "$tid"
                    fi
                    deleted=$((deleted + 1))
                fi
                ;;
        esac
    done < <(printf '%s' "$existing_list" | jq -r '.[] | [.id, .name, .address] | @tsv' 2>/dev/null || true)
fi

log_success "Done: $created created, $updated updated, $skipped up-to-date, $deleted deleted."
