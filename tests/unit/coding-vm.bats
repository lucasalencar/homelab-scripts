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
  for mock in ssh scp systemctl kvm-ok; do
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

@test "coding-vm install picks up the conventional mac key from the primary user home" {
  _install_env
  unset CODING_VM_SSH_PUBKEY_FILE
  mkdir -p "$MOCK_TMPDIR/fakehome"
  printf 'ssh-ed25519 AAAAC3Nzc2VudGVzdA== mac-key\n' > "$MOCK_TMPDIR/fakehome/code-mac.pub"
  export MOCK_GETENT_PASSWD="testuser:x:1000:1000::$MOCK_TMPDIR/fakehome:/bin/bash"
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"code-mac.pub"* ]]
  ! grep -q "No user SSH key" <<< "$output"
}

@test "coding-vm install warns but continues without a user key" {
  _install_env
  unset CODING_VM_SSH_PUBKEY_FILE
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No user SSH key"* ]]
  grep -q -- "--sshkeys" "$MOCK_LOG"
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

@test "coding-vm provision check-only aborts without KVM device" {
  export CODING_VM_TEST_MODE="1"
  export CODING_VM_KVM_DEVICE="$MOCK_TMPDIR/no-kvm-here"
  run bash "$REPO_ROOT/coding-vm/provision.sh" --check-only
  [ "$status" -ne 0 ]
}
