# Build status

Living tracker for which phases of the plan (`~/.claude/plans/write-the-plan-zany-quilt.md`) have landed and what is blocked. Delete at v1.0.0 ship.

## Done

### Phase 1 (partial)
- Repo layout established (`src/`, `cli/`, `files/`, `tests/`, `build/`, `examples/`, `docs/`).
- `tests/harness.uc` ucode test runner: `describe`, `it`, `assert_equal`, `assert_deep_equal`, `assert_true`, `assert_false`, `assert_throws`, `assert_match`, `summary`. Self-tested.
- `Makefile` with `test`, `test-unit`, `lint`, `lint-emdash`, `lint-syntax`, `clean` targets. Em-dash lint verified to actively reject violations.

### Phase 3 (partial: pure-ucode modules done)
- `src/lib/ids.uc`: ULID generator (Crockford base32, lowercase, 26 chars), `new_id(prefix)` for uci-section-name-compatible IDs, `is_valid_id` predicate.
- `src/lib/errors.uc`: error envelope (`error`, `field_error`, `validation_failed`, `reload_failed_restored`, `reload_failed_unrecovered`, `ok`, `no_content`), all CLAUDE.md error codes mapped to documented HTTP statuses, `new_context` for per-request request_id.
- `src/lib/scope.uc`: `parse`, `permits` (hierarchical deepest-match-wins with `*:rw`/`*:ro` wildcards, `rw` implies `ro`, same-depth rw-wins), `validate_against_known_tree` for CLI use.

Unit test coverage: 59 tests, all green. Verifiable via `make test`.

## Blocked

### Phase 0 (spike experiments)
Requires a real OpenWrt 25.12 VM. Cannot run in the current Alpine dev environment because the spikes test ubus/uci/uhttpd-mod-ucode behaviour, none of which exist outside OpenWrt.

What it would take to unblock:
- Download the official OpenWrt 25.12 x86_64 combined-ext4 image to `tests/vm/openwrt.img` (about 25MB).
- Confirm QEMU on the host can boot it (KVM acceleration optional; user-mode networking is fine).
- Write `tests/vm/start.sh` and friends.
- Then execute the five spikes (A through E) against the booted VM.

If any spike fails, CLAUDE.md needs revision before continuing per the plan ("If A or B fail, CLAUDE.md needs revision before continuing").

### Phase 1 remainder
- VM lifecycle scripts under `tests/vm/`.
- OpenWrt SDK pulled into `build/sdk/`.
- CI skeleton (`.github/workflows/ci.yml`).

The Makefile `lint-emdash` and `lint-syntax` targets are CI-ready; they just need to be wired into a workflow file.

### Phase 3 remainder
- `src/lib/ubus.uc`: the injection surface. Needs the real ubus/uci ucode modules to be useful; the test stub interface can be designed locally but cannot be exercised without OpenWrt.
- `src/lib/ucitrack.uc`: ditto, depends on ubus.uc.
- `src/lib/transaction.uc`: ditto, the snapshot/commit/reload/restore recipe.
- `src/lib/auth.uc` (stub form): can be written locally.

## How to resume

```sh
cd /home/alpine/repo/uapi
make test     # unit tests + lint should be green
```

Pick up at one of:
- **Unblock Phase 0**: stand up the OpenWrt 25.12 QEMU VM, run the five spikes.
- **Continue Phase 3 against a stubbed ubus**: design `src/lib/ubus.uc`'s interface, write `lib/transaction.uc` against stub responses for happy path and failure paths. Cannot be end-to-end verified until the VM exists.
- **Phase 1 CI scaffolding**: write the GitHub Actions workflow files (or equivalent), which can be committed without VM access but cannot be exercised until a runner has QEMU available.
