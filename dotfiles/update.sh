#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
    log_warning "Dotfiles update is per-user; run ./dotfiles/update.sh as your user. Skipping."
    exit 0
fi

update_script="$HOME/.dotfiles/update"
if [ ! -x "$update_script" ]; then
    log_warning "No update script at $update_script. Skipping."
    exit 0
fi

export DOTFILES_ROOT="${DOTFILES_ROOT:-$HOME/.dotfiles}"

log_step "Updating dotfiles..."
"$update_script" "$@"
log_success "Dotfiles update complete!"
