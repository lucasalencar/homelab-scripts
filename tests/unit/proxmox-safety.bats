#!/usr/bin/env bats
# Safety contract for proxmox/ scripts (see LEARNINGS.md).
#
# Incident: a broken `source .../common/functions.sh` path did not abort the
# script — `require_root`/`log_*` then failed as "command not found" while the
# script kept executing privileged steps. These tests lock in three layers:
#   1. fail-fast import  (`source ... || exit`)
#   2. strict mode       (`set -euo pipefail`-style errexit)
#   3. helpers used only after the import line
# Plus dynamic proof that a broken import dies before any side effect, and
# that require_root genuinely aborts when not root.

setup() {
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export STUB_LOG="$MOCK_TMPDIR/stub.log"
  export MOCK_DIR="$REPO_ROOT/tests/helpers/mocks"
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

_guarded_scripts() {
  grep -rl 'common/functions\.sh' "$REPO_ROOT" --include='*.sh' | grep -v '/tests/'
}

@test "scripts abort when the functions.sh import fails" {
  failures=""
  while IFS= read -r f; do
    line=$(grep -m1 '^[^#]*source.*common/functions\.sh' "$f")
    case "$line" in
      *'||'*) ;;
      *) failures="$failures
  $f: $line" ;;
    esac
  done < <(_guarded_scripts)
  if [ -n "$failures" ]; then
    echo "FAIL (no fail-fast guard):$failures" >&2
    return 1
  fi
}

@test "scripts run with errexit (set -e family)" {
  failures=""
  while IFS= read -r f; do
    if ! grep -qE '^set +-[a-z]*e' "$f" && ! grep -q 'set +-o +errexit' "$f"; then
      failures="$failures
  $f"
    fi
  done < <(_guarded_scripts)
  if [ -n "$failures" ]; then
    echo "FAIL (no errexit):$failures" >&2
    return 1
  fi
}

@test "scripts use helpers only after sourcing functions.sh" {
  failures=""
  while IFS= read -r f; do
    src=$(grep -n -m1 '^[^#]*source.*common/functions\.sh' "$f" | cut -d: -f1)
    first_use=$(awk '!/^[[:space:]]*#/ && /\<(log_step|log_info|log_success|log_warning|log_error|require_root|require_non_root)\>/ {print NR; exit}' "$f")
    if [ -z "$src" ]; then
      failures="$failures
  $f: no source line"
    elif [ -n "$first_use" ] && [ "$first_use" -lt "$src" ]; then
      failures="$failures
  $f: helper used at line $first_use, sourced at line $src"
    fi
  done < <(_guarded_scripts)
  if [ -n "$failures" ]; then
    echo "FAIL (helper before import):$failures" >&2
    return 1
  fi
}

@test "require_root aborts when not root (real logic, no test bypass)" {
  [ "$(id -u)" -eq 0 ] && skip "must run as non-root"
  run env -u BATS_TEST_TMPDIR bash -c 'source "$REPO_ROOT/common/functions.sh"; require_root'
  [ "$status" -ne 0 ]
}

@test "require_root is a no-op under the bats bypass (documents test blind spot)" {
  run bash -c 'source "$REPO_ROOT/common/functions.sh"; require_root'
  [ "$status" -eq 0 ]
}

@test "a broken functions.sh import dies before any side effect" {
  export HOME="$MOCK_TMPDIR/home"
  mkdir -p "$HOME/.ssh"
  stub_dir="$MOCK_TMPDIR/stubs"
  mkdir -p "$stub_dir"
  for cmd in adduser groupmod groupadd useradd update-grub ssh-keygen ssh-copy-id ssh sed apt-get guestfish systemctl docker rsync scp; do
    cat > "$stub_dir/$cmd" <<'EOF'
#!/bin/bash
echo "STUB $0 $*" >> "$STUB_LOG"
exit 0
EOF
    chmod +x "$stub_dir/$cmd"
  done

  failures=""
  while IFS= read -r f; do
    work="$MOCK_TMPDIR/work"
    mkdir -p "$work"
    cp "$f" "$work/$(basename "$f")"
    sed -i 's|common/functions\.sh|nonexistent-xyz/functions.sh|' "$work/$(basename "$f")"
    run env HOME="$HOME" PATH="$stub_dir:$MOCK_DIR:/usr/bin:/bin" \
      MOCK_LOG="$MOCK_LOG" STUB_LOG="$STUB_LOG" \
      bash "$work/$(basename "$f")" bats-dummy-arg
    if [ "$status" -eq 0 ]; then
      failures="$failures
  $f: exited 0 with broken import"
    fi
    if [ -f "$MOCK_LOG" ] && grep -qE '^(apt|curl|zfs|pct|qm|pvesh|pvesm|pveam|usermod|visudo|install|mkdir|chown|chmod|setfacl|getent|id) ' "$MOCK_LOG"; then
      failures="$failures
  $f: side-effect mocks invoked with broken import"
    fi
    if [ -s "$STUB_LOG" ]; then
      failures="$failures
  $f: privileged commands reached with broken import"
    fi
    rm -rf "$work"
    : > "$MOCK_LOG" 2>/dev/null || true
    : > "$STUB_LOG" 2>/dev/null || true
  done < <(_guarded_scripts)
  if [ -n "$failures" ]; then
    echo "FAIL (broken import not fail-fast):$failures" >&2
    return 1
  fi
}
