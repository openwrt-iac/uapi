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

## Open

### Phase 4 (next): firewall/rules vertical slice
- `src/main.uc` dispatcher (TLS check, auth, route to resource).
- `src/resources/firewall.rules.uc` implementing the uniform contract.
- CRUD handlers + adopt flow.
- Audit log on writes.
- Integration tests: happy path, validation failure, reload rollback, adoption, auth paths.

### Phase 5+: token CLI + real auth, remaining resources, /raw/, OpenAPI, APK, docs.

## How to resume

```sh
cd /home/alpine/repo/uapi
make test                  # unit + lint, runs anywhere ucode is installed
make test-integration      # boots the VM locally (needs QEMU + sudo)
```
