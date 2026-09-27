#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../common/functions.sh
source "$SCRIPT_DIR/../../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

# Check if username is provided
if [ -z "${1:-}" ]; then
    log_error "You must provide a username."
    log_error "Usage: $0 <username>"
    exit 1
fi

require_root

TARGET_USER=$1

# Ensure user exists
if ! id "$TARGET_USER" &>/dev/null; then
    log_error "User $TARGET_USER does not exist."
    exit 1
fi

# Check if dataset already exists to avoid errors
if zfs list "tank/data/$TARGET_USER" &>/dev/null; then
    log_info "Dataset tank/data/$TARGET_USER already exists. Skipping creation."
else
    log_step "Creating private ZFS dataset for '$TARGET_USER' (tank/data/$TARGET_USER)..."
    zfs create "tank/data/$TARGET_USER"
fi

# Ensure it's mounted
zfs mount "tank/data/$TARGET_USER" 2>/dev/null || true

log_step "Setting up $TARGET_USER ZFS dataset"
zfs set atime=off "tank/data/$TARGET_USER"

# Apply ownership and private permissions using ACLs
USER_UID=$(id -u "$TARGET_USER")
log_step "Applying private ACLs (Owner UID $USER_UID) to /tank/data/$TARGET_USER..."
setup_dataset_acls "tank/data/$TARGET_USER" "/tank/data/$TARGET_USER" "$USER_UID"

log_success "Private ZFS dataset for $TARGET_USER setup complete!"
