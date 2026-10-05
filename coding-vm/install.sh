#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

VM_NAME="${CODING_VM_NAME:-code}"
CORES="${CODING_VM_CORES:-8}"
MEMORY_MB="${CODING_VM_MEMORY_MB:-8192}"
BALLOON_MB="${CODING_VM_BALLOON_MB:-2048}"
DISK_GB="${CODING_VM_DISK_GB:-80}"
STORAGE="${CODING_VM_STORAGE:-local-lvm}"
BRIDGE="${CODING_VM_BRIDGE:-}"
IMAGE_URL="${CODING_VM_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
IMAGE_DIR="${CODING_VM_IMAGE_DIR:-/var/lib/vz/template/iso}"
WAIT_TIMEOUT="${CODING_VM_WAIT_TIMEOUT:-300}"
MIN_IMAGE_BYTES="${CODING_VM_MIN_IMAGE_BYTES:-104857600}"
GUI="${CODING_VM_GUI:-0}"

log_step "Starting coding VM ($VM_NAME) installation..."

nested="${CODING_VM_NESTED_STATUS:-}"
if [ -z "$nested" ]; then
    nested="N"
    for mod in kvm_intel kvm_amd; do
        if [ -r "/sys/module/$mod/parameters/nested" ]; then
            val=$(cat "/sys/module/$mod/parameters/nested" 2>/dev/null || true)
            case "$val" in
                Y|y|1) nested="Y" ;;
            esac
        fi
    done
fi
case "$nested" in
    Y|y|1) log_info "Nested virtualization is enabled." ;;
    *) log_error "Nested virtualization is disabled on this host. Enable it (kvm_intel/kvm_amd nested=1) for KVM acceleration inside the VM."; exit 1 ;;
esac

existing_id=$(get_vm_id_by_name "$VM_NAME" || true)
if [ -n "$existing_id" ]; then
    log_info "VM '$VM_NAME' already exists (ID: $existing_id). Skipping creation."
    log_success "Coding VM is already in place."
    exit 0
fi

if [ -z "$BRIDGE" ]; then
    BRIDGE=$(detect_pve_bridge)
fi
log_info "Using bridge: $BRIDGE"
if ! ip -o link show 2>/dev/null | grep -qF -- "$BRIDGE"; then
    log_error "Network bridge '$BRIDGE' not found on this host."
    exit 1
fi

needed_kb=$((DISK_GB * 1024 * 1024))
avail_kb=$(pvesm status 2>/dev/null | awk -v s="$STORAGE" '$1==s {print $6}' || true)
if ! [[ "$avail_kb" =~ ^[0-9]+$ ]] || [ "$avail_kb" -lt "$needed_kb" ]; then
    log_error "Storage '$STORAGE' has no space for a ${DISK_GB}G disk (available: ${avail_kb:-unknown} KB)."
    exit 1
fi
log_info "Storage $STORAGE has room for ${DISK_GB}G."

vmid=$(get_pve_next_id) || exit 1
log_info "Next free VM ID: $vmid"

PRIMARY_USER=$(get_primary_user) || exit 1
CI_USER="${CODING_VM_CI_USER:-$PRIMARY_USER}"
log_info "Cloud-init user: $CI_USER"

USER_PUBKEY_FILE="${CODING_VM_SSH_PUBKEY_FILE:-}"
if [ -z "$USER_PUBKEY_FILE" ]; then
    log_error "CODING_VM_SSH_PUBKEY_FILE is required (copy your Mac key to the host first, see README)."
    exit 1
fi
if [ ! -f "$USER_PUBKEY_FILE" ]; then
    log_error "CODING_VM_SSH_PUBKEY_FILE=$USER_PUBKEY_FILE does not exist."
    exit 1
fi
log_info "Injecting user key: $USER_PUBKEY_FILE"

PROVISION_KEY_FILE="${CODING_VM_PROVISION_KEY_FILE:-/root/.ssh/coding-vm-$VM_NAME}"
if [ ! -f "$PROVISION_KEY_FILE" ]; then
    log_step "Generating host provisioning key..."
    mkdir -p "$(dirname "$PROVISION_KEY_FILE")"
    ssh-keygen -t ed25519 -f "$PROVISION_KEY_FILE" -N "" -C "coding-vm-$VM_NAME-provision"
elif [ ! -f "$PROVISION_KEY_FILE.pub" ]; then
    log_error "Provisioning key $PROVISION_KEY_FILE exists but $PROVISION_KEY_FILE.pub is missing. Delete both or restore the .pub, then re-run."
    exit 1
fi

combined_keys=$(mktemp)
trap 'rm -f "$combined_keys"' EXIT
{
    cat "$PROVISION_KEY_FILE.pub"
    printf '\n'
    cat "$USER_PUBKEY_FILE"
    printf '\n'
} > "$combined_keys"

mkdir -p "$IMAGE_DIR"
image_file="$IMAGE_DIR/$(basename "$IMAGE_URL")"
if [ "${CODING_VM_SKIP_DOWNLOAD:-0}" = "1" ]; then
    log_info "Skipping image download (CODING_VM_SKIP_DOWNLOAD=1)."
    touch "$image_file"
else
    if [ ! -f "$image_file" ]; then
        log_step "Downloading Ubuntu cloud image..."
        curl -fsSL -o "$image_file" "$IMAGE_URL" || { log_error "Image download failed."; exit 1; }
    else
        log_info "Image already present: $image_file"
    fi
    if [ "${CODING_VM_SKIP_CHECKSUM:-0}" != "1" ]; then
        log_step "Verifying image checksum..."
        sums_file="$IMAGE_DIR/SHA256SUMS"
        curl -fsSL -o "$sums_file" "$(dirname "$IMAGE_URL")/SHA256SUMS" || { log_error "Checksum file download failed."; exit 1; }
        (cd "$IMAGE_DIR" && grep -E "[ *]$(basename "$image_file")\$" SHA256SUMS | sha256sum -c -) || { log_error "Image checksum mismatch."; exit 1; }
    fi
fi
if [ ! -f "$image_file" ]; then
    log_error "Image download failed."
    exit 1
fi
image_bytes=$(stat -c%s "$image_file" 2>/dev/null || echo 0)
if [ "$image_bytes" -lt "$MIN_IMAGE_BYTES" ]; then
    log_error "Image $image_file is too small ($image_bytes bytes, minimum $MIN_IMAGE_BYTES); likely truncated. Delete it and re-run."
    exit 1
fi

log_step "Creating VM $vmid ($VM_NAME)..."
qm create "$vmid" --name "$VM_NAME" \
    --sockets 1 --cores "$CORES" --memory "$MEMORY_MB" --balloon "$BALLOON_MB" \
    --cpu host --machine q35 --ostype l26 --scsihw virtio-scsi-pci \
    --net0 "virtio,bridge=$BRIDGE" --agent enabled=1 --onboot 0
qm importdisk "$vmid" "$image_file" "$STORAGE"
qm set "$vmid" --scsi0 "$STORAGE:vm-$vmid-disk-0,discard=on,ssd=1"
qm set "$vmid" --ide2 "$STORAGE:cloudinit"
qm set "$vmid" --boot order=scsi0 --serial0 socket
qm set "$vmid" --ciuser "$CI_USER" --sshkeys "$combined_keys" --ipconfig0 ip=dhcp
rm -f "$combined_keys"

log_step "Ensuring first-boot guest agent via cloud-init vendor-data..."
storage_json=$(pvesh get /storage --output-format json 2>/dev/null || echo "[]")
snippet_storage=$(echo "$storage_json" | jq -r '[.[] | select(.content != null and (.content | split(",") | index("snippets")))] | .[0].storage // empty' || true)
snippet_path=""
if [ -z "$snippet_storage" ]; then
    log_step "Enabling snippets content on local storage..."
    local_content=$(echo "$storage_json" | jq -r '.[] | select(.storage == "local") | .content // empty' || true)
    local_path=$(echo "$storage_json" | jq -r '.[] | select(.storage == "local") | .path // empty' || true)
    if [ -z "$local_content" ] || [ -z "$local_path" ]; then
        log_error "No storage with snippets content and no local storage to enable it on."
        exit 1
    fi
    pvesm set local --content "$local_content,snippets" || exit 1
    snippet_storage="local"
    snippet_path="$local_path"
else
    snippet_path=$(echo "$storage_json" | jq -r --arg s "$snippet_storage" '.[] | select(.storage == $s) | .path // empty' || true)
fi
if [ -z "$snippet_path" ]; then
    log_error "Could not determine path for snippets storage '$snippet_storage'."
    exit 1
fi
snippet_file="$snippet_path/snippets/coding-vm-vendor.yaml"
mkdir -p "$(dirname "$snippet_file")"
cat > "$snippet_file" <<'EOF'
#cloud-config
# Installed by coding-vm/install.sh: guest agent from first boot so that
# qm guest exec works immediately (stock Ubuntu cloud images lack it).
packages:
  - qemu-guest-agent
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
EOF
qm set "$vmid" --cicustom "vendor=${snippet_storage}:snippets/coding-vm-vendor.yaml"
qm resize "$vmid" scsi0 "${DISK_GB}G"

log_step "Starting VM $vmid..."
qm start "$vmid"

log_step "Waiting for guest agent (up to ${WAIT_TIMEOUT}s)..."
# wait_vm_ready polls every WAIT_SLEEP_S seconds; attempts cover WAIT_TIMEOUT
WAIT_SLEEP_S=5
wait_vm_ready "$vmid" "$(( (WAIT_TIMEOUT + WAIT_SLEEP_S - 1) / WAIT_SLEEP_S ))" "$WAIT_SLEEP_S" || exit 1

vm_ip=$(get_vm_ip "$vmid")
if [ -z "$vm_ip" ]; then
    log_error "Could not determine IP for VM $vmid."
    exit 1
fi
log_info "VM IP: $vm_ip"

ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$PROVISION_KEY_FILE")
log_step "Pushing guest provision script..."
scp "${ssh_opts[@]}" "$SCRIPT_DIR/provision.sh" "$CI_USER@$vm_ip:/tmp/coding-vm-provision.sh"

# RDP password travels via scp'd env file, never in ssh argv (see mock secret-absence test).
rdp_env_file=""
if [ -n "${CODING_VM_RDP_PASSWORD:-}" ]; then
    rdp_env_file=$(mktemp)
    chmod 600 "$rdp_env_file"
    printf 'CODING_VM_RDP_PASSWORD=%q\n' "$CODING_VM_RDP_PASSWORD" > "$rdp_env_file"
    trap 'rm -f "$combined_keys" "$rdp_env_file"' EXIT
    scp "${ssh_opts[@]}" "$rdp_env_file" "$CI_USER@$vm_ip:/tmp/coding-vm-rdp.env"
fi

guest_env=("CODING_VM_USER=$CI_USER" "CODING_VM_GUI=$GUI")
if [ -n "${CODING_VM_RDP_USER:-}" ]; then
    guest_env+=("CODING_VM_RDP_USER=${CODING_VM_RDP_USER}")
fi
if [ -n "${CODING_VM_RDP_CERT_DIR:-}" ]; then
    guest_env+=("CODING_VM_RDP_CERT_DIR=${CODING_VM_RDP_CERT_DIR}")
fi

log_step "Running guest provisioning..."
ssh "${ssh_opts[@]}" "$CI_USER@$vm_ip" sudo env "${guest_env[@]}" bash /tmp/coding-vm-provision.sh

log_step "Validating guest (KVM, ssh)..."
ssh "${ssh_opts[@]}" "$CI_USER@$vm_ip" sudo env "${guest_env[@]}" bash /tmp/coding-vm-provision.sh --check-only

echo ""
log_success "Coding VM '$VM_NAME' (ID: $vmid, IP: $vm_ip) is ready."
log_info "SSH: ssh $CI_USER@$vm_ip (VS Code Remote-SSH)"
if [ "$GUI" = "0" ]; then
    log_info "GUI: disabled (headless, CODING_VM_GUI=0 — no desktop, no RDP)"
elif [ -n "${CODING_VM_RDP_USER:-}" ]; then
    log_info "RDP: $vm_ip:3389 (system grdctl, user ${CODING_VM_RDP_USER})"
else
    log_info "RDP: not configured (set CODING_VM_RDP_USER/CODING_VM_RDP_PASSWORD and re-run provision for headless RDP on :3389)"
fi
log_info "SSH/RDP are plain TCP; no Caddy entry needed."
