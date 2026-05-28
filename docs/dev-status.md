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

## Open

### Phase 6+: remaining resources (network/interfaces, firewall/zones, dhcp/hosts, etc.), /raw/ passthrough, OpenAPI emission, APK packaging, docs.

## How to resume

```sh
cd /home/alpine/repo/uapi
make test                  # unit + lint, runs anywhere ucode is installed
make test-integration      # boots the VM locally (needs QEMU + sudo)
```
