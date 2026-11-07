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
# pulse/README.md
# -------------------------------------------------------------------

@test "pulse README documents port, Caddy, PVE token setup and scripts" {
  /usr/bin/grep -q "7655" "$REPO_ROOT/pulse/README.md"
  /usr/bin/grep -qi "caddy" "$REPO_ROOT/pulse/README.md"
  /usr/bin/grep -qi "PVEAuditor\|API token" "$REPO_ROOT/pulse/README.md"
  /usr/bin/grep -q "pulse/update.sh" "$REPO_ROOT/pulse/README.md"
}
