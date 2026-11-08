#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh" || { echo "Error: failed to load nvidia/lib.sh" >&2; exit 1; }

require_root

log_step "Checking for NVIDIA driver updates..."

nvidia_require_proxmox || exit 1

if ! nvidia_detect_gpu; then
    log_error "No NVIDIA GPU found via lspci."
    exit 1
fi

log_step "Refreshing APT and upgrading the driver stack..."
nvidia_ensure_non_free || exit 1
nvidia_ensure_cuda_repo || exit 1
nvidia_purge_legacy_stack
apt-get update
# shellcheck disable=SC2046  # word-splitting the package list is intended
apt-get install -y $(nvidia_driver_packages)

log_step "Rebuilding initramfs..."
update-initramfs -u

if nvidia_smi_ok; then
    log_success "Driver healthy after update."
else
    log_warning "nvidia-smi does not answer after update: reboot, then run bash nvidia/configure.sh."
fi
