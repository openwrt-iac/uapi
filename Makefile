.PHONY: test test-unit test-integration test-property coverage bench soak lint lint-emdash lint-syntax lint-reserved lint-refs lint-openapi-shape lint-defaults openapi openapi-check openapi-validate stage sbom vm-setup vm-start vm-stop vm-wait clean help lint-doc-refs gate-selftest

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
	@echo "  lint-doc-refs      fail on doc references that do not resolve (paths, exports, targets, codes)"
	@echo "  gate-selftest      break each gate on purpose and assert it fails"
	@echo "  lint-openapi-shape structural checks a conformance validator does not make"
	@echo "  openapi            regenerate build/openapi.json from resource modules"
	@echo "  openapi-validate   conformance-check the spec (needs python3 + openapi-spec-validator)"
	@echo "  stage              populate build/openwrt/uapi/files/ for SDK package build"
	@echo "  sbom               emit SPDX 2.3 SBOM (build/sbom.spdx.json); APK=<path> attaches built APK sha256"
	@echo "  vm-setup/start/wait/stop   manage the OpenWrt 25.12.5 QEMU VM"

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

# Conformance run against a real OpenAPI 3.1 validator. Deliberately not part
# of `lint`, which must stay dependency-free: this needs python3 and is wired
# into CI instead, so the gate is enforced without every local `make lint`
# requiring a pip install. Fails loudly when the validator is missing rather
# than skipping, since a check that quietly passes is worse than none.
openapi-validate:
	@command -v python3 >/dev/null || { echo "python3 required for openapi-validate"; exit 1; }
	@python3 -c 'import openapi_spec_validator' 2>/dev/null \
		|| { echo "openapi-spec-validator not installed: pip install openapi-spec-validator"; exit 1; }
	@python3 -c 'import json; from openapi_spec_validator import validate; \
		validate(json.load(open("build/openapi.json"))); \
		print("OK: build/openapi.json is a valid OpenAPI 3.1 document")'

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

lint: lint-emdash lint-syntax lint-reserved lint-refs lint-openapi-shape lint-defaults lint-doc-refs

# Tracked files only, via git rather than a hand-kept directory list. The list had
# gone stale: it named a `web` directory deleted in 2.0.3, and a missing path makes
# grep exit 2, which the `if` reads as "no match", so the rule was unenforced. It
# also scanned untracked build artifacts, where a binary image matches by accident.
#
# The two guards exist because the git form had its own silent-pass hole: the CI lint
# container installed no git, so `git ls-files` printed nothing, `hits` came back empty
# and the check reported success without reading a file. It had never run in CI. git is
# installed there now, and these guards mean the next container change fails the build
# instead of quietly disabling the rule.
lint-emdash:
	@command -v git >/dev/null 2>&1 || { \
		echo "lint-emdash needs git to list tracked files; without it this check passes without scanning anything"; \
		exit 1; }
	@git rev-parse --git-dir >/dev/null 2>/tmp/uapi-emdash-git.err || { \
		echo "lint-emdash cannot use this checkout, so the scan would be empty. git said:"; \
		sed 's/^/  /' /tmp/uapi-emdash-git.err; \
		echo "  (a tarball export has no tracked-file list; a container checkout needs"; \
		echo "   git config --global --add safe.directory \"\$$GITHUB_WORKSPACE\")"; \
		exit 1; }
	@hits=$$(git ls-files -z | xargs -0 grep -In $$'\xe2\x80\x94' 2>/dev/null || true); \
	if [ -n "$$hits" ]; then \
		echo "$$hits"; \
		echo ""; echo "em-dash found in tracked files (forbidden per CLAUDE.md style)"; exit 1; \
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

# Structural checks a conformance validator does not make, because the shapes
# they catch are legal JSON Schema and merely useless to a code generator.
# Complements openapi-validate rather than duplicating it.
lint-openapi-shape:
	@$(UCODE) tests/lint_openapi_shape.uc

# Breaks each gate on purpose and asserts it says so. Not part of `lint`: it runs the
# gates repeatedly in a throwaway worktree, which is CI-shaped work rather than
# edit-loop work. `lint-emdash` shipped for releases without ever running in CI, so a
# green gate and a working gate are not the same claim.
gate-selftest:
	@sh tests/gate_selftest.sh

# Fails on a documentation reference that does not resolve: a repo path, a
# module export, a `make` target, or an error code documented as returned that
# nothing emits. Four false claims were found by hand in a few days; this catches
# the two shapes that are mechanically checkable.
lint-doc-refs:
	@$(UCODE) tests/lint_doc_refs.uc

# Verifies every fromUci unconditional default has a matching
# `default: V` in schema_properties. Catches the drift case where a new
# defaulted field lands without the OpenAPI annotation that the
# terraform-provider-uapi clear-on-omit work depends on.
lint-defaults:
	@$(UCODE) tests/lint_defaults.uc

# build/openapi.json is tracked and is an input to `make lint` and `make stage`, so
# it is deliberately not removed here; `make openapi` regenerates it in place.
clean:
	@rm -rf build/sdk build/sdk-* build/sbom.spdx.json build/openwrt/uapi/files
