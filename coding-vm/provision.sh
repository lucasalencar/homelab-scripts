#!/bin/bash
#
# Guest-side provisioning for the coding VM (Ubuntu Desktop).
# Runs as root inside the VM. Handles only system-level setup
# (packages, groups, services, hardware checks). Everything user-level
# (languages, dot configs, editors, Android SDK) is done manually
# after first login.

set -euo pipefail

# Self-contained log helpers: provision.sh is scp'd to the guest, so it must
# not source common/functions.sh. Keep these in sync intentionally.
log_step() { echo ">>> $*"; }
log_info() { echo "--- $*"; }
log_success() { echo "OK: $*"; }
log_warning() { echo "WARN: $*" >&2; }
log_error() { echo "ERROR: $*" >&2; }

TEST_MODE="${CODING_VM_TEST_MODE:-0}"
KVM_DEVICE="${CODING_VM_KVM_DEVICE:-/dev/kvm}"
GUEST_USER="${CODING_VM_USER:-${SUDO_USER:-}}"
CHECK_ONLY=0

if [ "${1:-}" = "--check-only" ]; then
    CHECK_ONLY=1
fi

if [ "$TEST_MODE" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    log_error "This script must run as root inside the VM."
    exit 1
fi

check_kvm() {
    log_step "Checking KVM acceleration..."
    if ! command -v kvm-ok >/dev/null 2>&1; then
        log_error "kvm-ok not found. Install the 'cpu-checker' package."
        exit 1
    fi
    kvm-ok || exit 1
    if [ "$TEST_MODE" = "1" ]; then
        [ -e "$KVM_DEVICE" ] || { log_error "KVM device missing at $KVM_DEVICE."; exit 1; }
    else
        [ -c "$KVM_DEVICE" ] || { log_error "KVM device missing at $KVM_DEVICE. Nested virtualization may be off."; exit 1; }
    fi
    log_success "KVM acceleration available ($KVM_DEVICE)."
}

check_ssh() {
    log_step "Checking ssh service..."
    systemctl is-active --quiet ssh || { log_error "ssh service is not active."; exit 1; }
    log_success "ssh service is active."
}

if [ "$CHECK_ONLY" = "1" ]; then
    check_kvm
    check_ssh
    log_success "All guest checks passed."
    exit 0
fi

log_step "Installing system packages..."
apt-get update
apt-get install -y \
    qemu-guest-agent openssh-server git curl \
    qemu-kvm cpu-checker \
    ubuntu-desktop-minimal gnome-remote-desktop \
    libnss3 libnspr4 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 \
    libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 \
    libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2t64

log_step "Enabling base services..."
systemctl enable --now qemu-guest-agent
systemctl enable --now ssh

if [ -n "$GUEST_USER" ] && id "$GUEST_USER" >/dev/null 2>&1; then
    log_step "Granting $GUEST_USER access to KVM..."
    usermod -aG kvm "$GUEST_USER"
    loginctl enable-linger "$GUEST_USER" || log_warning "Could not enable linger for $GUEST_USER."
    su -s /bin/bash "$GUEST_USER" -c "grdctl rdp enable" 2>/dev/null \
        || log_warning "Could not pre-enable GNOME RDP. Enable it on first login: Settings > System > Remote Desktop."
else
    log_warning "No guest user resolved; skipping kvm group and RDP setup."
fi

check_kvm
check_ssh

log_success "Guest provisioning complete."
