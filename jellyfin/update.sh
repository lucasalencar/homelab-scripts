#!/bin/bash

set -euo pipefail

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

log_step "Checking for Jellyfin container updates..."

# 1. Identify the container ID
container_id=$(get_container_id_by_name "jellyfin")

if [ -z "$container_id" ]; then
    log_error "Could not find container 'jellyfin'."
    exit 1
fi

log_info "Identified Container ID: $container_id"

# 2. Install Jellyfin first to resolve dependency swaps (e.g. ffmpeg7 -> ffmpeg8)
log_step "Installing Jellyfin updates inside container $container_id..."
pct exec "$container_id" -- apt update
pct exec "$container_id" -- apt install jellyfin jellyfin-server jellyfin-web -y

# 3. Upgrade remaining packages
log_step "Running apt upgrade inside container $container_id..."
pct exec "$container_id" -- apt upgrade -y

log_success "Jellyfin update and synchronization process complete!"
