#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.7"
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

# -------------------------------------------------------------------
# pulse/install.sh — delegates to the community-scripts installer
# -------------------------------------------------------------------

COMMUNITY_CT="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/pulse.sh"

@test "pulse install delegates container creation to the community script" {
  # Fresh creation runs the external installer, which the mock harness
  # cannot simulate — pin the delegation contract statically, then
  # exercise the runtime path with an existing container.
  /usr/bin/grep -q -- "$COMMUNITY_CT" "$REPO_ROOT/pulse/install.sh"
  /usr/bin/grep -q 'ensure_container_installed "pulse"' "$REPO_ROOT/pulse/install.sh"

  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n107        running                 pulse'
  run bash "$REPO_ROOT/pulse/install.sh" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"7655"* ]]
}

@test "pulse install reuses existing container" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n107        running                 pulse'

  run bash "$REPO_ROOT/pulse/install.sh" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"107"* ]]
}

@test "pulse install has no vendored in-container provisioning" {
  [ ! -d "$REPO_ROOT/pulse/container" ]
  run /usr/bin/grep -r "docker compose" "$REPO_ROOT/pulse/" || [ "$status" -ne 0 ]
}

# -------------------------------------------------------------------
# pulse/lib.sh — unprivileged ICMP for the pulse user
# -------------------------------------------------------------------

@test "configure_pulse_unprivileged_ping writes sysctl conf and applies live" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; source "$REPO_ROOT/pulse/lib.sh"; configure_pulse_unprivileged_ping 110'
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "99-pulse-unprivileged-ping.conf" "$MOCK_LOG"
  /usr/bin/grep -q "sysctl" "$MOCK_LOG"
}

@test "configure_pulse_unprivileged_ping is idempotent when already configured" {
  export MOCK_PCT_EXEC_SYSCTL_CONF="net.ipv4.ping_group_range = 0 991"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; source "$REPO_ROOT/pulse/lib.sh"; configure_pulse_unprivileged_ping 110'
  [ "$status" -eq 0 ]
  run /usr/bin/grep -q "printf" "$MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "configure_pulse_unprivileged_ping fails when pulse user is missing" {
  export MOCK_PCT_EXEC_ID_G_pulse=""
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; source "$REPO_ROOT/pulse/lib.sh"; configure_pulse_unprivileged_ping 110'
  [ "$status" -ne 0 ]
  [[ "$output" == *"pulse"* ]]
}

@test "pulse install enables unprivileged ICMP after container is ready" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n107        running                 pulse'

  run bash "$REPO_ROOT/pulse/install.sh" 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "ping_group_range" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# pulse/update.sh — re-runs the community script (in-place update)
# -------------------------------------------------------------------

@test "pulse update re-runs the community script when container exists" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n107        running                 pulse'

  run bash "$REPO_ROOT/pulse/update.sh" 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q -- "$COMMUNITY_CT" "$REPO_ROOT/pulse/update.sh"
}

@test "pulse update fails when container not found" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"

  run bash "$REPO_ROOT/pulse/update.sh" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not find container"* ]]
}

# -------------------------------------------------------------------
# pulse/lib.sh — Pulse API helpers (shared by pulse/ and starr/ sync scripts)
# -------------------------------------------------------------------

@test "pulse_api_base prints base URL from discovered container IP" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n107        running                 pulse'
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.7"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; source "$REPO_ROOT/pulse/lib.sh"; pulse_api_base'
  [ "$status" -eq 0 ]
  [ "$output" = "http://10.0.0.7:7655" ]
}

@test "pulse_api_base fails when pulse container is missing" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; source "$REPO_ROOT/pulse/lib.sh"; pulse_api_base'
  [ "$status" -ne 0 ]
}

@test "pulse_api_header writes token to a 0600 file, never argv" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; source "$REPO_ROOT/pulse/lib.sh"; pulse_api_header "tok-abc"'
  [ "$status" -eq 0 ]
  header="$output"
  [ "$(/usr/bin/stat -c %a "$header")" = "600" ]
  /usr/bin/grep -q "tok-abc" "$header"
  run /usr/bin/grep -q "tok-abc" "$MOCK_LOG"
  [ "$status" -ne 0 ]
  rm -f "$header"
}

@test "pulse_availability_list normalizes bare array and targets object" {
  export MOCK_PULSE_TARGETS='[{"id":"t1","name":"a","address":"1.1.1.1"}]'
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; source "$REPO_ROOT/pulse/lib.sh"; pulse_availability_list "http://x:7655" "$MOCK_TMPDIR/h"'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"t1"'* ]]
  export MOCK_PULSE_TARGETS='{"targets": [{"id":"t2","name":"b","address":"2.2.2.2"}]}'
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; source "$REPO_ROOT/pulse/lib.sh"; pulse_availability_list "http://x:7655" "$MOCK_TMPDIR/h"'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"t2"'* ]]
}

@test "pulse_availability_payload includes port for tcp, omits for icmp" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; source "$REPO_ROOT/pulse/lib.sh"; pulse_availability_payload "svc-sonarr" "10.0.0.5" "tcp" "8989" 60 2000 2'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"port":8989'* ]]
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; source "$REPO_ROOT/pulse/lib.sh"; pulse_availability_payload "ping-x" "10.0.0.5" "icmp" "" 60 2000 2'
  [ "$status" -eq 0 ]
  [[ "$output" != *'"port"'* ]]
  [[ "$output" == *'"protocol":"icmp"'* ]]
}

# -------------------------------------------------------------------
# pulse/README.md
# -------------------------------------------------------------------

@test "pulse README documents port, Caddy, PVE token setup and scripts" {
  /usr/bin/grep -q "7655" "$REPO_ROOT/pulse/README.md"
  /usr/bin/grep -qi "caddy" "$REPO_ROOT/pulse/README.md"
  /usr/bin/grep -qi "PVEAuditor\|API token" "$REPO_ROOT/pulse/README.md"
  /usr/bin/grep -q "pulse/update.sh" "$REPO_ROOT/pulse/README.md"
}
