#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  export HOME="$MOCK_TMPDIR/home"
  unset DOTFILES_ROOT
  /bin/mkdir -p "$HOME"
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
}

_setup_home_with_update() {
  /bin/mkdir -p "$HOME/.dotfiles"
  printf '#!/bin/bash\necho "dotfiles updated $*"\necho "ROOT=$DOTFILES_ROOT"\n' > "$HOME/.dotfiles/update"
  /bin/chmod +x "$HOME/.dotfiles/update"
}

@test "dotfiles update runs the current user's update script" {
  _setup_home_with_update
  run bash "$REPO_ROOT/dotfiles/update.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dotfiles updated"* ]]
  ! grep -q "^su " "$MOCK_LOG"
}

@test "dotfiles update forwards args to the update script" {
  _setup_home_with_update
  run bash "$REPO_ROOT/dotfiles/update.sh" git
  [ "$status" -eq 0 ]
  [[ "$output" == *"dotfiles updated git"* ]]
}

@test "dotfiles update skips cleanly without dotfiles checkout" {
  run bash "$REPO_ROOT/dotfiles/update.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kipping"* ]] || [[ "$output" == *"No update"* ]]
  ! grep -q "^su " "$MOCK_LOG"
}

@test "dotfiles update skips cleanly when run as root" {
  _setup_home_with_update
  export MOCK_ID_UID=0
  run bash "$REPO_ROOT/dotfiles/update.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"as your user"* ]] || [[ "$output" == *"kipping"* ]]
  ! grep -q "^su " "$MOCK_LOG"
  [[ "$output" != *"dotfiles updated"* ]]
}

@test "dotfiles update defaults DOTFILES_ROOT to home checkout" {
  _setup_home_with_update
  run env -u DOTFILES_ROOT bash "$REPO_ROOT/dotfiles/update.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ROOT=$HOME/.dotfiles"* ]]
}

@test "dotfiles update preserves an existing DOTFILES_ROOT" {
  _setup_home_with_update
  export DOTFILES_ROOT="/custom/root"
  run bash "$REPO_ROOT/dotfiles/update.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ROOT=/custom/root"* ]]
}
