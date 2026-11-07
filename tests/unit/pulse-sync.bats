#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  export HOME="$MOCK_TMPDIR/home"
  /bin/mkdir -p "$HOME"
  export PULSE_API_TOKEN="test-token-123"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n107        running                 pulse\n100        running                 caddy\n101        stopped                 jellyfin'
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  home-assistant       running    4096              32.00 12345\n201  gaming               stopped    8192              64.00 -'
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.1.20"
  export MOCK_QM_GUEST_HOSTNAME_I="192.168.1.30"
  export MOCK_PULSE_TARGETS="[]"
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

@test "sync-ping-availability prints usage with --help" {
  run bash "$REPO_ROOT/pulse/sync-ping-availability.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "sync-ping-availability fails without a token" {
  unset PULSE_API_TOKEN
  unset PULSE_API_TOKEN_FILE
  run bash "$REPO_ROOT/pulse/sync-ping-availability.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PULSE_API_TOKEN"* ]]
}

@test "sync-ping-availability dry-run plans pings for running guests only" {
  run bash "$REPO_ROOT/pulse/sync-ping-availability.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"ping-caddy"* ]]
  [[ "$output" == *"ping-home-assistant"* ]]
  [[ "$output" != *"ping-jellyfin"* ]]
  [[ "$output" != *"ping-gaming"* ]]
  [[ "$output" != *"ping-pulse"* ]]
}

@test "sync-ping-availability creates missing targets" {
  run bash "$REPO_ROOT/pulse/sync-ping-availability.sh"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "POST" "$MOCK_LOG"
  /usr/bin/grep -q "ping-caddy" "$MOCK_LOG"
  /usr/bin/grep -q "192.168.1.20" "$MOCK_LOG"
  /usr/bin/grep -q "ping-home-assistant" "$MOCK_LOG"
  /usr/bin/grep -q "192.168.1.30" "$MOCK_LOG"
}

@test "sync-ping-availability skips up-to-date targets" {
  export MOCK_PULSE_TARGETS='[{"id":"t1","name":"ping-caddy","address":"192.168.1.20","protocol":"icmp","enabled":true},{"id":"t2","name":"ping-home-assistant","address":"192.168.1.30","protocol":"icmp","enabled":true}]'
  run bash "$REPO_ROOT/pulse/sync-ping-availability.sh"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q "POST" "$MOCK_LOG"
  [ "$status" -ne 0 ]
  run /usr/bin/grep -q "PUT" "$MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "sync-ping-availability updates stale addresses via PUT" {
  export MOCK_PULSE_TARGETS='[{"id":"t1","name":"ping-caddy","address":"9.9.9.9","protocol":"icmp","enabled":true}]'
  run bash "$REPO_ROOT/pulse/sync-ping-availability.sh"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "PUT" "$MOCK_LOG"
  /usr/bin/grep -q "192.168.1.20" "$MOCK_LOG"
}

@test "sync-ping-availability prunes orphan prefixed targets only with --prune" {
  export MOCK_PULSE_TARGETS='[{"id":"t9","name":"ping-oldbox","address":"192.168.1.99","protocol":"icmp","enabled":true},{"id":"t8","name":"manual-router","address":"192.168.1.1","protocol":"icmp","enabled":true}]'
  run bash "$REPO_ROOT/pulse/sync-ping-availability.sh"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q "DELETE" "$MOCK_LOG"
  [ "$status" -ne 0 ]

  : > "$MOCK_LOG"
  run bash "$REPO_ROOT/pulse/sync-ping-availability.sh" --prune
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "DELETE" "$MOCK_LOG"
  /usr/bin/grep -q "t9" "$MOCK_LOG"
  run /usr/bin/grep -q "t8" "$MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "sync-ping-availability never logs the API token" {
  run bash "$REPO_ROOT/pulse/sync-ping-availability.sh"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q "test-token-123" "$MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "sync-ping-availability supports --only ct to skip VMs" {
  run bash "$REPO_ROOT/pulse/sync-ping-availability.sh" --dry-run --only ct
  [ "$status" -eq 0 ]
  [[ "$output" == *"ping-caddy"* ]]
  [[ "$output" != *"ping-home-assistant"* ]]
}
