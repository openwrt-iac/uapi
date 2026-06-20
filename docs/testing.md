# Testing

Three layers, plus the harness and the load-bearing test inventory.

## Layers

- **Unit tests** (pure ucode): schema validation, `fromUci`/`toUci`, scope matcher, ID generation, error envelope, transaction snapshot logic. Runs anywhere ucode runs. Sub-5s end-to-end.
- **Integration tests** (QEMU + official OpenWrt VM image): full transaction recipe against real ubus/uci, auth on the wire, audit log emission, snapshot-restore. ~1-2 min including boot.
- **Contract / Terraform provider tests**: handled by `openwrt-iac/terraform-provider-uapi` against a running uapi. Seeded by the in-repo curl example suite (`examples/curl/`) and the emitted OpenAPI spec.

## ucode test harness

Thin homegrown harness (`tests/harness.uc`, ~100 lines): `describe` / `it` / `assert_equal` / `assert_true` / `assert_throws`, plain text output, exit code 1 on any failure.

## Injectable ubus surface

All ubus/uci calls route through a single injectable surface (`src/lib/bus.uc`). In production it's the real `ubus.connect()` / `uci.cursor()`; in unit tests it's a stub returning canned responses. This is the difference between covering 30% and covering the transaction recipe's failure paths (specifically the snapshot-restore rollback, which is hard to trigger naturally).

## Load-bearing integration tests

Every regression in this list has cost a real debug round-trip at some point. Keep them green; if one starts failing, that is the prompt to stop and investigate before pushing.

1. **Concurrency model confirmation.** Handler sleeps 1s; 5 concurrent curls; total wall time ~1-2s with 5 distinct PIDs and `count == 1` on every response. Confirms the fork-per-request CGI model (`tests/integration/01_concurrency_model_test.sh`).
2. **Happy-path write.** PUT → 200 → GET reflects new state → audit log line in syslog.
3. **Validation failure.** Bad payload → 422 with field errors → no uci change.
4. **Reload failure rollback.** Construct a config uci accepts but the daemon rejects → 500 `reload_failed_restored` → uci back to prior state.
5. **Auth paths.** Missing/bad token → 401. Insufficient scope → 403. Plain HTTP from remote → 403 `tls_required`.
6. **Adoption flow.** Pre-existing anonymous section → `managed: false` → PUT denied with `unmanaged_resource` → `POST .../adopt` → writable.
7. **APK install smoke test.** Fresh OpenWrt 25.12 → `apk add uapi` → init script wires uhttpd → curl works.
8. **Stock-config compatibility round-trip** (`tests/integration/44_stock_config_test.sh`, 2.3.0+). For every curated CRUD resource whose package ships in the bare OpenWrt image: `GET` the section, adopt it if `managed: false`, `PUT` the body back verbatim, then `GET` again and diff the persistable shape. Singletons follow the same pattern with `PATCH` instead of `PUT` (singletons don't expose PUT, per `handler.make_singleton`). A 422 or a diff surfaces a regression where uapi rejects (or silently mutates) what OpenWrt itself ships. Catches the validation-stricter-than-the-platform class. Scope is limited to bare-image packages (firewall, network, dhcp, dropbear, system); resources from optional packages (snmpd, lldpd, vnstat, mwan3, etc.) are deferred to a follow-up that wires their install at VM-setup time. The test should remain the last-numbered integration test because PUT-self cumulatively rewrites the VM's `/etc/config/*` (`toUci` drops options not in `schema_properties`), and any later test depending on pristine stock state would see drift.

## Lint suite

`make lint` chains four sub-targets:

- `lint-emdash`: forbids em-dashes in tracked sources (CLAUDE.md style rule, enforced).
- `lint-syntax`: `ucode -c` on every `.uc` file in `src/`, `cli/`, `tests/`.
- `lint-reserved`: fails on schema property names that collide with Terraform meta-arguments or HCL block keywords.
- `lint-refs`: walks every `$ref` under `#/components/` in `build/openapi.json` and fails on dangling targets.
- `lint-defaults` (2.2.2+): for every `fromUci` unconditional default, verifies a matching `default:` annotation in `schema_properties`; for every `x-uapi-clear-on-omit` flag, verifies the fromUci shape is `section.X ?? null` and the schema type includes `"null"`.

## CI shape

- Every commit/PR: unit suite + lint.
- Every PR + push to main: unit + integration suite (QEMU).
- Release tag: + multi-arch verify-build (cross-compile sanity) + release-apk job (publishes the GitHub Release with CHANGELOG-extracted notes).

## OpenAPI emission

Generated at build time (`make openapi`) from the inline `schema_properties` blocks in each resource module. Shipped as `/usr/share/uapi/openapi.json` and surfaced at `/api/v2/openapi.json`. The spec is the contract document and the input for openapi-codegen consumers (the Terraform provider in particular).

`make openapi-check` regenerates the spec into a temp file and diffs against the committed `build/openapi.json`. CI runs this as a sanity gate; if it fails, the committed spec is out of sync with the resource modules and one of them has to give.

## Curl example suite

In-repo at `examples/curl/`, one file per curated resource demonstrating CRUD. Doubles as documentation and seed for provider contract tests.

## Coverage gates

`make coverage` reports:

- Module coverage: every `.uc` file under `src/lib/` exercised by at least one unit test. Target: 100% (every module covered, even shallowly).
- Direct-call coverage: every exported function from `src/lib/` invoked by name in at least one unit test. Threshold: 80%. Functions reached only through production code paths count toward "total covered" but not "directly tested."

The thresholds are guardrails, not strict; if coverage drops below them, the CI step fails and the responsible commit has to add a missing test or justify the gap.
