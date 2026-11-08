#!/bin/bash
# Shared NVIDIA host-driver helpers.
# Sourced by install.sh / configure.sh / update.sh AFTER common/functions.sh.
# Not executed directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

# Test hooks (point at tmp fixtures under bats, real paths on the host).
# Usage: src=$(nvidia_debian_sources)
nvidia_pve_dir() { echo "${NVIDIA_PVE_DIR:-/etc/pve}"; }
nvidia_debian_sources() { echo "${NVIDIA_DEBIAN_SOURCES:-/etc/apt/sources.list.d/debian.sources}"; }
nvidia_modprobe_conf() { echo "${NVIDIA_MODPROBE_CONF:-/etc/modprobe.d/blacklist-nouveau-nvidia.conf}"; }
nvidia_dev_dir() { echo "${NVIDIA_DEV_DIR:-/dev}"; }
nvidia_uname_r() { echo "${NVIDIA_UNAME_R:-$(uname -r)}"; }
nvidia_cuda_dist() { echo "${NVIDIA_CUDA_DIST:-debian13}"; }
nvidia_cuda_sources() { echo "${NVIDIA_CUDA_SOURCES:-/etc/apt/sources.list.d/cuda-$(nvidia_cuda_dist)-x86_64.list}"; }
nvidia_cuda_keyring() { echo "${NVIDIA_CUDA_KEYRING:-/usr/share/keyrings/cuda-archive-keyring.gpg}"; }
nvidia_cuda_keyring_url() { echo "https://developer.download.nvidia.com/compute/cuda/repos/$(nvidia_cuda_dist)/x86_64/cuda-keyring_1.1-1_all.deb"; }
nvidia_cuda_repo_line() { echo "deb [signed-by=$(nvidia_cuda_keyring)] https://developer.download.nvidia.com/compute/cuda/repos/$(nvidia_cuda_dist)/x86_64/ /"; }

# Headless compute stack + headers installed by install.sh / update.sh.
# Usage: apt-get install -y $(nvidia_driver_packages)
nvidia_driver_packages() {
    echo "proxmox-headers-$(nvidia_uname_r) pve-headers nvidia-driver-cuda nvidia-kernel-open-dkms firmware-nvidia-graphics nvtop"
}

# Enables the NVIDIA CUDA network repository (idempotent).
# Usage: nvidia_ensure_cuda_repo || exit 1
nvidia_ensure_cuda_repo() {
    local src keyring line tmp
    src=$(nvidia_cuda_sources)
    keyring=$(nvidia_cuda_keyring)
    line=$(nvidia_cuda_repo_line)
    if [ -f "$src" ] && grep -qF "$line" "$src" 2>/dev/null && [ -f "$keyring" ]; then
        log_info "CUDA repository already configured in $src"
        return 0
    fi
    if [ ! -f "$keyring" ]; then
        log_step "Installing CUDA keyring..."
        tmp="$(mktemp)"
        if ! curl -fsSL -o "$tmp" "$(nvidia_cuda_keyring_url)"; then
            log_error "Failed to download CUDA keyring."
            rm -f "$tmp"
            return 1
        fi
        if ! dpkg -i "$tmp"; then
            log_error "Failed to install CUDA keyring."
            rm -f "$tmp"
            return 1
        fi
        rm -f "$tmp"
    fi
    log_step "Enabling CUDA repository in $src..."
    mkdir -p "$(dirname "$src")"
    printf '%s\n' "$line" > "$src"
}

# Removes the legacy closed Debian stack (nvidia-driver / nvidia-kernel-dkms).
# Safe to re-run: exact names never match the open compute stack.
# Usage: nvidia_purge_legacy_stack
nvidia_purge_legacy_stack() {
    log_step "Removing legacy closed NVIDIA stack (if present)..."
    apt-get remove --purge -y nvidia-driver nvidia-kernel-dkms || true
    apt-get autoremove --purge -y || true
}

# Fails when not on a Proxmox host.
# Usage: nvidia_require_proxmox || exit 1
nvidia_require_proxmox() {
    if [ ! -d "$(nvidia_pve_dir)" ]; then
        log_error "No Proxmox host detected (missing $(nvidia_pve_dir)). Run on the Proxmox host, not in a container."
        return 1
    fi
}

# True when lspci sees an NVIDIA VGA device (10de vendor id).
# Usage: nvidia_detect_gpu || exit 1
nvidia_detect_gpu() {
    lspci -nn 2>/dev/null | grep -qi "10de"
}

# True when the kernel bound the NVIDIA device to the proprietary driver.
# Usage: nvidia_driver_in_use || exit 1
nvidia_driver_in_use() {
    lspci -nnk 2>/dev/null | grep -q "Kernel driver in use: nvidia"
}

# True when the NVIDIA user-space driver answers.
# Usage: nvidia_smi_ok || exit 1
nvidia_smi_ok() {
    nvidia-smi -L >/dev/null 2>&1
}

# Lists /dev/nvidia* nodes, fails when none exist.
# Usage: nodes=$(nvidia_dev_nodes) || exit 1
nvidia_dev_nodes() {
    local nodes
    nodes=$(ls "$(nvidia_dev_dir)"/nvidia* 2>/dev/null || true)
    if [ -z "$nodes" ]; then
        return 1
    fi
    echo "$nodes"
}

# Adds the non-free component to debian.sources (idempotent).
# The token check skips non-free-firmware (substring, not the component).
# Usage: nvidia_ensure_non_free || exit 1
nvidia_ensure_non_free() {
    local src
    src=$(nvidia_debian_sources)
    if [ ! -f "$src" ]; then
        log_error "APT sources file not found: $src (set NVIDIA_DEBIAN_SOURCES to override)"
        return 1
    fi
    if grep -Eq '(^|[[:space:]])non-free($|[[:space:]])' "$src"; then
        log_info "non-free already enabled in $src"
        return 0
    fi
    log_step "Enabling non-free in $src..."
    sed -i -E '/^[[:space:]]*Components:/ s/[[:space:]]*$/ non-free/' "$src"
}
