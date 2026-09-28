#!/usr/bin/env bats
# The grep mock must never make an assertion pass by matching its own trace
# line in the file under test.

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

@test "grep mock does not self-match the mock log" {
  echo "unrelated content" > "$MOCK_LOG"
  run grep -q "nonsense-pattern-xyz" "$MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "grep mock still finds real matches in the mock log" {
  echo "qm create 100" > "$MOCK_LOG"
  run grep -q "^qm create" "$MOCK_LOG"
  [ "$status" -eq 0 ]
}
