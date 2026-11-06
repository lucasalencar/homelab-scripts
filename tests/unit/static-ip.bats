#!/usr/bin/env bats

# Unit tests for ensure_static_ip (common/functions.sh).

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

# -------------------------------------------------------------------
# ensure_static_ip
# -------------------------------------------------------------------

@test "ensure_static_ip is a no-op when net0 already matches" {
  export MOCK_PCT_CONFIG="hostname: adguard
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:A7:E4:E5,ip=192.168.31.22/24,gw=192.168.31.1"
  export MOCK_PCT_STATUS="status: running"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; ensure_static_ip 103 192.168.31.22/24 192.168.31.1'
  [ "$status" -eq 0 ]
  # Nonsense guard so the negative assertions below mean something
  /usr/bin/grep -q "^pct config 103" "$MOCK_LOG"
  ! /usr/bin/grep -q "^pct stop" "$MOCK_LOG"
  ! /usr/bin/grep -q "^pct set" "$MOCK_LOG"
  ! /usr/bin/grep -q "^pct start" "$MOCK_LOG"
}

@test "ensure_static_ip converts dhcp net0 preserving bridge hwaddr firewall" {
  export MOCK_PCT_CONFIG="hostname: adguard
net0: name=eth0,bridge=vmbr0,firewall=1,hwaddr=BC:24:11:A7:E4:E5,ip=dhcp,type=veth"
  export MOCK_PCT_STATUS="status: running"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; ensure_static_ip 103 192.168.31.22/24 192.168.31.1'
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "^pct stop 103" "$MOCK_LOG"
  /usr/bin/grep -q "^pct set 103 -net0 name=eth0,bridge=vmbr0,firewall=1,hwaddr=BC:24:11:A7:E4:E5,ip=192.168.31.22/24,gw=192.168.31.1" "$MOCK_LOG"
  /usr/bin/grep -q "^pct start 103" "$MOCK_LOG"
  # type=veth must never be passed back to pct set
  ! /usr/bin/grep -q "type=veth" "$MOCK_LOG"
}

@test "ensure_static_ip rejects invalid CIDR without touching pct" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; ensure_static_ip 103 999.1.1.1/24 192.168.31.1'
  [ "$status" -ne 0 ]
  ! /usr/bin/grep -q "^pct stop" "$MOCK_LOG"
  ! /usr/bin/grep -q "^pct set" "$MOCK_LOG"
}

@test "ensure_static_ip fails when net0 is missing" {
  export MOCK_PCT_CONFIG="hostname: adguard
cores: 1"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; ensure_static_ip 103 192.168.31.22/24 192.168.31.1'
  [ "$status" -ne 0 ]
  ! /usr/bin/grep -q "^pct set" "$MOCK_LOG"
}

@test "ensure_static_ip restarts container when pct set fails" {
  export MOCK_PCT_CONFIG="hostname: adguard
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:A7:E4:E5,ip=dhcp"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_PCT_SET_FAIL=1
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; ensure_static_ip 103 192.168.31.22/24 192.168.31.1'
  [ "$status" -ne 0 ]
  /usr/bin/grep -q "^pct start 103" "$MOCK_LOG"
}

@test "ensure_static_ip only sets when container is stopped" {
  export MOCK_PCT_CONFIG="hostname: adguard
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:A7:E4:E5,ip=dhcp"
  export MOCK_PCT_STATUS="status: stopped"
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; ensure_static_ip 103 192.168.31.22/24 192.168.31.1'
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "^pct set 103 -net0" "$MOCK_LOG"
  ! /usr/bin/grep -q "^pct stop" "$MOCK_LOG"
  ! /usr/bin/grep -q "^pct start" "$MOCK_LOG"
}
