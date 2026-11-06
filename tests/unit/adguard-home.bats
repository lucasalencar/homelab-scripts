#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

# -------------------------------------------------------------------
# adguard-home/install.sh
# -------------------------------------------------------------------

@test "adguard install pins its own static IP" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n103        running                 adguard'
  export MOCK_PCT_CONFIG="hostname: adguard
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:A7:E4:E5,ip=dhcp"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.31.22"

  # setup-upstream.sh needs an interactive AdGuard login, so a full mocked
  # install cannot exit 0 — assert the pin, which runs before that stage.
  run bash "$REPO_ROOT/adguard-home/install.sh" 2>&1
  grep -q "^pct set 103 -net0 .*ip=192.168.31.22/24,gw=192.168.31.1" "$MOCK_LOG"
}

@test "adguard install honors ADGUARD_STATIC_IP override" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n103        running                 adguard'
  export MOCK_PCT_CONFIG="hostname: adguard
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:A7:E4:E5,ip=dhcp"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.31.22"
  export ADGUARD_STATIC_IP="192.168.31.23/24"

  run bash "$REPO_ROOT/adguard-home/install.sh" 2>&1
  grep -q "^pct set 103 -net0 .*ip=192.168.31.23/24,gw=192.168.31.1" "$MOCK_LOG"
}
