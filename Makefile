.PHONY: test test-verbose lint

# Default Proxmox mock bin is in tests/helpers/mocks — no real host is touched.
test:
	@BATS_WARN_BW01=0 BATS_WARN_BW02=0 bats tests/unit

test-verbose:
	@BATS_WARN_BW01=0 BATS_WARN_BW02=0 bats --verbose-run tests/unit

lint:
	find . -path ./.git -prune -o -name '*.sh' -print0 | xargs -0 shellcheck
	@echo "shellcheck done"
