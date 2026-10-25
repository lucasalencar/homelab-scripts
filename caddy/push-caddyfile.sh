#!/bin/bash
# Pushes a local Caddyfile into the Caddy LXC and reloads Caddy.
# The file is written by generate-caddyfile.sh — review/edit it first,
# then run this script to deploy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

CADDY_CONTAINER_NAME="caddy"

usage() {
    echo "Usage: bash caddy/push-caddyfile.sh [--file <path>]" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --file <path>  Caddyfile to push (default: caddy/Caddyfile.local)" >&2
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

if [ ! -f "$FILE" ]; then
    log_error "File not found: $FILE. Run caddy/generate-caddyfile.sh first."
    exit 1
fi

log_step "Pushing $FILE to Caddy container ($CADDY_ID)..."
pct push "$CADDY_ID" "$FILE" /etc/caddy/Caddyfile

log_step "Reloading Caddy..."
pct exec "$CADDY_ID" -- systemctl reload caddy

log_success "Caddy reloaded."
