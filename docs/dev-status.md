# Build status

Living tracker for which phases of the plan (`~/.claude/plans/write-the-plan-zany-quilt.md`) have landed. Delete at v1.0.0 ship.

GitHub: <https://github.com/raspbeguy/uapi>. CI is green: unit, lint, integration (real OpenWrt 25.12.4 QEMU VM smoke test).

## Done

### Phase 1
- Repo layout (`src/`, `cli/`, `files/`, `tests/`, `build/`, `examples/`, `docs/`).
- `Makefile`: `test`, `test-unit`, `test-integration`, `lint`, `lint-emdash`, `lint-syntax`, `vm-setup`, `vm-start`, `vm-wait`, `vm-stop`, `clean`. Em-dash lint actively rejects violations.
- `tests/harness.uc`: thin ucode test runner.
- `tests/vm/`: OpenWrt 25.12.4 QEMU lifecycle scripts. Injects an SSH key plus a uci-defaults network reconfig (switches LAN to DHCP so QEMU user-mode networking works) at image setup.
- `tests/integration/`: discovery runner plus a smoke test that verifies ubus, uci, and uhttpd in the booted VM.
- `.github/workflows/ci.yml`: three jobs (Alpine container for unit + lint, Ubuntu host with QEMU for integration). Integration job caches the OpenWrt image.

### Phase 3 (partial: pure-ucode modules done)
- `src/lib/ids.uc`: ULID generator (Crockford base32, lowercase, 26 chars), `new_id(prefix)`, `is_valid_id`.
- `src/lib/errors.uc`: full envelope, every CLAUDE.md error code mapped, per-request context.
- `src/lib/scope.uc`: `parse`, `permits` (hierarchical deepest-match-wins, wildcards, rw-implies-ro, same-depth-rw-wins), `validate_against_known_tree`.

Unit test coverage: 59 tests, all green via `make test`.

## Open

### Phase 0 (spike experiments)
The CI integration job proves the VM-driven loop works, but the five formal spikes (serialization probe, snapshot/restore round-trip, ULID section naming, ucitrack discovery, handler persistence) are not yet written. Natural next move: promote each spike to a `tests/integration/*_test.sh` so they run in CI.

### Phase 3 remainder
- `src/lib/ubus.uc`: the injection surface. Design the API against the OpenWrt ubus/uci ucode modules; the unit-test stub mirrors the same surface.
- `src/lib/ucitrack.uc`: package -> reload-service mapping, driven by `/etc/config/ucitrack`.
- `src/lib/transaction.uc`: snapshot, commit, reload, restore recipe.
- `src/lib/auth.uc` (stub form): env-flag-gated stub returning a `*:rw` token until Phase 5 lands real auth.

## How to resume

```sh
cd /home/alpine/repo/uapi
make test                  # unit + lint, runs anywhere ucode is installed
make test-integration      # boots the VM locally (needs QEMU + sudo)
```

Suggested next moves, in priority order:
1. Promote Phase 0 spikes to CI integration tests one by one (A first: serialization probe).
2. Design `src/lib/ubus.uc` and write `src/lib/transaction.uc` + tests against stubs.
3. Begin Phase 4 (`firewall/rules` vertical slice) once transaction.uc is ready.
