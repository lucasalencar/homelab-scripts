#!/usr/bin/env bats
# The usernames in .server_users are real people. They must never leak into
# committed content: the file itself stays gitignored, and no tracked file
# may hardcode those names (resolve via get_primary_user/get_all_users or
# use <user> placeholders). System accounts owned by a service and test
# fixtures are not people and are exempt.

setup() {
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "committed files contain no .server_users username" {
  if [ ! -f "$REPO_ROOT/.server_users" ]; then
    skip ".server_users absent (e.g. CI)"
  fi
  failures=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    hits=$(git -C "$REPO_ROOT" grep -l --fixed-strings -- "$name" -- . ':!tests' ':!.server_users' || true)
    if [ -n "$hits" ]; then
      failures="$failures
  '$name' found in:
  $hits"
    fi
  done < "$REPO_ROOT/.server_users"
  if [ -n "$failures" ]; then
    echo "FAIL (.server_users username leaked):$failures" >&2
    return 1
  fi
}

@test "no hardcoded personal usernames in /home paths" {
  allow="^(qbittorrent|jellyfin|sonarr|radarr|prowlarr|bazarr|flaresolverr|casaos)$"
  failures=""
  while IFS= read -r match; do
    path="${match#*:*:}"
    name=$(printf '%s' "$path" | grep -o '/home/[a-z0-9][a-z0-9_-]*' | head -1 | cut -d/ -f3)
    if ! [[ "$name" =~ $allow ]]; then
      failures="$failures
  $match"
    fi
  done < <(grep -rnE --include='*.sh' --include='*.md' --include='*.py' --include='*.example' -e '/home/[a-z0-9][a-z0-9_-]*/' "$REPO_ROOT" | grep -v '/tests/' | grep -v '\.git:' || true)
  if [ -n "$failures" ]; then
    echo "FAIL (hardcoded username in /home path):$failures" >&2
    return 1
  fi
}
