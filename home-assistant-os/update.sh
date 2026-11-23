#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

# Env overrides:
#   HA_URL          Home Assistant base URL (default http://<vm-ip>:8123).
#   HA_TOKEN        Long-lived access token (Profile -> Security -> Long-lived access tokens).
#   HA_TOKEN_FILE   File containing the token (checked before HA_TOKEN).
run_ha_cli() {
    local vmid="${1:-}"
    shift
    if [ -z "$vmid" ] || [ $# -eq 0 ]; then
        log_error "run_ha_cli: missing vmid or command"
        return 1
    fi
    if qm guest exec "$vmid" -- ha "$@" >/dev/null 2>&1; then
        return 0
    fi
    log_warning "ha $* reported no update or failed (see HA logs for details)."
    return 0
}

log_step "Checking for Home Assistant OS VM updates..."

vm_id=$(get_vm_id_by_name "haos")

if [ -z "$vm_id" ]; then
    log_error "Could not find VM 'haos'."
    exit 1
fi

log_info "Identified VM ID: $vm_id"

vm_status=$(qm status "$vm_id" | awk '{print $2}' || true)
if [ "$vm_status" != "running" ]; then
    log_warning "VM $vm_id is not running. Start it to apply updates."
    exit 0
fi

log_step "Updating Home Assistant core, supervisor and OS..."
run_ha_cli "$vm_id" core update
run_ha_cli "$vm_id" supervisor update
run_ha_cli "$vm_id" os update

log_step "Checking for add-on updates..."
addons_raw=$(qm guest exec "$vm_id" -- ha addons list --raw-json 2>/dev/null || true)
addons_json=$(printf '%s' "$addons_raw" | jq -r '.["out-data"] // .["out"] // empty' 2>/dev/null || true)
mapfile -t addon_slugs < <(printf '%s' "$addons_json" | jq -r '.data.addons[]? | select(.update_available == true) | .slug' 2>/dev/null || true)
if [ "${#addon_slugs[@]}" -eq 0 ] || [ -z "${addon_slugs[0]:-}" ]; then
    log_info "No add-on updates available."
else
    for slug in "${addon_slugs[@]}"; do
        [ -n "$slug" ] || continue
        log_info "Updating add-on: $slug"
        run_ha_cli "$vm_id" addons update "$slug"
    done
fi

log_step "Checking for Marketplace updates via Home Assistant API..."
# Since HA 2026.11 HACS is built in as the Marketplace integration.
# Update entity IDs carry over, so update.install covers both.
ha_token=""
if [ -n "${HA_TOKEN_FILE:-}" ]; then
    ha_token=$(cat "$HA_TOKEN_FILE" 2>/dev/null || true)
elif [ -n "${HA_TOKEN:-}" ]; then
    ha_token="$HA_TOKEN"
fi

if [ -z "$ha_token" ]; then
    log_warning "Skipping HACS updates: set HA_TOKEN or HA_TOKEN_FILE with a long-lived access token."
    log_info "Create one in Home Assistant: Profile -> Security -> Long-lived access tokens."
    log_success "Home Assistant OS update process complete!"
    exit 0
fi

ha_url="${HA_URL:-}"
if [ -z "$ha_url" ]; then
    vm_ip=$(get_vm_ip "$vm_id" || true)
    if [ -z "$vm_ip" ]; then
        log_warning "Skipping HACS updates: could not determine HA address (set HA_URL)."
        log_success "Home Assistant OS update process complete!"
        exit 0
    fi
    ha_url="http://${vm_ip}:8123"
fi
ha_url="${ha_url%/}"

header_file=$(mktemp)
chmod 600 "$header_file"
printf 'Authorization: Bearer %s\n' "$ha_token" > "$header_file"
trap 'rm -f "$header_file"' EXIT

states=$(curl -fsS --max-time 30 -H @"$header_file" "$ha_url/api/states" 2>/dev/null || true)
mapfile -t pending_updates < <(printf '%s' "$states" | jq -r '.[] | select(.entity_id | startswith("update.")) | select(.state == "on") | .entity_id' 2>/dev/null || true)
if [ "${#pending_updates[@]}" -eq 0 ] || [ -z "${pending_updates[0]:-}" ]; then
    log_info "No pending update entities (HACS/Marketplace already up to date)."
else
    for entity in "${pending_updates[@]}"; do
        [ -n "$entity" ] || continue
        log_info "Installing update: $entity"
        if curl -fsS --max-time 120 -X POST -H @"$header_file" -H 'Content-Type: application/json' \
            -d "{\"entity_id\": \"$entity\"}" "$ha_url/api/services/update/install" >/dev/null 2>&1; then
            log_success "Update installed: $entity"
        else
            log_warning "Failed to install $entity (continuing)."
            log_info "If installs keep failing, accept the first-run warning in HA: Settings -> Marketplace."
        fi
    done
    log_info "Marketplace integration updates may need a restart (see Settings -> System -> Repairs)."
fi

rm -f "$header_file"
trap - EXIT

log_success "Home Assistant OS update process complete!"
