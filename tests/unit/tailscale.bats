#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  export MOCK_PVESH_NEXTID="110"
  export TAILSCALE_LXC_CONF_DIR="$MOCK_TMPDIR/lxc"
  unset TAILSCALE_AUTHKEY
  unset TAILSCALE_LAN_CIDR
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
  unset TAILSCALE_LXC_CONF_DIR
}

# -------------------------------------------------------------------
# tailscale/install.sh — auth key handling
# -------------------------------------------------------------------

@test "tailscale install fails fast without an auth key and creates nothing" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TAILSCALE_AUTHKEY"* ]]
  ! grep -q "pct create" "$MOCK_LOG"
}

@test "tailscale install rejects an invalid LAN CIDR" {
  export TAILSCALE_AUTHKEY="tskey-test-123"
  export TAILSCALE_LAN_CIDR="not-a-cidr"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CIDR"* ]]
}

# -------------------------------------------------------------------
# tailscale/install.sh — router provisioning
# -------------------------------------------------------------------

@test "tailscale install creates a dedicated router tagged no-auto-proxy" {
  export TAILSCALE_AUTHKEY="tskey-test-123"
  export MOCK_TAILSCALE_LOGGED_IN="0"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_PCT_CONFIG_110="hostname: tailscale-router"

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -eq 0 ]
  grep -q "pct create 110" "$MOCK_LOG"
  grep -q "tailscale-router" "$MOCK_LOG"
  grep -q "no-auto-proxy" "$MOCK_LOG"
  grep -q "advertise-routes" "$MOCK_LOG"
  [[ "$output" == *"tailscale-router"* ]]
}

@test "tailscale install advertises the detected LAN CIDR" {
  export TAILSCALE_AUTHKEY="tskey-test-123"
  export MOCK_TAILSCALE_LOGGED_IN="0"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_PCT_CONFIG_110="hostname: tailscale-router"
  export MOCK_IP_ROUTE_OUTPUT="192.168.42.0/24 dev vmbr0 proto kernel scope link src 192.168.42.5"

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -eq 0 ]
  grep -q "192.168.42.0/24" "$MOCK_LOG"
}

@test "tailscale install never logs the auth key" {
  export TAILSCALE_AUTHKEY="tskey-super-secret-xyz-999"
  export MOCK_TAILSCALE_LOGGED_IN="0"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_PCT_CONFIG_110="hostname: tailscale-router"

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -eq 0 ]
  ! grep -q "tskey-super-secret-xyz-999" "$MOCK_LOG"
  ! grep -q "tskey-super-secret-xyz-999" <<< "$output"
}

@test "tailscale install reuses the existing router without recreating it" {
  export TAILSCALE_AUTHKEY="tskey-test-123"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n110        running                 tailscale-router'
  export MOCK_PCT_CONFIG_110="hostname: tailscale-router"

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -eq 0 ]
  ! grep -q "pct create" "$MOCK_LOG"
  grep -q "pct exec 110" "$MOCK_LOG"
  [[ "$output" == *"eus"* ]] || [[ "$output" == *"reusing"* ]] || [[ "$output" == *"110"* ]]
}

@test "tailscale install ensures TUN passthrough idempotently" {
  export TAILSCALE_AUTHKEY="tskey-test-123"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n110        running                 tailscale-router'
  export MOCK_PCT_CONFIG_110="hostname: tailscale-router"

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -eq 0 ]
  conf="$TAILSCALE_LXC_CONF_DIR/110.conf"
  [ -f "$conf" ]
  [ "$(grep -c "lxc.cgroup2.devices.allow: c 10:200 rwm" "$conf")" -eq 1 ]
  [ "$(grep -c "lxc.mount.entry: /dev/net/tun" "$conf")" -eq 1 ]

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c "lxc.cgroup2.devices.allow: c 10:200 rwm" "$conf")" -eq 1 ]
  [ "$(grep -c "lxc.mount.entry: /dev/net/tun" "$conf")" -eq 1 ]
}

# -------------------------------------------------------------------
# tailscale/update.sh
# -------------------------------------------------------------------

@test "tailscale update fails when the router is missing" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'

  run bash "$REPO_ROOT/tailscale/update.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tailscale-router"* ]]
}

@test "tailscale update upgrades tailscale and re-asserts routes" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n110        running                 tailscale-router'
  export MOCK_PCT_CONFIG_110="hostname: tailscale-router"

  run bash "$REPO_ROOT/tailscale/update.sh"
  [ "$status" -eq 0 ]
  grep -q "pct exec 110" "$MOCK_LOG"
  grep -q "tailscale" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# tailscale/README.md — operator contract
# -------------------------------------------------------------------

@test "tailscale README documents auth key, no-auto-proxy, and manual console steps" {
  grep -q "TAILSCALE_AUTHKEY" "$REPO_ROOT/tailscale/README.md"
  grep -q "no-auto-proxy" "$REPO_ROOT/tailscale/README.md"
  grep -q "generate-caddyfile" "$REPO_ROOT/tailscale/README.md"
  grep -q "approve" "$REPO_ROOT/tailscale/README.md"
}
