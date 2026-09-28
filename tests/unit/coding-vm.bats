#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  for mock in ssh scp systemctl kvm-ok; do
    chmod +x "$BATS_TEST_DIRNAME/../helpers/mocks/$mock"
  done
  if [ -f "$REPO_ROOT/.server_users" ]; then
    cp "$REPO_ROOT/.server_users" "$MOCK_TMPDIR/.server_users.bak"
  fi
  echo "testuser" > "$REPO_ROOT/.server_users"
  echo "ssh-ed25519 AAAAC3Nzc2VudGVzdA== bats-test" > "$MOCK_TMPDIR/testkey.pub"
}

teardown() {
  if [ -f "$MOCK_TMPDIR/.server_users.bak" ]; then
    cp "$MOCK_TMPDIR/.server_users.bak" "$REPO_ROOT/.server_users"
  elif [ -f "$REPO_ROOT/.server_users" ]; then
    if grep -q "bats-test" "$REPO_ROOT/.server_users" 2>/dev/null || grep -q "testuser" "$REPO_ROOT/.server_users" 2>/dev/null; then
      rm -f "$REPO_ROOT/.server_users"
    fi
  fi
  rm -rf "$MOCK_TMPDIR"
}

_install_env() {
  export CODING_VM_NESTED_STATUS="Y"
  export CODING_VM_IMAGE_DIR="$MOCK_TMPDIR/images"
  export CODING_VM_SKIP_DOWNLOAD="1"
  export CODING_VM_SKIP_CHECKSUM="1"
  export CODING_VM_WAIT_TIMEOUT="1"
  export CODING_VM_SSH_PUBKEY_FILE="$MOCK_TMPDIR/testkey.pub"
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
}

@test "coding-vm install forwards dotfiles bootstrap file to guest" {
  _install_env
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345'
  printf '#!/bin/bash\necho bootstrap\n' > "$MOCK_TMPDIR/bootstrap.sh"
  chmod +x "$MOCK_TMPDIR/bootstrap.sh"
  export DOTFILES_BOOTSTRAP="$MOCK_TMPDIR/bootstrap.sh"
  run bash "$REPO_ROOT/coding-vm/install.sh"
  [ "$status" -eq 0 ]
  grep -q "bootstrap.sh" "$MOCK_LOG"
  grep -q "DOTFILES_BOOTSTRAP=/tmp/coding-vm-dotfiles-bootstrap" "$MOCK_LOG"
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
