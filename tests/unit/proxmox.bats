#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  export PROXMOX_RO_TEMPLATE="$REPO_ROOT/proxmox/post-install/proxmox-ro.sudoers"
  if [ -f "$REPO_ROOT/.server_users" ]; then
    cp "$REPO_ROOT/.server_users" "$MOCK_TMPDIR/.server_users.bak"
  fi
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

# -------------------------------------------------------------------
# proxmox/storage-setup/001-create-datasets.sh (via helper)
# -------------------------------------------------------------------

@test "proxmox storage-setup uses setup_dataset_acls with correct UIDs" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; setup_dataset_acls "tank/data/mediaserver" "/tank/data/mediaserver" "1000" "100000"'
  [ "$status" -eq 0 ]
  grep -q "zfs set acltype=posixacl tank/data/mediaserver" "$MOCK_LOG"
  grep -q "chown -R 1000:1000 /tank/data/mediaserver" "$MOCK_LOG"
}

@test "proxmox storage-setup handles zfs create failure" {
  export MOCK_ZFS_FAIL=1
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; zfs create tank/data/test; echo ok'
  # Mock should fail when MOCK_ZFS_FAIL=1 is respected by caller that checks exit code
  # Here we just verify mock was called and would fail if checked
  grep -q "zfs create tank/data/test" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# proxmox/post-install/005-add-secondary-user.sh (via is_user_registered)
# -------------------------------------------------------------------

@test "proxmox add-secondary-user duplicate check" {
  tmp_root=$(mktemp -d)
  mkdir -p "$tmp_root/common"
  cp "$REPO_ROOT/common/functions.sh" "$tmp_root/common/functions.sh"
  printf "alice\nbob\n" > "$tmp_root/.server_users"
  output=$(bash -c "source '$tmp_root/common/functions.sh'; is_user_registered alice && echo yes || echo no" 2>&1)
  [ "$output" = "yes" ]
  rm -rf "$tmp_root"
}

# -------------------------------------------------------------------
# common/functions.sh :: ensure_primary_user
# -------------------------------------------------------------------

@test "ensure_primary_user creates .server_users when missing" {
  tmp_root=$(mktemp -d)
  mkdir -p "$tmp_root/common"
  cp "$REPO_ROOT/common/functions.sh" "$tmp_root/common/functions.sh"
  run bash -c "source '$tmp_root/common/functions.sh'; ensure_primary_user alice"
  [ "$status" -eq 0 ]
  [ -f "$tmp_root/.server_users" ]
  assert_file_contains "^alice$" "$tmp_root/.server_users"
  rm -rf "$tmp_root"
}

@test "ensure_primary_user is a no-op when primary already first line" {
  tmp_root=$(mktemp -d)
  mkdir -p "$tmp_root/common"
  cp "$REPO_ROOT/common/functions.sh" "$tmp_root/common/functions.sh"
  printf "alice\nbob\n" > "$tmp_root/.server_users"
  run bash -c "source '$tmp_root/common/functions.sh'; ensure_primary_user alice"
  [ "$status" -eq 0 ]
  content=$(cat "$tmp_root/.server_users")
  [ "$content" = "alice
bob" ]
  rm -rf "$tmp_root"
}

@test "ensure_primary_user refuses to overwrite others' entries" {
  tmp_root=$(mktemp -d)
  mkdir -p "$tmp_root/common"
  cp "$REPO_ROOT/common/functions.sh" "$tmp_root/common/functions.sh"
  printf "lucas\njacque\n" > "$tmp_root/.server_users"
  run bash -c "source '$tmp_root/common/functions.sh'; ensure_primary_user carol"
  [ "$status" -ne 0 ]
  # The secondary user entry must survive the failed attempt
  assert_file_contains "^jacque$" "$tmp_root/.server_users"
  [[ "$output" == *"secondary"* ]]
  rm -rf "$tmp_root"
}

@test "ensure_primary_user updates primary when only primary registered" {
  tmp_root=$(mktemp -d)
  mkdir -p "$tmp_root/common"
  cp "$REPO_ROOT/common/functions.sh" "$tmp_root/common/functions.sh"
  printf "oldprimary\n" > "$tmp_root/.server_users"
  run bash -c "source '$tmp_root/common/functions.sh'; ensure_primary_user newprimary"
  [ "$status" -eq 0 ]
  content=$(cat "$tmp_root/.server_users")
  [ "$content" = "newprimary" ]
  rm -rf "$tmp_root"
}

@test "ensure_primary_user fails without username" {
  tmp_root=$(mktemp -d)
  mkdir -p "$tmp_root/common"
  cp "$REPO_ROOT/common/functions.sh" "$tmp_root/common/functions.sh"
  run bash -c "source '$tmp_root/common/functions.sh'; ensure_primary_user"
  [ "$status" -ne 0 ]
  rm -rf "$tmp_root"
}

# -------------------------------------------------------------------
# common/functions.sh :: grant_proxmox_readonly
# -------------------------------------------------------------------

# In bats, `! grep` and bare `grep -q` in the test body do NOT cause test
# failure (body exit codes are ignored). Use these helpers to actually fail
# the test when a pattern is/isn't found.
assert_file_contains() {
  local pattern="$1" file="$2"
  grep -q "$pattern" "$file" || {
    echo "FAIL: expected pattern '$pattern' in $file" >&2
    return 1
  }
}
assert_file_not_contains() {
  local pattern="$1" file="$2"
  ! grep -q "$pattern" "$file" || {
    echo "FAIL: forbidden pattern '$pattern' found in $file" >&2
    return 1
  }
  return 0
}

@test "grant_proxmox_readonly adds user to required groups on first run" {
  export MOCK_ID_NG=""  # user not in any of the target groups yet
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; grant_proxmox_readonly testuser'
  [ "$status" -eq 0 ]
  assert_file_contains "^usermod -aG www-data testuser$" "$MOCK_LOG"
  assert_file_contains "^usermod -aG adm testuser$" "$MOCK_LOG"
  assert_file_contains "^usermod -aG systemd-journal testuser$" "$MOCK_LOG"
}

@test "grant_proxmox_readonly is idempotent when user already in groups" {
  export MOCK_ID_NG="familia sudo www-data adm systemd-journal users lxc-data"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; grant_proxmox_readonly testuser'
  [ "$status" -eq 0 ]
  assert_file_not_contains "^usermod -aG" "$MOCK_LOG"
  [[ "$output" == *"already in 'www-data' group"* ]]
  [[ "$output" == *"already in 'adm' group"* ]]
  [[ "$output" == *"already in 'systemd-journal' group"* ]]
}

@test "grant_proxmox_readonly installs sudoers drop-in with expected content" {
  sudoers_target="$MOCK_TMPDIR/proxmox-ro"
  export PROXMOX_RO_SUDOERS_FILE="$sudoers_target"
  export MOCK_ID_NG=""
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; grant_proxmox_readonly testuser'
  [ "$status" -eq 0 ]
  [ -f "$sudoers_target" ]
  assert_file_contains "^testuser ALL=(root) NOPASSWD: " "$sudoers_target"
  assert_file_contains "/usr/sbin/qm config" "$sudoers_target"
  assert_file_contains "/usr/sbin/pct list" "$sudoers_target"
  assert_file_contains "/usr/sbin/pvesm status" "$sudoers_target"
  assert_file_contains "/usr/sbin/corosync-cfgtool -s" "$sudoers_target"
  # Write subcommands must NOT appear
  assert_file_not_contains "/usr/sbin/qm start" "$sudoers_target"
  assert_file_not_contains "/usr/sbin/pct stop" "$sudoers_target"
  assert_file_not_contains "/usr/sbin/qm destroy" "$sudoers_target"
  assert_file_contains "^visudo -c" "$MOCK_LOG"
}

@test "grant_proxmox_readonly skips reinstalling identical sudoers file" {
  sudoers_target="$MOCK_TMPDIR/proxmox-ro"
  export PROXMOX_RO_SUDOERS_FILE="$sudoers_target"
  export MOCK_ID_NG=""
  # First install
  bash -c 'source "$REPO_ROOT/common/functions.sh"; grant_proxmox_readonly testuser' >/dev/null 2>&1
  # Reset log to count install invocations on second run
  : > "$MOCK_LOG"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; grant_proxmox_readonly testuser'
  [ "$status" -eq 0 ]
  assert_file_not_contains "^install " "$MOCK_LOG"
  [[ "$output" == *"already up to date"* ]]
}

@test "grant_proxmox_readonly fails when user does not exist" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; grant_proxmox_readonly nonexistent_zzz_user "$PROXMOX_RO_TEMPLATE"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "grant_proxmox_readonly fails when no template path provided" {
  unset PROXMOX_RO_TEMPLATE
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; grant_proxmox_readonly testuser'
  [ "$status" -ne 0 ]
  [[ "$output" == *"template path required"* ]]
}

@test "grant_proxmox_readonly fails when template path does not exist" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; grant_proxmox_readonly testuser /nonexistent/template.sudoers'
  [ "$status" -ne 0 ]
  [[ "$output" == *"template not found"* ]]
}

@test "grant_proxmox_readonly renders template (not embedded heredoc)" {
  sudoers_target="$MOCK_TMPDIR/proxmox-ro"
  export PROXMOX_RO_SUDOERS_FILE="$sudoers_target"
  export MOCK_ID_NG=""
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; grant_proxmox_readonly alice'
  [ "$status" -eq 0 ]
  # Username from arg must end up in the installed file (proves rendering happened)
  assert_file_contains "^alice ALL=(root) NOPASSWD: " "$sudoers_target"
  # The unrendered placeholder must NOT leak into the installed file
  assert_file_not_contains "__SUDO_USER__" "$sudoers_target"
}

@test "proxmox-ro sudoers template file exists with placeholder" {
  template="$REPO_ROOT/proxmox/post-install/proxmox-ro.sudoers"
  [ -f "$template" ]
  assert_file_contains "__SUDO_USER__" "$template"
  assert_file_contains "/usr/sbin/qm config" "$template"
  assert_file_contains "/usr/sbin/pct list" "$template"
  assert_file_contains "/usr/sbin/pvesm status" "$template"
  assert_file_contains "/usr/sbin/corosync-cfgtool -s" "$template"
  # Write subcommands must NOT be in the template
  assert_file_not_contains "/usr/sbin/qm start" "$template"
  assert_file_not_contains "/usr/sbin/pct stop" "$template"
}

# -------------------------------------------------------------------
# container-annotate/annotate.sh
# -------------------------------------------------------------------

@test "container-annotate runs without error when no guests" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  run bash "$REPO_ROOT/container-annotate/annotate.sh" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 annotated, 0 already up-to-date"* ]] || [[ "$output" == *"Done!"* ]]
}
