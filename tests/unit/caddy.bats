#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  # Redirect generator outputs to per-test temp files: the real
  # Caddyfile.local/state.json are never touched (see CADDY_* overrides).
  export TEST_CADDYFILE="$MOCK_TMPDIR/Caddyfile.local"
  export TEST_STATE_JSON="$MOCK_TMPDIR/state.json"
  export CADDY_LOCAL_CADDYFILE="$TEST_CADDYFILE"
  export CADDY_STATE_FILE="$TEST_STATE_JSON"
}

teardown() {
  # Safety net: the suite must never leave fixture data in the real file
  # (tests redirect via CADDY_* overrides; this catches any bypass).
  if [ -f "$REPO_ROOT/caddy/Caddyfile.local" ] && grep -q "bats-test" "$REPO_ROOT/caddy/Caddyfile.local" 2>/dev/null; then
    rm -f "$REPO_ROOT/caddy/Caddyfile.local"
  fi
  rm -rf "$MOCK_TMPDIR"
}

# -------------------------------------------------------------------
# caddy/install.sh
# -------------------------------------------------------------------

@test "caddy install succeeds and fetches container IP" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_PCT_CONFIG="hostname: caddy"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"

  run bash "$REPO_ROOT/caddy/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Caddy"* ]]
  [[ "$output" == *"10.0.0.5"* ]]
  grep -q "pct list" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# caddy/update.sh
# -------------------------------------------------------------------

@test "caddy update delegates to container" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_PCT_CONFIG="hostname: caddy"
  run bash "$REPO_ROOT/caddy/update.sh" 2>&1
  [ "$status" -eq 0 ] || [[ "$output" == *"caddy"* ]]
}

# -------------------------------------------------------------------
# caddy/trust-nextcloud.sh — fallback nextcloudpi
# -------------------------------------------------------------------

@test "caddy trust-nextcloud falls back to nextcloudpi when nextcloud not found" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n102        running                 nextcloudpi'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_102="hostname: nextcloudpi"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  run bash "$REPO_ROOT/caddy/trust-nextcloud.sh" --caddy-ip 10.0.0.5 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"102"* ]]
  [[ "$output" == *"nextcloudpi"* ]] || [[ "$output" == *"Nextcloud container"* ]]
  grep -q "pct exec 102" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# caddy/generate-caddyfile.sh — basic
# -------------------------------------------------------------------

@test "caddy generate-caddyfile runs without error when no guests" {
  export MOCK_PCT_LIST="VMID       Status     Lock         Name"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  # Mock caddy exists
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  run bash "$REPO_ROOT/caddy/generate-caddyfile.sh" 2>&1
  # Should handle empty guest list gracefully
  [ "$status" -eq 0 ] || [[ "$output" == *"No guests"* ]] || [[ "$output" == *"Found 0"* ]]
}

# -------------------------------------------------------------------
# caddy/generate-caddyfile.sh — multi-service guests (e.g. starr CT)
# -------------------------------------------------------------------

@test "caddy generate multi-service maps each port to its own subdomain" {

  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n105        running                 starr'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_105="hostname: starr"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  export MOCK_PCT_EXEC_SS_OUTPUT=$'State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess\nLISTEN 0     128          0.0.0.0:6767      0.0.0.0:*\nLISTEN 0     128          0.0.0.0:7878      0.0.0.0:*\nLISTEN 0     128          0.0.0.0:8989      0.0.0.0:*\nLISTEN 0     128          0.0.0.0:9696      0.0.0.0:*'

  # Ports are probed sorted: 6767 7878 8989 9696 -> bazarr radarr sonarr prowlarr
  run bash -c "printf 'y\nbazarr\nn\nradarr\nn\nsonarr\nn\nprowlarr\nn\n' | bash \"$REPO_ROOT/caddy/generate-caddyfile.sh\" 2>&1"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "bazarr.marx.home" "$TEST_CADDYFILE"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:6767" "$TEST_CADDYFILE"
  /usr/bin/grep -q "radarr.marx.home" "$TEST_CADDYFILE"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:7878" "$TEST_CADDYFILE"
  /usr/bin/grep -q "sonarr.marx.home" "$TEST_CADDYFILE"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:8989" "$TEST_CADDYFILE"
  /usr/bin/grep -q "prowlarr.marx.home" "$TEST_CADDYFILE"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:9696" "$TEST_CADDYFILE"
  # Multi-mode must not also emit a single starr block
  ! /usr/bin/grep -q "starr.marx.home" "$TEST_CADDYFILE"
  # Stdout must stay pure: core prompts/logs go to stderr, never into the file
  ! /usr/bin/grep -q "Subdomain for" "$TEST_CADDYFILE"
  ! /usr/bin/grep -q "Does starr host" "$TEST_CADDYFILE"
  ! /usr/bin/grep -q "HTTPS (tls internal) for" "$TEST_CADDYFILE"
  ! /usr/bin/grep -q "Loading existing" "$TEST_CADDYFILE"
  ! /usr/bin/grep -q "✓" "$TEST_CADDYFILE"
  /usr/bin/grep -q "pct push 100" "$MOCK_LOG"
  /usr/bin/grep -q "pct exec 100" "$MOCK_LOG"

}

@test "caddy generate second run reuses state without prompting" {

  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n107        running                 jellyfin'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_107="hostname: jellyfin"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.7"
  export MOCK_PCT_EXEC_SS_OUTPUT=$'State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess\nLISTEN 0     128          0.0.0.0:8096      0.0.0.0:*'

  run bash -c "printf '\n\n' | bash \"$REPO_ROOT/caddy/generate-caddyfile.sh\" 2>&1"
  [ "$status" -eq 0 ]
  cp "$TEST_CADDYFILE" "$MOCK_TMPDIR/first.local"

  run bash "$REPO_ROOT/caddy/generate-caddyfile.sh" </dev/null 2>&1
  [ "$status" -eq 0 ]
  diff -q "$MOCK_TMPDIR/first.local" "$TEST_CADDYFILE"
  /usr/bin/grep -q "jellyfin.marx.home" "$TEST_CADDYFILE"

}

@test "caddy generate reuses saved multi-service mappings without prompting" {
  cat > "$TEST_STATE_JSON" <<'EOF'
{"version": 1, "domain": "marx.home", "entries": {
  "bazarr": {"ip": "10.0.0.5", "port": 6767, "tls": "http", "source": "auto", "guest": null},
  "radarr": {"ip": "10.0.0.5", "port": 7878, "tls": "http", "source": "auto", "guest": null},
  "sonarr": {"ip": "10.0.0.5", "port": 8989, "tls": "http", "source": "auto", "guest": null},
  "prowlarr": {"ip": "10.0.0.5", "port": 9696, "tls": "http", "source": "auto", "guest": null}
}}
EOF

  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n105        running                 starr'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_105="hostname: starr"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  export MOCK_PCT_EXEC_SS_OUTPUT=$'State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess\nLISTEN 0     128          0.0.0.0:6767      0.0.0.0:*\nLISTEN 0     128          0.0.0.0:7878      0.0.0.0:*\nLISTEN 0     128          0.0.0.0:8989      0.0.0.0:*\nLISTEN 0     128          0.0.0.0:9696      0.0.0.0:*'

  run bash "$REPO_ROOT/caddy/generate-caddyfile.sh" </dev/null 2>&1
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:6767" "$TEST_CADDYFILE"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:7878" "$TEST_CADDYFILE"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:8989" "$TEST_CADDYFILE"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:9696" "$TEST_CADDYFILE"
  ! /usr/bin/grep -q "starr.marx.home" "$TEST_CADDYFILE"

}

@test "caddy generate preserves orphan blocks not owned by any guest" {
  cat > "$TEST_STATE_JSON" <<'EOF'
{"version": 1, "domain": "marx.home", "entries": {
  "myapp": {"ip": "10.9.9.9", "port": 1234, "tls": "http", "source": "auto", "guest": "vanished"}
}}
EOF

  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n105        running                 starr'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_105="hostname: starr"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  export MOCK_PCT_EXEC_SS_OUTPUT=$'State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess\nLISTEN 0     128          0.0.0.0:8989      0.0.0.0:*'

  run bash -c "printf '\n\n' | bash \"$REPO_ROOT/caddy/generate-caddyfile.sh\" 2>&1"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "starr.marx.home" "$TEST_CADDYFILE"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:8989" "$TEST_CADDYFILE"
  /usr/bin/grep -q "myapp.marx.home" "$TEST_CADDYFILE"
  /usr/bin/grep -q "reverse_proxy 10.9.9.9:1234" "$TEST_CADDYFILE"
  [[ "$output" == *"Preserving unmanaged block myapp"* ]]
  # Preserved blocks keep no log lines in the file either
  ! /usr/bin/grep -q "Preserving unmanaged" "$TEST_CADDYFILE"
  ! /usr/bin/grep -q "Port for" "$TEST_CADDYFILE"

}

@test "caddy generate keeps single-service flow for one-port guests" {

  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n107        running                 jellyfin'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_107="hostname: jellyfin"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.7"
  export MOCK_PCT_EXEC_SS_OUTPUT=$'State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess\nLISTEN 0     128          0.0.0.0:8096      0.0.0.0:*'

  run bash -c "printf '\n\n' | bash \"$REPO_ROOT/caddy/generate-caddyfile.sh\" 2>&1"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "jellyfin.marx.home" "$TEST_CADDYFILE"
  /usr/bin/grep -q "reverse_proxy 10.0.0.7:8096" "$TEST_CADDYFILE"

}

@test "caddy generate falls back to single-service when all ports skipped" {

  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n105        running                 starr'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_105="hostname: starr"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  export MOCK_PCT_EXEC_SS_OUTPUT=$'State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess\nLISTEN 0     128          0.0.0.0:6767      0.0.0.0:*\nLISTEN 0     128          0.0.0.0:9696      0.0.0.0:*'

  # y=multi, then skip both ports, then single-service defaults (port 6767, http)
  run bash -c "printf 'y\n\n\n\n\n' | bash \"$REPO_ROOT/caddy/generate-caddyfile.sh\" 2>&1"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "starr.marx.home" "$TEST_CADDYFILE"
  /usr/bin/grep -q "reverse_proxy 10.0.0.5:6767" "$TEST_CADDYFILE"

}
@test "caddy generate shows per-guest probing progress during collection" {


  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy\n105        running                 starr'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_CONFIG_105="hostname: starr"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_QM_LIST="VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  export MOCK_PCT_EXEC_SS_OUTPUT=$'State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess\nLISTEN 0     128          0.0.0.0:8096      0.0.0.0:*'

  run bash -c "printf '\n\n' | bash \"$REPO_ROOT/caddy/generate-caddyfile.sh\" 2>&1"
  [ "$status" -eq 0 ]
  # Each probed guest is announced before its probes run, so a hang
  # points at the last announced guest instead of silent output
  [[ "$output" == *"Probing CT 105 (starr)"* ]]
  # The caddy container itself is excluded, never probed
  [[ "$output" != *"Probing CT 100"* ]]

}

@test "caddy generate warns and skips VM whose guest agent does not respond" {


  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  deadvm               running    2048              32.00 999'
  export MOCK_QM_CONFIG_200="name: deadvm"
  export MOCK_QM_GUEST_FAIL=1

  run bash "$REPO_ROOT/caddy/generate-caddyfile.sh" </dev/null 2>&1
  # A dead agent must not abort the run, and the skip must be visible
  [ "$status" -eq 0 ]
  [[ "$output" == *"Probing VM 200 (deadvm)"* ]]
  [[ "$output" == *"Skipping VM 200 (deadvm)"* ]]
  [ ! -f "$TEST_CADDYFILE" ] || ! /usr/bin/grep -q "deadvm.marx.home" "$TEST_CADDYFILE"

}

@test "caddy generate warns when port probe fails but still configures the guest" {


  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  test-vm              running    2048              32.00 999'
  export MOCK_QM_GUEST_FAIL=1

  # Default qm config mock carries ipconfig0 ip=10.0.0.10/24, so the VM is
  # collected via the ipconfig fallback even with a dead agent; the port
  # scan then fails and must warn instead of silently yielding no ports
  run bash -c "printf '\n\n' | bash \"$REPO_ROOT/caddy/generate-caddyfile.sh\" 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Probe failed for VM 200 (test-vm) port scan"* ]]
  /usr/bin/grep -q "test-vm.marx.home" "$TEST_CADDYFILE"

}

@test "caddy generate runs guest probes under CADDY_GUEST_TIMEOUT" {


  # Spy timeout: records the requested duration, then delegates to the real one
  mkdir -p "$MOCK_TMPDIR/fakebin"
  export REAL_TIMEOUT="$(command -v timeout)"
  cat > "$MOCK_TMPDIR/fakebin/timeout" <<'EOF'
#!/usr/bin/env bash
echo "TIMEOUT-DUR:$1" >> "$MOCK_LOG"
shift
exec "$REAL_TIMEOUT" "$@"
EOF
  /bin/chmod +x "$MOCK_TMPDIR/fakebin/timeout"
  export PATH="$MOCK_TMPDIR/fakebin:$PATH"

  export CADDY_GUEST_TIMEOUT=7
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n100        running                 caddy'
  export MOCK_PCT_CONFIG_100="hostname: caddy"
  export MOCK_PCT_STATUS="status: running"
  export MOCK_PCT_EXEC_HOSTNAME_I="10.0.0.5"
  export MOCK_QM_LIST=$'VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n200  test-vm              running    2048              32.00 999'
  export MOCK_QM_GUEST_HOSTNAME_I="10.0.0.10"

  run bash -c "printf '\n\n' | bash \"$REPO_ROOT/caddy/generate-caddyfile.sh\" 2>&1"
  [ "$status" -eq 0 ]
  /usr/bin/grep -q "TIMEOUT-DUR:7" "$MOCK_LOG"

}
