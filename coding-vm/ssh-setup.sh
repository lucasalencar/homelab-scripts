#!/bin/bash
# Configures passwordless SSH from this client machine (e.g. your Mac)
# to the coding VM, including an ssh config entry for VS Code Remote-SSH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_non_root

CONFIG_FILE="$HOME/.coding_vm_config"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    log_info "Loaded configuration from $CONFIG_FILE"
fi

KEY_PATH="${CODING_VM_SSH_KEY_PATH:-$HOME/.ssh/code}"
HOST_ALIAS="${CODING_VM_SSH_ALIAS:-code}"

target="${1:-}"
vm_user="${CODING_VM_USER:-}"
vm_ip="${CODING_VM_IP:-}"
if [[ -n "$target" ]]; then
    if [[ "$target" == *@* ]]; then
        vm_user="${target%@*}"
        vm_ip="${target#*@}"
    else
        vm_ip="$target"
    fi
fi
if [[ -z "$vm_user" ]]; then
    vm_user="$(id -un)"
fi

if [[ -z "$vm_ip" ]]; then
    log_error "Coding VM IP not specified."
    log_error "Either:"
    log_error "  1. Set CODING_VM_IP in $CONFIG_FILE, OR"
    log_error "  2. Provide target as argument: $0 [user@]<vm_ip>"
    exit 1
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [[ ! -f "$KEY_PATH" ]]; then
    log_step "Generating SSH key at $KEY_PATH..."
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N ""
else
    log_info "SSH key already exists at $KEY_PATH."
fi

log_step "Copying public key to $vm_user@$vm_ip..."
ssh-copy-id -i "$KEY_PATH" "$vm_user@$vm_ip"

ssh_config="$HOME/.ssh/config"
touch "$ssh_config"
if ! grep -q "^Host $HOST_ALIAS$" "$ssh_config"; then
    {
        printf '\nHost %s\n' "$HOST_ALIAS"
        printf '    HostName %s\n' "$vm_ip"
        printf '    User %s\n' "$vm_user"
        printf '    IdentityFile %s\n' "$KEY_PATH"
    } >> "$ssh_config"
    log_success "SSH config entry '$HOST_ALIAS' added to $ssh_config"
else
    log_info "SSH config entry '$HOST_ALIAS' already present."
fi

if [[ "${CODING_VM_SSH_SETUP_NO_CONNECT:-0}" != "1" ]]; then
    log_step "Verifying connection..."
    if ssh -o ConnectTimeout=10 -i "$KEY_PATH" "$vm_user@$vm_ip" true; then
        log_success "Connection to $HOST_ALIAS works."
    else
        log_warning "Could not connect. Check the VM is running and the IP is correct."
    fi
fi

echo ""
log_success "SSH setup complete. Connect with: ssh $HOST_ALIAS"
log_info "VS Code: Remote-SSH > Connect to Host > $HOST_ALIAS"
