#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BATS_TEST_TMPDIR="$MOCK_TMPDIR"
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  export SERVER_USERS_FILE="$MOCK_TMPDIR/.server_users"
  echo "testuser" > "$SERVER_USERS_FILE"
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n100  haos                 running    4096              32.00 12345'
  export MOCK_QM_STATUS="status: running"
  unset HA_TOKEN
  unset HA_TOKEN_FILE
  unset HA_URL
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

@test "home-assistant update runs core, supervisor and os updates" {
  run bash "$REPO_ROOT/home-assistant-os/update.sh" 2>&1
  [ "$status" -eq 0 ]
  grep -q "ha core update" "$MOCK_LOG"
  grep -q "ha supervisor update" "$MOCK_LOG"
  grep -q "ha os update" "$MOCK_LOG"
}

@test "home-assistant update warns and skips HACS when no token is configured" {
  run bash "$REPO_ROOT/home-assistant-os/update.sh" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"HACS"* ]]
  [[ "$output" == *"HA_TOKEN"* ]]
}
