#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

log_step "Checking for Nextcloud container updates..."

container_id=$(get_container_id_by_name "nextcloud")

if [ -z "$container_id" ]; then
    log_error "Could not find container 'nextcloud'."
    exit 1
fi

log_info "Identified Container ID: $container_id"

log_step "Running apt update and upgrade inside container $container_id..."
pct exec "$container_id" -- apt update
pct exec "$container_id" -- apt upgrade -y

log_step "Running NextcloudPi update..."
pct exec "$container_id" -- bash -c "ncp-update 2>/dev/null || sudo -u www-data php /var/www/nextcloud/occ upgrade 2>/dev/null || echo 'Automatic update not available; use ncp-config for manual update.'"

log_success "Nextcloud update process complete!"
