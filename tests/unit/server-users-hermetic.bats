#!/usr/bin/env bats
# The repo-root .server_users registry holds real people and must never be
# touched by tests: no creating, writing, or deleting it, not even as
# "cleanup". Tests resolve the registry exclusively through SERVER_USERS_FILE
# pointed at $MOCK_TMPDIR.

setup() {
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test ".server_users stays gitignored" {
  run git -C "$REPO_ROOT" check-ignore -q .server_users
  [ "$status" -eq 0 ]
}

@test "no test writes or deletes the real .server_users" {
  read_pattern='\[\s*!?\s*-f "\$REPO_ROOT/\.server_users" \]|done < "\$REPO_ROOT/\.server_users"|cat "\$REPO_ROOT/\.server_users"'
  failures=""
  while IFS= read -r match; do
    if ! printf '%s' "$match" | grep -qE "$read_pattern"; then
      failures="$failures
  $match"
    fi
  done < <(grep -rn --include='*.bats' --include='*.bash' -e 'REPO_ROOT/.server_users' "$REPO_ROOT/tests" | grep -v 'server-users-hermetic.bats' || true)
  if [ -n "$failures" ]; then
    echo "FAIL (test touches real .server_users):$failures" >&2
    return 1
  fi
}
