.PHONY: test test-unit test-integration lint lint-emdash lint-syntax vm-setup vm-start vm-stop vm-wait clean help

UCODE ?= ucode
UNIT_PATHS = -L tests -L src/lib

help:
	@echo "Targets:"
	@echo "  test               run unit tests and lint"
	@echo "  test-unit          run unit tests only"
	@echo "  test-integration   boot VM, run integration tests, stop VM (sudo required for vm-setup)"
	@echo "  lint               em-dash check + ucode syntax check"
	@echo "  lint-emdash        forbid em-dashes in tracked sources"
	@echo "  lint-syntax        ucode -c on all .uc files"
	@echo "  vm-setup/start/wait/stop   manage the OpenWrt 25.12.4 QEMU VM"

test: lint test-unit

test-unit:
	@$(UCODE) $(UNIT_PATHS) tests/run_unit.uc

vm-setup:
	@tests/vm/setup.sh

vm-start:
	@tests/vm/start.sh

vm-wait:
	@tests/vm/wait.sh

vm-stop:
	@tests/vm/stop.sh

test-integration: vm-setup vm-start
	@trap 'tests/vm/stop.sh' EXIT INT TERM; \
	 tests/vm/wait.sh && tests/integration/run.sh

lint: lint-emdash lint-syntax

lint-emdash:
	@if grep -rn $$'\xe2\x80\x94' src cli tests files build examples docs Makefile 2>/dev/null; then \
		echo ""; echo "em-dash found in source files (forbidden per CLAUDE.md style)"; exit 1; \
	fi

lint-syntax:
	@find src cli tests -name '*.uc' -print0 | xargs -0 -I{} $(UCODE) -c -o /dev/null {}

clean:
	@rm -rf build/sdk build/openapi.json
