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
  unset TAILSCALE_ROUTER_NAME
  unset TAILSCALE_DNS_IP
  unset TAILSCALE_DNS_ZONE
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
  unset TAILSCALE_LXC_CONF_DIR
}

# -------------------------------------------------------------------
# tailscale/install.sh — auth key handling
# -------------------------------------------------------------------

@test "tailscale install fails fast without an auth key when not logged in" {
  export MOCK_TAILSCALE_LOGGED_IN="0"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TAILSCALE_AUTHKEY"* ]]
  ! grep -q "pct create" "$MOCK_LOG"
}

@test "tailscale install skips login when already logged in" {
  export TAILSCALE_AUTHKEY="tskey-test-123"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n110        running                 tailscale-router'
  export MOCK_PCT_CONFIG_110="hostname: tailscale-router"

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -eq 0 ]
  ! grep -q "tailscale up" "$MOCK_LOG"
  grep -q "tailscale set --advertise-routes=" "$MOCK_LOG"
}

@test "tailscale install warns when a key is provided but unused" {
  export TAILSCALE_AUTHKEY="tskey-test-123"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n110        running                 tailscale-router'
  export MOCK_PCT_CONFIG_110="hostname: tailscale-router"

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unused"* ]]
}

@test "tailscale install rejects invalid LAN CIDRs" {
  export TAILSCALE_AUTHKEY="tskey-test-123"
  export MOCK_TAILSCALE_LOGGED_IN="0"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'

  for bad in "not-a-cidr" "999.999.0.0/24" "192.168.1.0/33" "0.0.0.0/0" "192.168.1.1" "192.168.001.0/24"; do
    export TAILSCALE_LAN_CIDR="$bad"
    run bash "$REPO_ROOT/tailscale/install.sh"
    [ "$status" -ne 0 ]
  done
}

@test "tailscale install fails when the LAN CIDR is undetectable" {
  export TAILSCALE_AUTHKEY="tskey-test-123"
  export MOCK_TAILSCALE_LOGGED_IN="0"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_IP_ROUTE_OUTPUT=""

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TAILSCALE_LAN_CIDR"* ]]
  ! grep -q "pct create" "$MOCK_LOG"
}

@test "tailscale install fails on ambiguous routes instead of guessing" {
  export TAILSCALE_AUTHKEY="tskey-test-123"
  export MOCK_TAILSCALE_LOGGED_IN="0"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_IP_ROUTE_OUTPUT=$'192.168.15.0/24 dev vmbr0 proto kernel scope link src 192.168.15.5\n10.42.0.0/24 dev vmbr0 proto kernel scope link src 10.42.0.5'

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"explicit"* ]]
}

@test "tailscale install fails on duplicate router names instead of cloning" {
  export TAILSCALE_AUTHKEY="tskey-test-123"
  export MOCK_TAILSCALE_LOGGED_IN="0"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n110        running                 tailscale-router\n111        running                 tailscale-router'

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Multiple"* ]]
  ! grep -q "pct create" "$MOCK_LOG"
}

@test "tailscale install fails cleanly when tailscale up fails" {
  export TAILSCALE_AUTHKEY="tskey-super-secret-xyz-999"
  export MOCK_TAILSCALE_LOGGED_IN="0"
  export MOCK_TAILSCALE_UP_FAIL="1"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tailscale up failed"* ]]
  ! grep -q "tskey-super-secret-xyz-999" "$MOCK_LOG"
  ! grep -q "tskey-super-secret-xyz-999" <<< "$output"
  grep -q "pct exec 110 -- rm -f /tmp/ts-authkey" "$MOCK_LOG"
}

@test "tailscale install requires a key for an existing router that is logged out" {
  unset TAILSCALE_AUTHKEY
  export MOCK_TAILSCALE_LOGGED_IN="0"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n110        running                 tailscale-router'
  export MOCK_PCT_CONFIG_110="hostname: tailscale-router"

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TAILSCALE_AUTHKEY"* ]]
  ! grep -q "tailscale up" "$MOCK_LOG"
}

@test "tailscale install fails on a detected but invalid route" {
  export TAILSCALE_AUTHKEY="tskey-test-123"
  export MOCK_TAILSCALE_LOGGED_IN="0"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_IP_ROUTE_OUTPUT="999.999.0.0/24 dev vmbr0 proto kernel scope link src 999.999.0.5"

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -ne 0 ]
}

@test "tailscale install hardens the pushed key and removes it" {
  export TAILSCALE_AUTHKEY="tskey-test-123"
  export MOCK_TAILSCALE_LOGGED_IN="0"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_PCT_CONFIG_110="hostname: tailscale-router"

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -eq 0 ]
  grep -q "pct exec 110 -- chmod 600 /tmp/ts-authkey" "$MOCK_LOG"
  grep -q "pct exec 110 -- rm -f /tmp/ts-authkey" "$MOCK_LOG"
}

@test "tailscale install enables IP forwarding in the router" {
  export TAILSCALE_AUTHKEY="tskey-test-123"
  export MOCK_TAILSCALE_LOGGED_IN="0"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_PCT_CONFIG_110="hostname: tailscale-router"

  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -eq 0 ]
  grep -q "sysctl -w net.ipv4.ip_forward=1" "$MOCK_LOG"
  grep -q "99-tailscale.conf" "$MOCK_LOG"
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
  grep -q "tailscale up --auth-key=file:/tmp/ts-authkey" "$MOCK_LOG"
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
  grep -q "tailscale set --advertise-routes=192.168.42.0/24" "$MOCK_LOG"
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
  [[ "$output" == *"reusing"* ]]
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
  grep -q "pct stop 110" "$MOCK_LOG"
  grep -q "pct start 110" "$MOCK_LOG"

  : > "$MOCK_LOG"
  run bash "$REPO_ROOT/tailscale/install.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c "lxc.cgroup2.devices.allow: c 10:200 rwm" "$conf")" -eq 1 ]
  [ "$(grep -c "lxc.mount.entry: /dev/net/tun" "$conf")" -eq 1 ]
  ! grep -q "pct stop 110" "$MOCK_LOG"
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

@test "tailscale update fails on duplicate router names" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n110        running                 tailscale-router\n111        running                 tailscale-router'

  run bash "$REPO_ROOT/tailscale/update.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Multiple"* ]]
}

@test "tailscale update upgrades tailscale and re-asserts routes" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n110        running                 tailscale-router'
  export MOCK_PCT_CONFIG_110="hostname: tailscale-router"

  run bash "$REPO_ROOT/tailscale/update.sh"
  [ "$status" -eq 0 ]
  grep -q "pct exec 110 -- apt install -y --only-upgrade tailscale" "$MOCK_LOG"
  grep -q "pct exec 110 -- sysctl -w net.ipv4.ip_forward=1" "$MOCK_LOG"
  grep -q "tailscale set --advertise-routes=" "$MOCK_LOG"
}

@test "tailscale update rejects the default route" {
  export TAILSCALE_LAN_CIDR="0.0.0.0/0"
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n110        running                 tailscale-router'

  run bash "$REPO_ROOT/tailscale/update.sh"
  [ "$status" -ne 0 ]
  ! grep -q "advertise-routes" "$MOCK_LOG"
}

@test "tailscale update fails when the LAN CIDR is undetectable" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n110        running                 tailscale-router'
  export MOCK_PCT_CONFIG_110="hostname: tailscale-router"
  export MOCK_IP_ROUTE_OUTPUT=""

  run bash "$REPO_ROOT/tailscale/update.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TAILSCALE_LAN_CIDR"* ]]
}

# -------------------------------------------------------------------
# validate_ipv4_cidr (common/functions.sh)
# -------------------------------------------------------------------

@test "validate_ipv4_cidr accepts valid and rejects invalid CIDRs" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; validate_ipv4_cidr "192.168.15.0/24"'
  [ "$status" -eq 0 ]
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; validate_ipv4_cidr "10.0.0.0/8"'
  [ "$status" -eq 0 ]
  for bad in "" "not-a-cidr" "999.999.0.0/24" "192.168.1.0/33" "192.168.1.1" "192.168.1.0/" "/24" "192.168.001.0/24"; do
    run bash -c 'source "$REPO_ROOT/common/functions.sh"; validate_ipv4_cidr "$0"' "$bad"
    [ "$status" -ne 0 ]
  done
}

# -------------------------------------------------------------------
# tailscale/README.md — operator contract
# -------------------------------------------------------------------

@test "tailscale README documents auth key, no-auto-proxy, and manual console steps" {
  grep -q "TAILSCALE_AUTHKEY" "$REPO_ROOT/tailscale/README.md"
  grep -q "no-auto-proxy" "$REPO_ROOT/tailscale/README.md"
  grep -q "generate-caddyfile" "$REPO_ROOT/tailscale/README.md"
  grep -q "approve" "$REPO_ROOT/tailscale/README.md"
  grep -q "TAILSCALE_ROUTER_NAME" "$REPO_ROOT/tailscale/README.md"
}
