#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_non_root

log_step "Configuring git repository with primary user's identity..."

PRIMARY_USER=$(get_primary_user) || exit 1
PRIMARY_HOME=$(get_primary_user_home) || exit 1

GITCONFIG="$PRIMARY_HOME/.gitconfig"
if [ ! -f "$GITCONFIG" ]; then
    log_error "$GITCONFIG not found for user $PRIMARY_USER."
    exit 1
fi

GIT_NAME=$(git config -f "$GITCONFIG" user.name || true)
GIT_EMAIL=$(git config -f "$GITCONFIG" user.email || true)
if [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
    log_error "user.name or user.email not found in $GITCONFIG."
    exit 1
fi

git config --local user.name "$GIT_NAME"
git config --local user.email "$GIT_EMAIL"
log_info "Set user.name = $GIT_NAME"
log_info "Set user.email = $GIT_EMAIL"

SSH_KEY=""
for key in "$PRIMARY_HOME/.ssh"/id_*; do
    [ -e "$key" ] || continue
    case "$key" in *.pub) continue ;; esac
    SSH_KEY="$key"
    break
done
if [ -n "$SSH_KEY" ]; then
    git config --local core.sshCommand "ssh -i $SSH_KEY"
    log_info "Set core.sshCommand = ssh -i $SSH_KEY"
else
    log_warning "No private SSH key found in $PRIMARY_HOME/.ssh/. Skipping core.sshCommand."
fi

log_success "Git setup complete for this repository."
