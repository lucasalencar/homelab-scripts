#!/bin/bash
# Pulls the live Caddyfile from the Caddy LXC into a local file.
# Use when the local copy is missing (e.g. gitignored Caddyfile.local on a
# fresh branch): pull, edit, then deploy with push-caddyfile.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

CADDY_CONTAINER_NAME="caddy"

usage() {
    echo "Usage: bash caddy/pull-caddyfile.sh [--file <path>]" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --file <path>  Local destination (default: caddy/Caddyfile.local)" >&2
}

FILE="$SCRIPT_DIR/Caddyfile.local"
while [ $# -gt 0 ]; do
    case "$1" in
        --file)
            if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                log_error "Option --file requires a value."
                usage
                exit 1
            fi
            FILE="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

CADDY_ID=$(get_container_id_by_name "$CADDY_CONTAINER_NAME" || true)
if [ -z "$CADDY_ID" ]; then
    log_error "Caddy container not found. Run caddy/install.sh first."
    exit 1
fi

log_step "Pulling Caddyfile from Caddy container ($CADDY_ID) to $FILE..."
pct pull "$CADDY_ID" /etc/caddy/Caddyfile "$FILE"

log_success "Pulled to $FILE."
