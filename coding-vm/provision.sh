#!/bin/bash
#
# Guest-side provisioning for the coding VM (Ubuntu, Desktop optional).
# Runs as root inside the VM. Handles only system-level setup
# (packages, groups, services, hardware checks). Everything user-level
# (languages, dot configs, editors, Android SDK) is done manually
# after first login.

set -euo pipefail

# Self-contained log helpers: this file is scp'd to the guest, so it cannot
# source the shared helpers library. Keep these in sync intentionally.
log_step() { echo ">>> $*"; }
log_info() { echo "--- $*"; }
log_success() { echo "OK: $*"; }
log_warning() { echo "WARN: $*" >&2; }
log_error() { echo "ERROR: $*" >&2; }

TEST_MODE="${CODING_VM_TEST_MODE:-0}"
KVM_DEVICE="${CODING_VM_KVM_DEVICE:-/dev/kvm}"
GUEST_USER="${CODING_VM_USER:-${SUDO_USER:-}}"
RDP_USER="${CODING_VM_RDP_USER:-}"
RDP_PASSWORD="${CODING_VM_RDP_PASSWORD:-}"
RDP_CERT_DIR="${CODING_VM_RDP_CERT_DIR:-/var/lib/gnome-remote-desktop}"
RDP_ENV_FILE="${CODING_VM_RDP_ENV_FILE:-/tmp/coding-vm-rdp.env}"
SKIP_APT="${CODING_VM_SKIP_APT:-0}"
GUI="${CODING_VM_GUI:-0}"

# Password arrives via scp'd env file (install.sh never puts it in ssh argv).
if [ -z "$RDP_PASSWORD" ] && [ -f "$RDP_ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$RDP_ENV_FILE"
    set +a
    RDP_USER="${CODING_VM_RDP_USER:-$RDP_USER}"
    RDP_PASSWORD="${CODING_VM_RDP_PASSWORD:-}"
fi
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

check_rdp() {
    if [ "$GUI" = "0" ]; then
        return 0
    fi
    if [ -z "$RDP_USER" ]; then
        return 0
    fi
    log_step "Checking system RDP..."
    systemctl is-active --quiet gnome-remote-desktop || { log_error "gnome-remote-desktop service is not active."; exit 1; }
    [ -f "$RDP_CERT_DIR/rdp-tls.crt" ] || { log_error "RDP TLS certificate missing."; exit 1; }
    [ -f "$RDP_CERT_DIR/rdp-tls.key" ] || { log_error "RDP TLS key missing."; exit 1; }
    rdp_open=0
    for _ in 1 2 3 4 5; do
        if ss -ltn 2>/dev/null | grep -q ':3389'; then
            rdp_open=1
            break
        fi
        sleep 2
    done
    if [ "$rdp_open" != "1" ]; then
        log_error "Nothing listening on 3389 (is the display manager running?)."
        exit 1
    fi
    log_success "system RDP is active."
}

setup_display_manager() {
    log_step "Enabling desktop services..."
    systemctl set-default graphical.target || true
    # gdm.service is static (no [Install]): 'enable' is a no-op, and a
    # cloud-image + apt desktop install never creates
    # display-manager.service, which graphical.target pulls via Wants=.
    dm_link="${CODING_VM_DM_LINK:-/etc/systemd/system/display-manager.service}"
    if [ ! -e "$dm_link" ]; then
        log_step "Registering gdm as display manager..."
        gdm_fragment="${CODING_VM_GDM_FRAGMENT:-}"
        if [ -z "$gdm_fragment" ]; then
            for candidate in /usr/lib/systemd/system/gdm.service /lib/systemd/system/gdm.service; do
                if [ -f "$candidate" ]; then
                    gdm_fragment="$candidate"
                    break
                fi
            done
        fi
        if [ -z "$gdm_fragment" ]; then
            log_warning "gdm unit not found; skipping display-manager registration."
        else
            ln -sf "$gdm_fragment" "$dm_link"
            systemctl daemon-reload
        fi
    fi
    systemctl start display-manager.service 2>/dev/null || systemctl start gdm.service
}

setup_rdp_system() {
    if [ "$GUI" = "0" ]; then
        log_info "Headless mode (CODING_VM_GUI=0): skipping system RDP (requires desktop)."
        return 0
    fi
    if [ -z "$RDP_USER" ] || [ -z "$RDP_PASSWORD" ]; then
        log_warning "RDP credentials unset; skipping system RDP (set CODING_VM_RDP_USER/CODING_VM_RDP_PASSWORD to enable)."
        return 0
    fi
    log_step "Configuring system GNOME RDP..."
    mkdir -p "$RDP_CERT_DIR"
    cert="$RDP_CERT_DIR/rdp-tls.crt"
    key="$RDP_CERT_DIR/rdp-tls.key"
    if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
        openssl req -x509 -newkey rsa:2048 -keyout "$key" -out "$cert" -days 365 -nodes -subj "/CN=code"
    fi
    if id gnome-remote-desktop >/dev/null 2>&1; then
        chown gnome-remote-desktop:gnome-remote-desktop "$cert" "$key"
    fi
    chmod 600 "$key"
    grdctl --system rdp set-tls-cert "$cert"
    grdctl --system rdp set-tls-key "$key"
    grdctl --system rdp set-credentials "$RDP_USER" "$RDP_PASSWORD"
    grdctl --system rdp enable
    grdctl --system rdp disable-view-only || true
    systemctl enable gnome-remote-desktop.service
    systemctl restart gnome-remote-desktop.service
    rm -f "$RDP_ENV_FILE"
    log_success "System RDP enabled on 3389."
}

if [ "$CHECK_ONLY" = "1" ]; then
    check_kvm
    check_ssh
    check_rdp
    log_success "All guest checks passed."
    exit 0
fi

if [ "$SKIP_APT" != "1" ]; then
log_step "Installing system packages..."
apt-get update
base_pkgs=(qemu-guest-agent openssh-server git curl qemu-kvm cpu-checker
    libnss3 libnspr4 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64
    libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3
    libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2t64)
if [ "$GUI" = "0" ]; then
    log_info "Headless mode (CODING_VM_GUI=0): skipping desktop packages."
    apt-get install -y "${base_pkgs[@]}"
else
    apt-get install -y "${base_pkgs[@]}" \
        ubuntu-desktop-minimal gnome-remote-desktop
fi
fi

log_step "Enabling base services..."
systemctl enable --now qemu-guest-agent
systemctl enable --now ssh

if [ "$GUI" = "0" ]; then
    log_step "Disabling desktop services (headless)..."
    systemctl set-default multi-user.target || true
    systemctl disable --now gdm gdm3 gnome-remote-desktop.service 2>/dev/null || true
else
    setup_display_manager
fi

if [ -n "$GUEST_USER" ] && id "$GUEST_USER" >/dev/null 2>&1; then
    log_step "Granting $GUEST_USER access to KVM..."
    usermod -aG kvm "$GUEST_USER"
    loginctl enable-linger "$GUEST_USER" || log_warning "Could not enable linger for $GUEST_USER."
else
    log_warning "No guest user resolved; skipping kvm group setup."
fi

setup_rdp_system

check_kvm
check_ssh
check_rdp

log_success "Guest provisioning complete."
