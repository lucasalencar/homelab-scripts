.PHONY: test test-python test-verbose lint

# Single source of truth for the ShellCheck version, used both locally and
# in CI. Bump this to upgrade everywhere at once; `?=` allows one-off
# overrides like `SHELLCHECK_VERSION=0.9.0 make lint`.
SHELLCHECK_VERSION ?= 0.11.0
SHELLCHECK_DIR := $(CURDIR)/.tools/shellcheck-v$(SHELLCHECK_VERSION)
SHELLCHECK_BIN := $(SHELLCHECK_DIR)/shellcheck

# Default Proxmox mock bin is in tests/helpers/mocks — no real host is touched.
test: test-python
	@BATS_WARN_BW01=0 BATS_WARN_BW02=0 bats tests/unit

test-python:
	@python3 caddy/test_generate_caddyfile_core.py

test-verbose: test-python
	@BATS_WARN_BW01=0 BATS_WARN_BW02=0 bats --verbose-run tests/unit

$(SHELLCHECK_BIN):
	mkdir -p "$(SHELLCHECK_DIR)"
	curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v$(SHELLCHECK_VERSION)/shellcheck-v$(SHELLCHECK_VERSION).linux.x86_64.tar.xz" -o "$(SHELLCHECK_DIR).tar.xz"
	tar -xf "$(SHELLCHECK_DIR).tar.xz" -C "$(SHELLCHECK_DIR)" --strip-components=1
	rm -f "$(SHELLCHECK_DIR).tar.xz"

lint: $(SHELLCHECK_BIN)
	find . -path ./.git -prune -o -name '*.sh' -print0 | xargs -0 "$(SHELLCHECK_BIN)"
	@python3 -m py_compile caddy/generate_caddyfile_core.py caddy/test_generate_caddyfile_core.py
	@echo "shellcheck $(SHELLCHECK_VERSION) done"
