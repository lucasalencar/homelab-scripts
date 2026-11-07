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
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n107        running                 pulse\n105        running                 starr'
  export MOCK_PCT_EXEC_HOSTNAME_I="192.168.1.50"
  export MOCK_PCT_EXEC_SS_OUTPUT=$'LISTEN 0 128 0.0.0.0:9696 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:8989 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:7878 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:6767 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:5055 0.0.0.0:*'
  export MOCK_PULSE_TARGETS="[]"
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

@test "sync-service-availability prints usage with --help" {
  run bash "$REPO_ROOT/starr/sync-service-availability.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "sync-service-availability fails without a token" {
  unset PULSE_API_TOKEN
  unset PULSE_API_TOKEN_FILE
  run bash "$REPO_ROOT/starr/sync-service-availability.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PULSE_API_TOKEN"* ]]
}

@test "sync-service-availability dry-run plans tcp checks for the five services" {
  run bash "$REPO_ROOT/starr/sync-service-availability.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"svc-prowlarr"* ]]
  [[ "$output" == *"svc-sonarr"* ]]
  [[ "$output" == *"svc-radarr"* ]]
  [[ "$output" == *"svc-bazarr"* ]]
  [[ "$output" == *"svc-seerr"* ]]
}

@test "sync-service-availability creates tcp targets with ports" {
  run bash "$REPO_ROOT/starr/sync-service-availability.sh"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "POST" "$MOCK_LOG"
  /usr/bin/grep -q "svc-sonarr" "$MOCK_LOG"
  /usr/bin/grep -q "8989" "$MOCK_LOG"
  /usr/bin/grep -q "svc-seerr" "$MOCK_LOG"
  /usr/bin/grep -q "5055" "$MOCK_LOG"
}

@test "sync-service-availability never touches FlareSolverr loopback port" {
  run bash "$REPO_ROOT/starr/sync-service-availability.sh"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q "8191" "$MOCK_LOG"
  [ "$status" -ne 0 ]
  [[ "$output" != *"8191"* ]]
}

@test "sync-service-availability skips up-to-date targets" {
  export MOCK_PULSE_TARGETS='[{"id":"t1","name":"svc-sonarr","address":"192.168.1.50","protocol":"tcp","port":8989},{"id":"t2","name":"svc-prowlarr","address":"192.168.1.50","protocol":"tcp","port":9696},{"id":"t3","name":"svc-radarr","address":"192.168.1.50","protocol":"tcp","port":7878},{"id":"t4","name":"svc-bazarr","address":"192.168.1.50","protocol":"tcp","port":6767},{"id":"t5","name":"svc-seerr","address":"192.168.1.50","protocol":"tcp","port":5055}]'
  run bash "$REPO_ROOT/starr/sync-service-availability.sh"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q "POST" "$MOCK_LOG"
  [ "$status" -ne 0 ]
  run /usr/bin/grep -q "PUT" "$MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "sync-service-availability updates stale ports via PUT" {
  export MOCK_PULSE_TARGETS='[{"id":"t1","name":"svc-sonarr","address":"192.168.1.50","protocol":"tcp","port":9999}]'
  run bash "$REPO_ROOT/starr/sync-service-availability.sh"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "PUT" "$MOCK_LOG"
  /usr/bin/grep -q "t1" "$MOCK_LOG"
}

@test "sync-service-availability warns but syncs when a port is not listening" {
  export MOCK_PCT_EXEC_SS_OUTPUT=$'LISTEN 0 128 0.0.0.0:9696 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:8989 0.0.0.0:*'
  run bash "$REPO_ROOT/starr/sync-service-availability.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"6767"* ]]
  /usr/bin/grep -q "svc-bazarr" "$MOCK_LOG"
}

@test "sync-service-availability prunes orphan svc targets only with --prune" {
  export MOCK_PULSE_TARGETS='[{"id":"t9","name":"svc-oldapp","address":"192.168.1.50","protocol":"tcp","port":1234},{"id":"t8","name":"manual-router","address":"192.168.1.1","protocol":"icmp"}]'
  run bash "$REPO_ROOT/starr/sync-service-availability.sh"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q "DELETE" "$MOCK_LOG"
  [ "$status" -ne 0 ]

  : > "$MOCK_LOG"
  run bash "$REPO_ROOT/starr/sync-service-availability.sh" --prune
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "DELETE" "$MOCK_LOG"
  /usr/bin/grep -q "t9" "$MOCK_LOG"
  run /usr/bin/grep -q "t8" "$MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "sync-service-availability never logs the API token" {
  run bash "$REPO_ROOT/starr/sync-service-availability.sh"
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q "test-token-123" "$MOCK_LOG"
  [ "$status" -ne 0 ]
}
