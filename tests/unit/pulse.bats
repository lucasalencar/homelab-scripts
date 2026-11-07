#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  export MOCK_PVESM_STATUS=$'local             dir     active\nlocal-lvm         lvmthin active'
  export MOCK_IP_LINK_SHOW=$'2: vmbr0: <BROADCAST>'
  export MOCK_PVEAM_AVAILABLE_SYSTEM=$'system debian-13-standard_13.0-1_amd64.tar.zst'
  export MOCK_PVEAM_LIST="local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
  export MOCK_PVESH_NEXTID="107"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.7"
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

# -------------------------------------------------------------------
# pulse/install.sh — container creation + provision
# -------------------------------------------------------------------

@test "pulse install creates new container with expected resources" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"
  export MOCK_PCT_CONFIG="hostname: test"

  run bash "$REPO_ROOT/pulse/install.sh" 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "pct create 107" "$MOCK_LOG"
  /usr/bin/grep -q -- "--hostname pulse" "$MOCK_LOG"
  /usr/bin/grep -q -- "--memory 2048" "$MOCK_LOG"
}

@test "pulse install pushes provision script and reports port 7655" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"
  export MOCK_PCT_CONFIG="hostname: test"

  run bash "$REPO_ROOT/pulse/install.sh" 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "pct push 107.*container/provision.sh" "$MOCK_LOG"
  /usr/bin/grep -q "pct exec 107 -- bash /tmp/provision.sh" "$MOCK_LOG"
  [[ "$output" == *"7655"* ]]
}

@test "pulse install reuses existing container and still provisions" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n107        running                 pulse'
  export MOCK_PCT_CONFIG="hostname: pulse"

  run bash "$REPO_ROOT/pulse/install.sh" 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "pct push 107.*provision.sh" "$MOCK_LOG"
  [[ "$output" == *"reusing"* ]] || [[ "$output" == *"Found existing"* ]]
}

@test "pulse install fails when provision push fails" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n107        running                 pulse'
  export MOCK_PCT_CONFIG="hostname: pulse"
  export MOCK_PCT_PUSH_FAIL=1

  run bash "$REPO_ROOT/pulse/install.sh" 2>&1
  [ "$status" -ne 0 ]
}

# -------------------------------------------------------------------
# pulse/update.sh — pushes container update script
# -------------------------------------------------------------------

@test "pulse update pushes update script and succeeds" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n107        running                 pulse'
  export MOCK_PCT_CONFIG="hostname: pulse"

  run bash "$REPO_ROOT/pulse/update.sh" 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "pct push 107.*container/update.sh" "$MOCK_LOG"
  /usr/bin/grep -q "pct exec 107 -- bash /tmp/update.sh" "$MOCK_LOG"
}

@test "pulse update fails when container not found" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"

  run bash "$REPO_ROOT/pulse/update.sh" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"Could not find container"* ]]
}

# -------------------------------------------------------------------
# pulse/container scripts — static checks (no pct)
# -------------------------------------------------------------------

@test "pulse container provision installs docker and runs pulse on 7655" {
  /usr/bin/grep -q "docker" "$REPO_ROOT/pulse/container/provision.sh"
  /usr/bin/grep -q "rcourtman/pulse" "$REPO_ROOT/pulse/container/provision.sh"
  /usr/bin/grep -q "7655" "$REPO_ROOT/pulse/container/provision.sh"
  /usr/bin/grep -q "docker compose" "$REPO_ROOT/pulse/container/provision.sh"
  run bash -n "$REPO_ROOT/pulse/container/provision.sh"
  [ "$status" -eq 0 ]
}

@test "pulse container update pulls and recreates pulse" {
  /usr/bin/grep -q "rcourtman/pulse\|docker compose" "$REPO_ROOT/pulse/container/update.sh"
  /usr/bin/grep -q "pull" "$REPO_ROOT/pulse/container/update.sh"
  run bash -n "$REPO_ROOT/pulse/container/update.sh"
  [ "$status" -eq 0 ]
}

@test "pulse README documents port, Caddy and PVE token setup" {
  /usr/bin/grep -q "7655" "$REPO_ROOT/pulse/README.md"
  /usr/bin/grep -qi "caddy" "$REPO_ROOT/pulse/README.md"
  /usr/bin/grep -qi "PVEAuditor\|API token" "$REPO_ROOT/pulse/README.md"
  /usr/bin/grep -q "pulse/install.sh" "$REPO_ROOT/pulse/README.md"
  /usr/bin/grep -q "pulse/update.sh" "$REPO_ROOT/pulse/README.md"
}
