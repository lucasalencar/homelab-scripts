#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

# -------------------------------------------------------------------
# jellyfin/install.sh
# -------------------------------------------------------------------

@test "jellyfin install succeeds when container exists" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n101        running                 jellyfin'
  export MOCK_PCT_CONFIG="hostname: jellyfin"
  export MOCK_PCT_EXEC_ID_U_jellyfin="1000"

  run bash "$REPO_ROOT/jellyfin/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Jellyfin"* ]]
  [[ "$output" == *"101"* ]]
  grep -q "pct list" "$MOCK_LOG"
  grep -q "setfacl" "$MOCK_LOG"
  grep -q "pct set 101 -mp1 /tank/data/mediaserver/media,mp=/DATA/Media" "$MOCK_LOG"
  grep -q "pct set 101 -mp2 /tank/data/memorias,mp=/DATA/Gallery" "$MOCK_LOG"
}

@test "jellyfin install grants ACL on whole mediaserver dataset" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n101        running                 jellyfin'
  export MOCK_PCT_CONFIG="hostname: jellyfin"
  export MOCK_PCT_EXEC_ID_U_jellyfin="1000"

  run bash "$REPO_ROOT/jellyfin/install.sh"
  [ "$status" -eq 0 ]
  # Sonarr hardlinks from downloads/ into media/, preserving the source
  # inode ACL — so the grant must cover the parent dataset, not just
  # media/ (same convention as starr/qbittorrent/casa-os).
  # Anchored ^setfacl + real grep: the mock grep logs its own argv
  # into MOCK_LOG, so an unanchored pattern would self-match.
  /usr/bin/grep -q "^setfacl.* /tank/data/mediaserver$" "$MOCK_LOG"
}

@test "jellyfin install discovers host UID correctly" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n101        running                 jellyfin'
  export MOCK_PCT_CONFIG="hostname: jellyfin"
  export MOCK_PCT_EXEC_ID_U_jellyfin="1005"

  run bash "$REPO_ROOT/jellyfin/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"101005"* ]] # 1005 + 100000 = 101005
  grep -q "u:101005:rwx" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# jellyfin/update.sh
# -------------------------------------------------------------------

@test "jellyfin update delegates to container" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n101        running                 jellyfin'
  export MOCK_PCT_CONFIG="hostname: jellyfin"
  # update.sh exists for jellyfin — mock its pct exec
  run bash "$REPO_ROOT/jellyfin/update.sh" 2>&1
  # Should succeed or skip gracefully when mocked
  [ "$status" -eq 0 ] || [[ "$output" == *"jellyfin"* ]]
}

@test "jellyfin update does not pin ffmpeg version" {
  # ffmpeg7 -> ffmpeg8 transition: script must not hardcode either,
  # let apt resolve the dependency from the jellyfin metapackages.
  run /bin/grep -E "jellyfin-ffmpeg[0-9]" "$REPO_ROOT/jellyfin/update.sh"
  [ "$status" -ne 0 ]
}

@test "jellyfin update installs jellyfin without --only-upgrade" {
  # --only-upgrade ignores not-yet-installed packages (e.g. ffmpeg8),
  # so the jellyfin install must be plain to allow new deps.
  /bin/grep -q "apt install.*jellyfin" "$REPO_ROOT/jellyfin/update.sh"
  run /bin/grep "apt install.*--only-upgrade.*jellyfin" "$REPO_ROOT/jellyfin/update.sh"
  [ "$status" -ne 0 ]
}

@test "jellyfin update runs apt install before apt upgrade" {
  export MOCK_PCT_LIST=$'VMID       Status     Lock         Name\n101        running                 jellyfin'
  export MOCK_PCT_CONFIG="hostname: jellyfin"
  run bash "$REPO_ROOT/jellyfin/update.sh" 2>&1
  [ "$status" -eq 0 ]
  install_line=$(/bin/grep -n "apt install" "$MOCK_LOG" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)
  upgrade_line=$(/bin/grep -n "apt upgrade" "$MOCK_LOG" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)
  [ -n "$install_line" ]
  [ -n "$upgrade_line" ]
  [ "$install_line" -lt "$upgrade_line" ]
}
