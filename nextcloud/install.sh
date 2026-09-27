#!/bin/bash

set -euo pipefail

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

log_step "Starting Nextcloud installation/configuration via LXC container..."

# shellcheck disable=SC2016  # evaluated later via 'bash -c'
NEXTCLOUD_INSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/nextcloudpi.sh)"'
container_id=$(ensure_container_installed "nextcloud" "$NEXTCLOUD_INSTALL_CMD") || exit 1

log_step "Waiting for container to finish first-boot setup..."
for _ in $(seq 1 30); do
    if pct exec "$container_id" -- systemctl is-system-running --wait 2>/dev/null | grep -qE 'running|degraded'; then
        break
    fi
    sleep 2
done

log_step "Disabling ncp-activation Apache site (first-run wizard)..."
pct exec "$container_id" -- a2dissite ncp-activation 2>/dev/null || true
pct exec "$container_id" -- systemctl reload apache2 2>/dev/null || true

ADMIN_USER="ncp"
ADMIN_PASS=$(tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | head -c 20 || true)
log_step "Setting admin user '$ADMIN_USER' password..."
pct exec "$container_id" -- bash -c \
    "OC_PASS='$ADMIN_PASS' sudo -E -u www-data php /var/www/nextcloud/occ user:resetpassword --password-from-env '$ADMIN_USER'" 2>/dev/null

log_step "Moving Nextcloud data directory to ZFS dataset on HDD..."
"$SCRIPT_DIR/setup-storage.sh"

echo ""
log_success "Installation complete. Nextcloud is running in container $container_id."
echo ""
log_success "──────────────────────────────────────────────────────"
log_success "  Admin credentials:"
log_success "    User:     $ADMIN_USER"
log_success "    Password: $ADMIN_PASS"
log_success "──────────────────────────────────────────────────────"
echo ""
log_info "Next steps:"
log_info "  1. Run ./caddy/generate-caddyfile.sh to configure reverse proxy"
log_info "  2. Run ./caddy/trust-nextcloud.sh to trust Caddy integration"
log_info "  3. Run ./nextcloud/sync-users.sh to create server users in Nextcloud"
