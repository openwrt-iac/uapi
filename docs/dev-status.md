# Build status

Living tracker for which phases of the plan (`~/.claude/plans/write-the-plan-zany-quilt.md`) have landed. Delete at v1.0.0 ship.

GitHub: <https://github.com/raspbeguy/uapi>. CI is green: unit, lint, integration.

## Done

### Phase 0 (partial: spike A landed)
Spike A (concurrency model) is in CI as `tests/integration/01_concurrency_model_test.sh`. Result: uhttpd-mod-ucode is fork-per-request CGI, not a persistent handler. CLAUDE.md "Concurrency" was rewritten accordingly; the test's assertions now lock in the corrected model (5 distinct PIDs, all responses `count=1`, wall time ~2s under uhttpd's `max_requests` cap). Spikes B (snapshot/restore round-trip), C (ULID section naming), D (ucitrack discovery), E (handler persistence) are not separately written; B and C will be implicitly exercised by Phase 4's integration tests, D and E are folded into the new design.

### Phase 1
- Repo layout, Makefile, em-dash + ucode-syntax lint.
- `tests/harness.uc` ucode test runner.
- `tests/vm/` OpenWrt 25.12.4 QEMU lifecycle (download, key injection, DHCP-LAN uci-defaults, start/wait/stop/ssh).
- `tests/integration/` runner + smoke test.
- `.github/workflows/ci.yml` with unit + lint (Alpine container) and integration (Ubuntu host + QEMU + cached OpenWrt image).

### Phase 3
All shared internals landed with unit-test coverage.

- `src/lib/ids.uc` ULID generator with type-prefixed IDs and validation.
- `src/lib/errors.uc` full error envelope, every CLAUDE.md code mapped, `locked` helper sets `Retry-After`, per-request context.
- `src/lib/scope.uc` hierarchical scope parser and matcher.
- `src/lib/ubus.uc` injection surface for `ubus`/`uci` plus a deep-test stub (programmable responses, recorded calls, in-memory uci with `_state`, snapshot round-trip).
- `src/lib/ucitrack.uc` package to reload-service mapping with fallback table.
- `src/lib/transaction.uc` atomic recipe with non-blocking flock (`/var/lock/uapi.lock`), snapshot-restore on reload failure, `reload_failed_unrecovered` worst-case path.
- `src/lib/auth.uc` Bearer-header parser and lookup against a tokens map, plus `stub_enabled`/`stub_token` for Phase 4 wiring. Real uci-backed token loading is Phase 5.

Unit test coverage: 113 tests, all green via `make test`.

### Phase 4 (firewall/rules vertical slice)
- `src/main.uc`: TLS check, request context, JSON body parsing, query parsing, auth (uci token loader), scope check, route to handler, audit log on writes.
- `src/resources/firewall.rules.uc`: schema, validate, fromUci, toUci, cross-reference checks against existing zones.
- `src/lib/handler.uc`: generic CRUD over a resource module (list/get/create/replace/patch/remove/adopt).
- `tests/integration/lib/install_uapi.sh` + test-tokens uci: idempotent VM provisioning.
- Integration tests landed:
  - `02_api_skeleton`: healthz, 404 fallback, auth-gated unknown paths, method not allowed.
  - `03_firewall_rules_crud`: POST→GET→list→PATCH→PUT→DELETE round-trip; validation 422; auth 401/403.
  - `04_adopt`: anonymous rule injected via uci, surfaced as `managed: false`; PUT/DELETE rejected with `unmanaged_resource`; `POST .../adopt` renames to ULID and flips `managed: true`; double-adopt returns 409.

Real-OpenWrt findings captured along the way:
- `loadfile()` inherits the VM's parse mode; raw-script modules loaded from template-mode handlers need `{raw_mode: true}`.
- `cursor.get(pkg, sect)` returns the section type string; the full dict requires `cursor.get_all(pkg, sect)`.
- uhttpd's CGI header parser requires `Status: NNN <reason>` with a reason phrase; `Status: NNN` alone is silently dropped.
- ucode-mod-uci has no `cursor.export`/`cursor.import`; the bus wrapper reads/writes `/etc/config/<pkg>` directly for snapshot/restore.

### Phase 5 (auth, CLI, healthz, install hook)
- `cli/uapi-token`: `create`, `list`, `show`, `revoke`. Cleartext shown once at create; salted sha256 hash stored. Scope strings validated against the known tree; `--force` bypasses.
- `lib/auth.uc`: new signature `authorize(tokens_array, header, hash_fn)`. Production passes `digest.sha256(salt + ":" + bearer)`; tests pass a plaintext-compare function so unit tests don't need the digest module.
- `main.uc`: loads tokens in `{name, salt, hash, scopes}` form, passes the hash function to authorize.
- `main.uc /healthz`: probes ubus via `system info`; returns 503 `service_unavailable` if unreachable.
- `files/etc/uci-defaults/99-uapi`: idempotent install hook that adds the `ucode_prefix` to `uhttpd.main` and reloads uhttpd; self-deletes on first-boot success.
- Integration tests now mint tokens via the CLI on each run; the plaintext test-tokens uci file is gone.

Real-OpenWrt findings: ucode-mod-digest exports `digest.sha256(s)` returning the hex digest directly (no separate `sha256_hex`).

### Phase 6 (remaining curated resources)
All ten curated v1 resources are implemented:

- `firewall/rules` (Phase 4), `firewall/zones`, `firewall/redirects`
- `network/interfaces`, `network/devices`
- `wireless/devices`, `wireless/interfaces` (wifi `key` is write-only, `fromUci` masks it and reports `has_key: true`)
- `dhcp/hosts`
- `dhcp/leases` (read-only runtime; parses `/tmp/dhcp.leases`; supports `?managed=` filter is N/A here, but `/dhcp/leases/<mac>` lookup works)
- `system` (singleton)

Three handler-factory shapes now cover the v1 surface:
- `handler.make(resource)`: full CRUD against uci sections
- `handler.make_singleton(resource)`: GET/PATCH on a single uci section (the `system` config)
- `handler.make_collection(resource)`: read-only list backed by a custom `list_fn`; write methods all return 405. Future runtime-list resources (wifi clients, ARP, routing table) follow this pattern

`main.uc` routes via two registries (`RESOURCES`, `SINGLETONS`). Adding a future resource is one line plus the module.

Integration tests: each resource has at least one round-trip test against the real VM (CRUD, GET/PATCH for singleton, GET/get-by-id for the read-only collection).

### Phase 7 (generic /raw/ passthrough)
- `src/raw.uc`: generic `/api/v1/raw/<package>/<id>` handler. GET/POST/PUT/PATCH/DELETE plus collection-level GET/POST.
- Section payload mirrors uci exactly (uci field names, list options as arrays). Response carries `id`, `.type`, `managed`, plus the section options. Writes also include `reloaded: bool`, `reload_services: [...]`, and a `reload_note` when no reload service was known.
- Reload services inferred via `lib/ucitrack.uc` (uses `/etc/config/ucitrack` plus the fallback table). Unknown packages get `reloaded: false` plus the explanatory note.
- Dual-scope composition: every raw request requires `raw:*` AND the inferred domain scope. The mapping (`firewall.rule` to `firewall:rules`, etc.) lives in `raw.uc`. Unknown packages fall back to `[<package>]` for the domain check, so only `*:rw` or `<pkg>:rw` permits them.
- Integration test seeds an admin POST that creates a rule, a `firewall_ro` token POST that 403s (composition check), and an unknown-package POST that 200s with `reloaded: false`.

New finding: ucode does not hoist function declarations. Forward references between top-level functions fail at runtime with "left-hand side is not a function." Define helpers before callers.

### Phase 8 (OpenAPI emission)
- `build/gen_openapi.uc`: generator that walks the curated + collection + singleton endpoint list, introspects each resource module's `fromUci` output to derive a basic JSON Schema, and emits OpenAPI 3.1.
- 30 paths, 14 schemas. Covers all curated CRUD endpoints, `/system` singleton, `/dhcp/leases` collection, `/raw/{package}/{id}` passthrough, `/healthz`.
- Bearer security scheme, error envelope and field error schemas, named response references for each standard HTTP error code.
- `build/openapi.json` is checked in as the canonical contract artifact.
- `make openapi` regenerates; `make openapi-check` diffs the regeneration against the checked-in copy and fails CI if they drift. Wired into the `lint` job so PRs that change resources without regenerating fail before integration.

Phase 8 follow-ups landed:
- Per-resource `schema_properties` overrides expose enum and pattern constraints in OpenAPI. The generator merges these into the auto-derived property map. Enums cover firewall targets/policies/families/protos, network interface protos, network device types, wireless types/bands/modes/encryption; pattern set for dhcp.hosts MAC.
- `GET /api/v1/openapi.json` serves the spec without auth (TLS check still applies). Per-request file read; the parent VM doesn't cache.
- `install_uapi.sh` pushes `build/openapi.json` to `/usr/share/uapi/openapi.json` on the test VM. Real APK packaging in Phase 9 will install via the SDK Makefile.

### Phase 9 (APK packaging)
- `build/openwrt/uapi/Makefile`: OpenWrt SDK Makefile for the package. Pure-`files` install (no compile step), `PKGARCH:=all`. Depends on `uhttpd`, `uhttpd-mod-ucode`, `ucode`, and the `ucode-mod-{ubus,uci,fs,digest,log}` mods.
- `files/etc/config/uapi`: conffile seed with a commented example token block.
- `Package/uapi/postinst`: runs the `99-uapi` uci-defaults script immediately on live installs, deletes it, then prints the bootstrap message (CLAUDE.md "Post-install message").
- `Package/uapi/prerm`: removes the `ucode_prefix` entry before the handler files disappear, commits uhttpd config, reloads uhttpd.
- `make stage`: populates `build/openwrt/uapi/files/` from `src/`, `cli/`, `files/`, and `build/openapi.json`. Mirrors the install layout 1:1.
- `docs/packaging.md`: walk-through for building the APK against the official 25.12.4 SDK.
- `.github/workflows/release.yml`: release-tier workflow (manual or tag-triggered). Downloads + caches the SDK, stages, builds the APK, runs the smoke test (`release_apk_smoke.sh`) which `apk add`s the freshly-built package into a clean VM, verifies the uci-defaults hook wired the prefix and self-deleted, mints a token via the CLI, hits `/healthz` and `/system`, then `apk del`s and confirms the conffile survives.

## Open

### Phase 10+: README, operator docs, curl example suite, release v1.0.0.

## How to resume

```sh
cd /home/alpine/repo/uapi
make test                  # unit + lint, runs anywhere ucode is installed
make test-integration      # boots the VM locally (needs QEMU + sudo)
```
