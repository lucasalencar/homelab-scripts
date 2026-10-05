#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  # Hermetic user registry — scripts under test resolve .server_users here,
  # never the real repo file.
  export SERVER_USERS_FILE="$MOCK_TMPDIR/.server_users"
  for mock in ssh scp systemctl kvm-ok grdctl apt-get chown openssl; do
    chmod +x "$BATS_TEST_DIRNAME/../helpers/mocks/$mock"
  done
  echo "testuser" > "$SERVER_USERS_FILE"
  echo "ssh-ed25519 AAAAC3Nzc2VudGVzdA== bats-test" > "$MOCK_TMPDIR/testkey.pub"
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

_install_env() {
  export CODING_VM_NESTED_STATUS="Y"
  export CODING_VM_IMAGE_DIR="$MOCK_TMPDIR/images"
  export CODING_VM_SKIP_DOWNLOAD="1"
  export CODING_VM_SKIP_CHECKSUM="1"
  export CODING_VM_WAIT_TIMEOUT="1"
  export CODING_VM_SSH_PUBKEY_FILE="$MOCK_TMPDIR/testkey.pub"
  export CODING_VM_PROVISION_KEY_FILE="$MOCK_TMPDIR/provision-key"
  export CODING_VM_MIN_IMAGE_BYTES="0"
  export MOCK_PVESH_STORAGE='[{"storage":"local","type":"dir","content":"import,backup,iso,vztmpl,snippets","path":"'"$MOCK_TMPDIR"'/vz"},{"storage":"local-lvm","type":"lvmthin","content":"images,rootdir"}]'
}

# -------------------------------------------------------------------
# coding-vm/install.sh
# -------------------------------------------------------------------

@test "coding-vm install aborts when nested virtualization is disabled" {
  _install_env
  export CODING_VM_NESTED_STATUS="N"
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ested"* ]] || [[ "$output" == *"KVM"* ]]
}

@test "coding-vm install is idempotent when VM already exists" {
  _install_env
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n201  code                   running    8192              80.00 12345'
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  ! grep -q "^qm create" "$MOCK_LOG"
}

@test "coding-vm install creates VM when absent" {
  _install_env
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -eq 0 ]
  grep -q "^qm create" "$MOCK_LOG"
  grep -q "^qm importdisk" "$MOCK_LOG"
  grep -q "^qm set" "$MOCK_LOG"
  grep -q "^qm resize" "$MOCK_LOG"
  grep -q "^qm start" "$MOCK_LOG"
  grep -q "^scp " "$MOCK_LOG"
  grep -q "^ssh " "$MOCK_LOG"
  grep -q "cpu.*host" "$MOCK_LOG"
  grep -q "discard=on,ssd=1" "$MOCK_LOG"
}

@test "coding-vm install verifies image against Ubuntu SHA256SUMS star-marker format" {
  _install_env
  export CODING_VM_SKIP_DOWNLOAD="0"
  export CODING_VM_SKIP_CHECKSUM="0"
  export CODING_VM_MIN_IMAGE_BYTES="0"
  export CODING_VM_IMAGE_URL="https://example.invalid/noble-server-cloudimg-amd64.img"
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  mkdir -p "$CODING_VM_IMAGE_DIR"
  printf 'fake-image-bytes' > "$CODING_VM_IMAGE_DIR/noble-server-cloudimg-amd64.img"
  export MOCK_SHA256SUMS_LINE="$(sha256sum "$CODING_VM_IMAGE_DIR/noble-server-cloudimg-amd64.img" | awk '{print $1}') *noble-server-cloudimg-amd64.img"
  mkdir -p "$MOCK_TMPDIR/bin"
  cat > "$MOCK_TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$MOCK_LOG"
outfile=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[i]}" = "-o" ]; then
    outfile="${args[i+1]}"
  fi
done
url="${args[${#args[@]}-1]}"
if [[ "$url" == */SHA256SUMS ]]; then
  echo "$MOCK_SHA256SUMS_LINE" > "$outfile"
fi
exit 0
EOF
  # NOTE: chmod is shadowed by a no-op logging mock under test PATH —
  # newly created fixtures need the real binary to become executable.
  /bin/chmod +x "$MOCK_TMPDIR/bin/curl"
  export PATH="$MOCK_TMPDIR/bin:$PATH"
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -eq 0 ]
  grep -q "^qm create" "$MOCK_LOG"
}

@test "coding-vm install sets vendor snippet for first-boot agent" {
  _install_env
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -eq 0 ]
  grep -q "cicustom" "$MOCK_LOG"
  grep -q "vendor=" "$MOCK_LOG"
  [ -f "$MOCK_TMPDIR/vz/snippets/coding-vm-vendor.yaml" ]
  grep -q "qemu-guest-agent" "$MOCK_TMPDIR/vz/snippets/coding-vm-vendor.yaml"
}

@test "coding-vm install enables snippets on local when missing" {
  _install_env
  export MOCK_PVESH_STORAGE='[{"storage":"local","type":"dir","content":"import,backup,iso,vztmpl","path":"'"$MOCK_TMPDIR"'/vz"}]'
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -eq 0 ]
  grep -q "pvesm set local" "$MOCK_LOG"
  grep -q "cicustom" "$MOCK_LOG"
}

@test "coding-vm install rejects a truncated image" {
  _install_env
  export CODING_VM_MIN_IMAGE_BYTES="104857600"
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mage"* ]]
  ! grep -q "^qm create" "$MOCK_LOG"
}

@test "coding-vm install uses a dedicated host provisioning key" {
  _install_env
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -eq 0 ]
  grep -q "^ssh-keygen" "$MOCK_LOG"
  grep -qF -- "-i $MOCK_TMPDIR/provision-key" "$MOCK_LOG"
  grep -q -- "--sshkeys" "$MOCK_LOG"
}

@test "coding-vm install fails without a user key" {
  _install_env
  unset CODING_VM_SSH_PUBKEY_FILE
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CODING_VM_SSH_PUBKEY_FILE"* ]]
  ! grep -q "^qm create" "$MOCK_LOG"
}

@test "coding-vm install fails clearly when provisioning .pub is missing" {
  _install_env
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  touch "$CODING_VM_PROVISION_KEY_FILE"
  rm -f "$CODING_VM_PROVISION_KEY_FILE.pub"
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *".pub"* ]]
  ! grep -q "^qm create" "$MOCK_LOG"
}

@test "coding-vm install fails when bridge is missing" {
  _install_env
  export MOCK_IP_LINK_SHOW="1: lo: <LOOPBACK> mtu 65536"
  export CODING_VM_BRIDGE="vmbr9"
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bridge"* ]]
}

@test "coding-vm install fails when storage has no space" {
  _install_env
  export MOCK_PVESM_STATUS=$'Name             Type     Status           Total            Used       Available        %\nlocal-lvm         lvmthin active        200000000       199999000        1000     99.00%'
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"space"* ]] || [[ "$output" == *"storage"* ]]
}

# -------------------------------------------------------------------
# coding-vm/update.sh
# -------------------------------------------------------------------

@test "coding-vm update fails when VM is missing" {
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID'
  run bash "$REPO_ROOT/coding-vm/update.sh" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"code"* ]]
}

@test "coding-vm update upgrades via guest agent when running" {
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n201  code                   running    8192              80.00 12345'
  export MOCK_QM_STATUS="status: running"
  run bash "$REPO_ROOT/coding-vm/update.sh" 2>&1
  [ "$status" -eq 0 ]
  grep -q "^qm guest exec" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# coding-vm/provision.sh --check-only (guest-side validations)
# -------------------------------------------------------------------

@test "coding-vm provision check-only passes with KVM device" {
  touch "$MOCK_TMPDIR/kvm"
  export CODING_VM_TEST_MODE="1"
  export CODING_VM_KVM_DEVICE="$MOCK_TMPDIR/kvm"
  run bash "$REPO_ROOT/coding-vm/provision.sh" --check-only
  [ "$status" -eq 0 ]
  grep -q "^kvm-ok" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# coding-vm/ssh-setup.sh (client-side, HOME is faked)
# -------------------------------------------------------------------

@test "coding-vm ssh-setup generates key, copies it and writes ssh config" {
  export HOME="$MOCK_TMPDIR/home"
  mkdir -p "$HOME/.ssh"
  for mock in ssh-keygen ssh-copy-id; do
    chmod +x "$BATS_TEST_DIRNAME/../helpers/mocks/$mock"
  done
  run bash "$REPO_ROOT/coding-vm/ssh-setup.sh" "testuser@10.0.0.10"
  [ "$status" -eq 0 ]
  grep -q "^ssh-keygen" "$MOCK_LOG"
  grep -q "^ssh-copy-id" "$MOCK_LOG"
  grep -q "^Host code$" "$HOME/.ssh/config"
  grep -q "HostName 10.0.0.10" "$HOME/.ssh/config"
}

@test "coding-vm ssh-setup does not regenerate an existing key" {
  export HOME="$MOCK_TMPDIR/home"
  mkdir -p "$HOME/.ssh"
  touch "$HOME/.ssh/code"
  for mock in ssh-keygen ssh-copy-id; do
    chmod +x "$BATS_TEST_DIRNAME/../helpers/mocks/$mock"
  done
  : > "$MOCK_LOG"
  run bash "$REPO_ROOT/coding-vm/ssh-setup.sh" "10.0.0.10"
  [ "$status" -eq 0 ]
  ! grep -q "^ssh-keygen" "$MOCK_LOG"
  grep -q "^ssh-copy-id" "$MOCK_LOG"
}

@test "coding-vm ssh-setup fails without an IP" {
  export HOME="$MOCK_TMPDIR/home"
  mkdir -p "$HOME/.ssh"
  run bash "$REPO_ROOT/coding-vm/ssh-setup.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"IP"* ]]
}

@test "coding-vm ssh-setup updates HostName on re-run with new IP" {
  export HOME="$MOCK_TMPDIR/home"
  mkdir -p "$HOME/.ssh"
  for mock in ssh-keygen ssh-copy-id; do
    chmod +x "$BATS_TEST_DIRNAME/../helpers/mocks/$mock"
  done
  run bash "$REPO_ROOT/coding-vm/ssh-setup.sh" "testuser@10.0.0.10"
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/coding-vm/ssh-setup.sh" "testuser@10.0.0.99"
  [ "$status" -eq 0 ]
  grep -q "HostName 10.0.0.99" "$HOME/.ssh/config"
  [ "$(grep -c "^Host code$" "$HOME/.ssh/config")" -eq 1 ]
}

@test "coding-vm provision check-only aborts without KVM device" {
  export CODING_VM_TEST_MODE="1"
  export CODING_VM_KVM_DEVICE="$MOCK_TMPDIR/no-kvm-here"
  run bash "$REPO_ROOT/coding-vm/provision.sh" --check-only
  [ "$status" -ne 0 ]
}

@test "coding-vm provision check-only fails when kvm-ok fails" {
  touch "$MOCK_TMPDIR/kvm"
  export CODING_VM_TEST_MODE="1"
  export CODING_VM_KVM_DEVICE="$MOCK_TMPDIR/kvm"
  export MOCK_KVM_OK_FAIL="1"
  run bash "$REPO_ROOT/coding-vm/provision.sh" --check-only
  [ "$status" -ne 0 ]
}

@test "coding-vm provision check-only fails when ssh inactive" {
  touch "$MOCK_TMPDIR/kvm"
  export CODING_VM_TEST_MODE="1"
  export CODING_VM_KVM_DEVICE="$MOCK_TMPDIR/kvm"
  export MOCK_SYSTEMCTL_FAIL="1"
  run bash "$REPO_ROOT/coding-vm/provision.sh" --check-only
  [ "$status" -ne 0 ]
}

# -------------------------------------------------------------------
# coding-vm/provision.sh system RDP (grdctl --system, headless-safe)
# -------------------------------------------------------------------

@test "coding-vm provision skips system RDP without credentials" {
  touch "$MOCK_TMPDIR/kvm"
  export CODING_VM_TEST_MODE="1"
  export CODING_VM_KVM_DEVICE="$MOCK_TMPDIR/kvm"
  export CODING_VM_SKIP_APT="1"
  export CODING_VM_USER="testuser"
  unset CODING_VM_RDP_USER
  unset CODING_VM_RDP_PASSWORD
  export CODING_VM_RDP_ENV_FILE="$MOCK_TMPDIR/no-rdp.env"
  : > "$MOCK_LOG"
  run bash "$REPO_ROOT/coding-vm/provision.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RDP"* ]]
  ! grep -q "^grdctl " "$MOCK_LOG"
}

@test "coding-vm provision configures system RDP with credentials" {
  touch "$MOCK_TMPDIR/kvm"
  export CODING_VM_TEST_MODE="1"
  export CODING_VM_KVM_DEVICE="$MOCK_TMPDIR/kvm"
  export CODING_VM_SKIP_APT="1"
  export CODING_VM_USER="testuser"
  export CODING_VM_RDP_USER="rdpuser"
  export CODING_VM_RDP_PASSWORD="fixture-pass"
  export CODING_VM_RDP_CERT_DIR="$MOCK_TMPDIR/certs"
  export CODING_VM_RDP_ENV_FILE="$MOCK_TMPDIR/no-rdp.env"
  : > "$MOCK_LOG"
  run bash "$REPO_ROOT/coding-vm/provision.sh"
  [ "$status" -eq 0 ]
  grep -q "^openssl " "$MOCK_LOG"
  grep -q "^grdctl --system rdp set-tls-cert" "$MOCK_LOG"
  grep -q "^grdctl --system rdp set-tls-key" "$MOCK_LOG"
  grep -q "^grdctl --system rdp set-credentials rdpuser" "$MOCK_LOG"
  grep -q "^grdctl --system rdp enable" "$MOCK_LOG"
  grep -q "gnome-remote-desktop" "$MOCK_LOG"
  [ -f "$MOCK_TMPDIR/certs/rdp-tls.crt" ]
  [ -f "$MOCK_TMPDIR/certs/rdp-tls.key" ]
}

@test "coding-vm provision loads RDP password from env file" {
  touch "$MOCK_TMPDIR/kvm"
  export CODING_VM_TEST_MODE="1"
  export CODING_VM_KVM_DEVICE="$MOCK_TMPDIR/kvm"
  export CODING_VM_SKIP_APT="1"
  export CODING_VM_USER="testuser"
  export CODING_VM_RDP_USER="rdpuser"
  unset CODING_VM_RDP_PASSWORD
  export CODING_VM_RDP_CERT_DIR="$MOCK_TMPDIR/certs2"
  export CODING_VM_RDP_ENV_FILE="$MOCK_TMPDIR/rdp.env"
  printf "CODING_VM_RDP_PASSWORD='file-pass'\n" > "$MOCK_TMPDIR/rdp.env"
  : > "$MOCK_LOG"
  run bash "$REPO_ROOT/coding-vm/provision.sh"
  [ "$status" -eq 0 ]
  grep -q "^grdctl --system rdp set-credentials rdpuser" "$MOCK_LOG"
}

@test "coding-vm provision check-only validates system RDP when configured" {
  touch "$MOCK_TMPDIR/kvm"
  export CODING_VM_TEST_MODE="1"
  export CODING_VM_KVM_DEVICE="$MOCK_TMPDIR/kvm"
  export CODING_VM_RDP_USER="rdpuser"
  export CODING_VM_RDP_PASSWORD="fixture-pass"
  export CODING_VM_RDP_CERT_DIR="$MOCK_TMPDIR/certs3"
  export CODING_VM_RDP_ENV_FILE="$MOCK_TMPDIR/no-rdp.env"
  /bin/mkdir -p "$MOCK_TMPDIR/certs3"
  touch "$MOCK_TMPDIR/certs3/rdp-tls.crt" "$MOCK_TMPDIR/certs3/rdp-tls.key"
  export MOCK_SYSTEMCTL_FAIL="1"
  run bash "$REPO_ROOT/coding-vm/provision.sh" --check-only
  [ "$status" -ne 0 ]
}

# -------------------------------------------------------------------
# coding-vm/install.sh RDP secret transport (file, never ssh argv)
# -------------------------------------------------------------------

@test "coding-vm install ships RDP password via file without leaking secret" {
  _install_env
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  export CODING_VM_RDP_USER="rdpuser"
  export CODING_VM_RDP_PASSWORD="s3cret-xyz-123"
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -eq 0 ]
  grep -q "coding-vm-rdp.env" "$MOCK_LOG"
  ! grep -q "s3cret-xyz-123" "$MOCK_LOG"
  grep -q "CODING_VM_RDP_USER=rdpuser" "$MOCK_LOG"
}

@test "coding-vm install skips RDP file transport without password" {
  _install_env
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  unset CODING_VM_RDP_PASSWORD
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -eq 0 ]
  ! grep -q "coding-vm-rdp.env" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# coding-vm GUI option (CODING_VM_GUI=0 headless, default with GUI)
# -------------------------------------------------------------------

@test "coding-vm provision installs headless packages by default" {
  touch "$MOCK_TMPDIR/kvm"
  export CODING_VM_TEST_MODE="1"
  export CODING_VM_KVM_DEVICE="$MOCK_TMPDIR/kvm"
  export CODING_VM_SKIP_APT="0"
  export CODING_VM_USER="testuser"
  unset CODING_VM_GUI
  unset CODING_VM_RDP_USER
  unset CODING_VM_RDP_PASSWORD
  export CODING_VM_RDP_ENV_FILE="$MOCK_TMPDIR/no-rdp.env"
  : > "$MOCK_LOG"
  run bash "$REPO_ROOT/coding-vm/provision.sh"
  [ "$status" -eq 0 ]
  grep -q "^apt-get install" "$MOCK_LOG"
  grep -q "qemu-guest-agent" "$MOCK_LOG"
  ! grep -q "ubuntu-desktop-minimal" "$MOCK_LOG"
  ! grep -q "^apt-get install.*gnome-remote-desktop" "$MOCK_LOG"
}

@test "coding-vm provision installs desktop packages when GUI enabled" {
  touch "$MOCK_TMPDIR/kvm"
  export CODING_VM_TEST_MODE="1"
  export CODING_VM_KVM_DEVICE="$MOCK_TMPDIR/kvm"
  export CODING_VM_SKIP_APT="0"
  export CODING_VM_USER="testuser"
  export CODING_VM_GUI="1"
  unset CODING_VM_RDP_USER
  unset CODING_VM_RDP_PASSWORD
  export CODING_VM_RDP_ENV_FILE="$MOCK_TMPDIR/no-rdp.env"
  : > "$MOCK_LOG"
  run bash "$REPO_ROOT/coding-vm/provision.sh"
  [ "$status" -eq 0 ]
  grep -q "ubuntu-desktop-minimal" "$MOCK_LOG"
  grep -q "gnome-remote-desktop" "$MOCK_LOG"
}

@test "coding-vm provision installs headless packages without desktop when GUI disabled" {
  touch "$MOCK_TMPDIR/kvm"
  export CODING_VM_TEST_MODE="1"
  export CODING_VM_KVM_DEVICE="$MOCK_TMPDIR/kvm"
  export CODING_VM_SKIP_APT="0"
  export CODING_VM_USER="testuser"
  export CODING_VM_GUI="0"
  unset CODING_VM_RDP_USER
  unset CODING_VM_RDP_PASSWORD
  export CODING_VM_RDP_ENV_FILE="$MOCK_TMPDIR/no-rdp.env"
  : > "$MOCK_LOG"
  run bash "$REPO_ROOT/coding-vm/provision.sh"
  [ "$status" -eq 0 ]
  grep -q "^apt-get install" "$MOCK_LOG"
  grep -q "qemu-guest-agent" "$MOCK_LOG"
  ! grep -q "ubuntu-desktop-minimal" "$MOCK_LOG"
  ! grep -q "^apt-get install.*gnome-remote-desktop" "$MOCK_LOG"
}

@test "coding-vm provision disables GUI services when headless" {
  touch "$MOCK_TMPDIR/kvm"
  export CODING_VM_TEST_MODE="1"
  export CODING_VM_KVM_DEVICE="$MOCK_TMPDIR/kvm"
  export CODING_VM_SKIP_APT="1"
  export CODING_VM_USER="testuser"
  export CODING_VM_GUI="0"
  unset CODING_VM_RDP_USER
  unset CODING_VM_RDP_PASSWORD
  export CODING_VM_RDP_ENV_FILE="$MOCK_TMPDIR/no-rdp.env"
  : > "$MOCK_LOG"
  run bash "$REPO_ROOT/coding-vm/provision.sh"
  [ "$status" -eq 0 ]
  grep -q "multi-user.target" "$MOCK_LOG"
  grep -q "disable.*gdm" "$MOCK_LOG"
}

@test "coding-vm provision skips RDP setup when headless even with credentials" {
  touch "$MOCK_TMPDIR/kvm"
  export CODING_VM_TEST_MODE="1"
  export CODING_VM_KVM_DEVICE="$MOCK_TMPDIR/kvm"
  export CODING_VM_SKIP_APT="1"
  export CODING_VM_USER="testuser"
  export CODING_VM_GUI="0"
  export CODING_VM_RDP_USER="rdpuser"
  export CODING_VM_RDP_PASSWORD="fixture-pass"
  export CODING_VM_RDP_CERT_DIR="$MOCK_TMPDIR/certs-headless"
  export CODING_VM_RDP_ENV_FILE="$MOCK_TMPDIR/no-rdp.env"
  : > "$MOCK_LOG"
  run bash "$REPO_ROOT/coding-vm/provision.sh"
  [ "$status" -eq 0 ]
  ! grep -q "^grdctl " "$MOCK_LOG"
}

@test "coding-vm install passes GUI flag to guest" {
  _install_env
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  export CODING_VM_GUI="0"
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -eq 0 ]
  grep -q "CODING_VM_GUI=0" "$MOCK_LOG"
}

@test "coding-vm install defaults to headless guest flag" {
  _install_env
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  unset CODING_VM_GUI
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -eq 0 ]
  grep -q "CODING_VM_GUI=0" "$MOCK_LOG"
}
