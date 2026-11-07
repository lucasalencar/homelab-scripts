#!/bin/bash
# Syncs Pulse TCP availability checks for the Starr stack services.
# One check per Servarr app listening on the LAN; FlareSolverr (127.0.0.1:8191)
# is deliberately excluded — Pulse probes over the LAN and would false-alert.
# Idempotent. Depends on the pulse container (explicit cross-package call).
# Usage: sync-service-availability.sh [--dry-run] [--prune] [--prefix PREFIX]
#        [--starr-name NAME] [--pulse-name NAME] [--poll-interval SEC]
#        [--timeout-ms MS] [--failure-threshold N]
# Env: PULSE_API_TOKEN or PULSE_API_TOKEN_FILE (Pulse API token with
#      admin + settings:read/write).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }
# shellcheck source=../pulse/lib.sh
source "$SCRIPT_DIR/../pulse/lib.sh" || { echo "Error: failed to load pulse/lib.sh" >&2; exit 1; }

# Hard-coded service map: the Starr CT runs exactly these LAN-facing apps.
# FlareSolverr (8191) is loopback-only by design — never add it here.
SERVICES=(
    "prowlarr:9696"
    "sonarr:8989"
    "radarr:7878"
    "bazarr:6767"
    "seerr:5055"
)

DRY_RUN=0
PRUNE=0
PREFIX="svc-"
STARR_NAME="starr"
PULSE_NAME="${PULSE_CONTAINER_NAME:-pulse}"
POLL_INTERVAL=60
TIMEOUT_MS=2000
FAILURE_THRESHOLD=2

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Syncs Pulse TCP availability checks for the Starr stack services.

Options:
  --dry-run              Plan only, no POST/PUT/DELETE.
  --prune                Delete prefixed targets with no matching service.
  --prefix PREFIX        Target name prefix (default: svc-).
  --starr-name NAME      Starr container name (default: starr).
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
        --starr-name) STARR_NAME="${2:-}"; shift 2 ;;
        --pulse-name) PULSE_NAME="${2:-}"; shift 2 ;;
        --poll-interval) POLL_INTERVAL="${2:-}"; shift 2 ;;
        --timeout-ms) TIMEOUT_MS="${2:-}"; shift 2 ;;
        --failure-threshold) FAILURE_THRESHOLD="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown argument: $1 (see --help)"; exit 1 ;;
    esac
done

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

starr_id=$(get_container_id_by_name "$STARR_NAME" || true)
if [ -z "$starr_id" ]; then
    log_error "Could not find container '$STARR_NAME'."
    exit 1
fi
starr_ip=$(get_container_ip "$starr_id" 2>/dev/null || true)
if [ -z "$starr_ip" ]; then
    log_error "Could not determine IP of container '$STARR_NAME' ($starr_id)."
    exit 1
fi

BASE=$(pulse_api_base "$PULSE_NAME") || exit 1
HEADER_FILE=$(pulse_api_header "$TOKEN") || exit 1
trap 'rm -f "$HEADER_FILE"' EXIT

existing_list=$(pulse_availability_list "$BASE" "$HEADER_FILE")

# Pre-flight: warn when a service is not listening locally, still sync —
# the Pulse check is the monitor, it will alert until the service recovers.
listeners=$(pct exec "$starr_id" -- ss -tln 2>/dev/null || true)

declare -A HAVE_ID=()
declare -A HAVE_ADDR=()
declare -A HAVE_PORT=()
while IFS=$'\t' read -r tid tname taddr tport; do
    [ -n "${tname:-}" ] || continue
    HAVE_ID["$tname"]="$tid"
    HAVE_ADDR["$tname"]="$taddr"
    HAVE_PORT["$tname"]="$tport"
done < <(printf '%s' "$existing_list" | jq -r '.[] | [.id, .name, .address, (.port // empty)] | @tsv' 2>/dev/null || true)

created=0
updated=0
skipped=0
deleted=0

for svc in "${SERVICES[@]}"; do
    app="${svc%%:*}"
    port="${svc##*:}"
    name="${PREFIX}${app}"
    if ! printf '%s' "$listeners" | grep -qE ":${port}([[:space:]]|$)"; then
        log_warning "Port $port ($app) is not listening in container $STARR_NAME ($starr_id) — syncing anyway, Pulse will alert."
    fi
    payload=$(pulse_availability_payload "$name" "$starr_ip" "tcp" "$port" "$POLL_INTERVAL" "$TIMEOUT_MS" "$FAILURE_THRESHOLD")
    if [ -z "${HAVE_ID[$name]:-}" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log_info "DRY-RUN CREATE $name -> ${starr_ip}:${port}"
        else
            log_info "CREATE $name -> ${starr_ip}:${port}"
            pulse_availability_create "$BASE" "$HEADER_FILE" "$payload"
        fi
        created=$((created + 1))
    elif [ "${HAVE_ADDR[$name]:-}" != "$starr_ip" ] || [ "${HAVE_PORT[$name]:-}" != "$port" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log_info "DRY-RUN UPDATE $name ${HAVE_ADDR[$name]}:${HAVE_PORT[$name]} -> ${starr_ip}:${port}"
        else
            log_info "UPDATE $name ${HAVE_ADDR[$name]}:${HAVE_PORT[$name]} -> ${starr_ip}:${port}"
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
                wanted=0
                for svc in "${SERVICES[@]}"; do
                    if [ "$tname" = "${PREFIX}${svc%%:*}" ]; then
                        wanted=1
                        break
                    fi
                done
                if [ "$wanted" = "0" ]; then
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
