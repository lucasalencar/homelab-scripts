#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

echo "Checking for Caddy container updates..."

container_id=$(get_container_id_by_name "caddy")

if [ -z "$container_id" ]; then
    echo "Error: Could not find container 'caddy'."
    exit 1
fi

echo "Identified Container ID: $container_id"

echo "Running apt update and upgrade inside container $container_id..."
pct exec "$container_id" -- apt update
pct exec "$container_id" -- apt upgrade -y

echo "Upgrading Caddy binary..."
pct exec "$container_id" -- caddy upgrade

echo "Caddy update process complete!"
