#!/usr/bin/env bats

setup() {
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
}

# Every script that sources common/functions.sh must resolve the path
# correctly from its own location (some are two levels deep).
@test "all scripts source common/functions.sh with a resolvable path" {
  failures=""
  while IFS= read -r f; do
    dir=$(dirname "$f")
    # Extract the source argument, normalize $SCRIPT_DIR / $(dirname "$0")
    # to the script's directory, then check the resolved file exists.
    arg=$(grep -m1 -o '[^ ]*common/functions.sh' "$f")
    arg=${arg//\$SCRIPT_DIR/}
    arg=${arg//\$(dirname \$0)\//} # dirname form
    arg=${arg//\"/}
    arg=${arg//\}/}
    arg=${arg//\(/}
    if [ ! -e "$dir/$arg" ]; then
      failures="$failures
  $f -> $arg"
    fi
  done < <(grep -rl "common/functions.sh" "$REPO_ROOT" --include="*.sh" | grep -v "/tests/")
  [ -z "$failures" ] || fail "broken source paths:$failures"
}
