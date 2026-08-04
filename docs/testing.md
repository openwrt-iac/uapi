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

## The read-honesty property

`tests/unit/read_honesty_test.uc` (2.5.0+) is the unit-level statement of principle 4: read a section, write the body back, read again, and nothing may change or be rejected. It runs in two forms because they catch different defects.

- **Body written back verbatim.** Catches a read the write path cannot reproduce. This is how 2.4.0 destroyed write-only credentials: the read masks them, so the body a client echoes cannot carry them, and the write dropped what it could not see.
- **One field changed first, the rest left as read.** Catches a read whose fields are not independently writable, which the verbatim form structurally cannot see. This is how the `ipaddr` / `ipaddrs` pair became unwritable in 2.4.1: unmodified, the scalar agrees with the list, so the contradiction only appears once the list moves and the previously-read scalar travels beside it. It is also the shape of every real apply.

Both forms were validated by re-introducing the bug they claim to catch, and each catches only its own: neutering `carry_write_only` fails four cases on the verbatim form; neutering `resolve_for_replace` fails one case, and only on the modified form.

The case list cannot go stale, because a companion test derives the at-risk set from the resource modules themselves (any module declaring `writeOnly`, `merge_for_patch`, or `resolve_for_replace`) and fails naming what is uncovered.

Relationship to the stock-config round-trip (layer 8 above): that test runs on a real box against real configuration, which this cannot, but it PUTs verbatim only and covers bare-image packages only. Neither the secret-destruction nor the mirror-field class is reachable from it, since both live in wireguard, wireless and openvpn.

Neither test can see a uci option no resource models at all. PUT deliberately drops unmodelled options, so a view-level comparison cannot detect the loss; that is a curation-completeness question, and layer 8 is what answers it.

## Lint suite

`make lint` chains these sub-targets:

- `lint-emdash`: forbids em-dashes in tracked sources (CLAUDE.md style rule, enforced).
- `lint-syntax`: `ucode -c` on every `.uc` file in `src/`, `cli/`, `tests/`.
- `lint-reserved`: fails on schema property names that collide with Terraform meta-arguments or HCL block keywords.
- `lint-refs`: walks every `$ref` under `#/components/` in `build/openapi.json` and fails on dangling targets.
- `lint-openapi-shape` (2.4.0+): structural checks over `build/openapi.json` that a conformance validator does not make, because the shapes are legal JSON Schema and merely useless to a generator: a schema `required` naming a property the schema does not declare, an `if` with no `then` or `else` (and the reverse), an empty or non-array `enum`, and any value that is the string `"NaN"`. The last one exists because ucode's `+` on two arrays yields NaN rather than concatenating, which is how an `enum` of `"NaN"` reached the published spec.
- `lint-defaults` (2.2.2+): for every `fromUci` unconditional default, verifies a matching `default:` annotation in `schema_properties`; for every `x-uapi-clear-on-omit` flag, verifies the fromUci shape is `section.X ?? null` and the schema type includes `"null"`.

### Asserting that a write reached the daemon

A 200 and a successful read-back prove only that uci accepted the write. Both were true of the redirect bug that made every uapi-created port forward silently vanish. Where a daemon compiles uci into something else, the integration library asserts against that compiled form instead:

- `assert_fw4_emits` / `assert_fw4_omits` / `assert_fw4_loads` check what firewall4 renders from uci and that `nft -c` accepts the whole ruleset. Rendering is used rather than the applied table because CI stubs `/etc/init.d/firewall`, and because `nft -f` is atomic, so one bad token rejects every rule while `firewall reload` still exits 0.
- `assert_dnsmasq_emits` / `assert_dnsmasq_omits` / `assert_dnsmasq_loads` check `/var/etc/dnsmasq.conf.<id>`, which dnsmasq compiles from `/etc/config/dhcp` on reload, and run `dnsmasq --test` over it. `--test` is the counterpart to `nft -c`: it reports a bad option or a bad value without disturbing the running server.

There is deliberately **no equivalent for network**. netifd reports a status object for an interface whose proto it does not recognise (silently falling back to `none`) and for one whose device does not exist, so "netifd knows about it" passes for broken configuration and would be a tautological assertion. `available: false` is not a usable signal either, since it is also false for a perfectly valid interface that has no device to bind to. A meaningful check would need a test interface bound to a real device, which the suite does not currently create.

`make openapi-validate` (2.4.0+) runs a real OpenAPI 3.1 conformance validator over the emitted document. It is deliberately **not** part of `make lint`, which stays dependency-free; it needs `python3` and `openapi-spec-validator`, and CI runs it as its own step so the gate is enforced without every local `make lint` requiring a pip install. It fails rather than skips when the validator is absent, since a check that quietly passes is worse than no check. The two gates are complementary and were measured to be so: the conformance run catches type and keyword violations anywhere in the document, and misses the two semantic cases above, which are valid JSON Schema.

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
