.PHONY: test test-unit test-integration test-property coverage bench soak lint lint-emdash lint-syntax lint-reserved lint-refs openapi openapi-check stage sbom vm-setup vm-start vm-stop vm-wait clean help

UCODE ?= ucode
UNIT_PATHS = -L tests -L src/lib

help:
	@echo "Targets:"
	@echo "  test               run unit tests and lint"
	@echo "  test-unit          run unit tests only"
	@echo "  test-integration   boot VM, run integration tests, stop VM (sudo required for vm-setup)"
	@echo "  test-property      high-iteration property fuzz pass (PROPERTY_ITERS=1000 default)"
	@echo "  coverage           structural test-coverage inventory (one row per module)"
	@echo "  bench              read-only latency benchmark (UAPI_BASE + UAPI_TOKEN required)"
	@echo "  soak               long-duration read-only load test (UAPI_BASE + UAPI_TOKEN required)"
	@echo "  lint               em-dash check + ucode syntax check"
	@echo "  lint-emdash        forbid em-dashes in tracked sources"
	@echo "  lint-syntax        ucode -c on all .uc files"
	@echo "  lint-reserved      fail on Terraform-reserved schema property names"
	@echo "  lint-refs          fail on dangling \$\$ref strings in build/openapi.json"
	@echo "  lint-defaults      verify every fromUci default is annotated in schema_properties"
	@echo "  openapi            regenerate build/openapi.json from resource modules"
	@echo "  stage              populate build/openwrt/uapi/files/ for SDK package build"
	@echo "  sbom               emit SPDX 2.3 SBOM (build/sbom.spdx.json); APK=<path> attaches built APK sha256"
	@echo "  vm-setup/start/wait/stop   manage the OpenWrt 25.12.4 QEMU VM"

test: lint test-unit

test-unit:
	@$(UCODE) $(UNIT_PATHS) tests/run_unit.uc

# High-iteration property/fuzz pass. Default 1000/resource (vs 200 in
# `make test`) so a regression in fuzz coverage shows up as a distinct
# CI step rather than vanishing into the unit-test output.
test-property:
	@PROPERTY_ITERS=$${PROPERTY_ITERS:-1000} $(UCODE) $(UNIT_PATHS) tests/run_unit.uc

coverage:
	@$(UCODE) $(UNIT_PATHS) tests/coverage.uc

bench:
	@tests/bench/bench.sh

soak:
	@tests/soak/soak.sh

openapi:
	@$(UCODE) build/gen_openapi.uc -o build/openapi.json
	@echo "wrote build/openapi.json ($$(wc -c < build/openapi.json) bytes)"

openapi-check:
	@$(UCODE) build/gen_openapi.uc -o /tmp/openapi.gen.json
	@diff -u build/openapi.json /tmp/openapi.gen.json || { \
		echo ""; echo "build/openapi.json is out of date; run 'make openapi' and commit"; \
		exit 1; }
	@rm -f /tmp/openapi.gen.json

stage:
	@rm -rf build/openwrt/uapi/files
	@mkdir -p build/openwrt/uapi/files/usr/share/uapi/lib
	@mkdir -p build/openwrt/uapi/files/usr/share/uapi/resources
	@mkdir -p build/openwrt/uapi/files/usr/bin
	@mkdir -p build/openwrt/uapi/files/etc/config
	@mkdir -p build/openwrt/uapi/files/etc/uci-defaults
	@cp src/main.uc src/raw.uc      build/openwrt/uapi/files/usr/share/uapi/
	@cp src/lib/*.uc                build/openwrt/uapi/files/usr/share/uapi/lib/
	@cp src/resources/*.uc          build/openwrt/uapi/files/usr/share/uapi/resources/
	@cp build/openapi.json          build/openwrt/uapi/files/usr/share/uapi/openapi.json
	@cp VERSION                     build/openwrt/uapi/files/usr/share/uapi/VERSION
	@cp VERSION                     build/openwrt/uapi/files/VERSION
	@cp cli/uapi-token              build/openwrt/uapi/files/usr/bin/uapi-token
	@cp files/etc/config/uapi       build/openwrt/uapi/files/etc/config/uapi
	@cp files/etc/uci-defaults/99-uapi build/openwrt/uapi/files/etc/uci-defaults/99-uapi
	@chmod +x build/openwrt/uapi/files/usr/bin/uapi-token \
	          build/openwrt/uapi/files/etc/uci-defaults/99-uapi
	@echo "staged to build/openwrt/uapi/files/"

# Emit an SPDX 2.3 SBOM for the staged package.
# APK=<path> attaches the built artifact's sha256 + size to the package
# verification fields; omit if you're just SBOM'ing the staged tree.
sbom: stage
	@tools/gen_sbom.sh build/openwrt/uapi/files $(if $(APK),--apk $(APK)) > build/sbom.spdx.json
	@echo "wrote build/sbom.spdx.json ($$(wc -c < build/sbom.spdx.json) bytes)"

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

lint: lint-emdash lint-syntax lint-reserved lint-refs lint-defaults

lint-emdash:
	@if grep -rn --exclude-dir=sdk $$'\xe2\x80\x94' src cli tests files build examples docs web .github tools Makefile README.md CHANGELOG.md CLAUDE.md CONTRIBUTING.md 2>/dev/null; then \
		echo ""; echo "em-dash found in source files (forbidden per CLAUDE.md style)"; exit 1; \
	fi

lint-syntax:
	@set -e; for f in $$(find src cli tests -name '*.uc'); do \
		if head -c 2 "$$f" | grep -q '{%'; then \
			$(UCODE) -c -T -o /dev/null "$$f"; \
		else \
			$(UCODE) -c -o /dev/null "$$f"; \
		fi; \
	done

# Fails on Terraform-reserved or HCL-keyword schema property names. Catches
# the next provider-hostile field name before it ships.
lint-reserved:
	@$(UCODE) tests/lint_reserved_names.uc

# Walks every $ref under #/components/ in build/openapi.json and fails on
# any dangling target. Catches header-component renames that drift between
# the dict that references them and the dict that defines them.
lint-refs:
	@$(UCODE) tests/lint_ref_integrity.uc

# Verifies every fromUci unconditional default has a matching
# `default: V` in schema_properties. Catches the drift case where a new
# defaulted field lands without the OpenAPI annotation that the
# terraform-provider-uapi clear-on-omit work depends on.
lint-defaults:
	@$(UCODE) tests/lint_defaults.uc

clean:
	@rm -rf build/sdk build/openapi.json
