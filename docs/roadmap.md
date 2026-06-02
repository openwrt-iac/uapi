# Roadmap

Things deliberately not yet shipped. Each entry says why and what shape the change would take.

## Shipped

- **ETags / `If-Match` optimistic concurrency** in v1.2.
- **Schema-driven type check.** `handler.uc` walks `schema_properties` before every `resource.validate()` and 422s shape mismatches that previously fell through to `toUci()` and were silently dropped. PATCH schema-checks the wire delta only (the merge inherits fromUci's uci-string view of integer fields). Errors are deduped by `(field, code)`; messages use JSON Schema vocabulary (`got integer`, not `got int`).
- **Round-trip property tests + adversarial fuzz harness.** `tests/property_harness.uc` exposes a deterministic LCG and two contract checkers used by `tests/unit/property_test.uc`: every resource gets 200 fuzz bodies through `validate()` (must never throw) and 7 representative resources have synthesized-section fixtures that prove `fromUci -> toUci -> fromUci` is stable.
- **Coverage inventory.** `make coverage` walks `src/resources` and `src/lib`; CI gates on 100% structural coverage.
- **Latency benchmark.** `make bench` reports p50/p95/p99 across representative reads against a live router.
- **Soak harness.** `make soak` runs a long read-only load loop with optional SSH-side RSS/fd/child sampling.
- **Per-package flock.** uci transactions hold SH on `/var/lock/uapi.lock` + EX on `/var/lock/uapi.pkg.<package>.lock`. Different packages run in parallel; same package serializes; non-uci writes (apk, system/access) hold the global EX. Live-verified cross-package POSTs overlap; same-package POSTs return `423 locked` (non-blocking, client retries).
- **Security headers on every response.** `Strict-Transport-Security`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Cache-Control: no-store`.
- **Central enum / min / max / pattern / items enforcement.** `check_schema_types` now enforces every constraint declared in `schema_properties` (was previously only `type`). Items recursion propagates type/enum/range to array elements with indexed field paths (`tags[1]`).
- **Per-resource validate dedup.** 14 resources had their now-redundant enum/min/max/pattern checks removed from `validate()`. Net `-103` lines. The central check is the source of truth; `validate()` now carries only cross-field logic (required/conflict/format checks the schema doesn't yet express).

## Features (additive, future minor bumps)

- **Multi-resource batch endpoint.** `POST /api/v1/batch [{path, method, body}, ...]`. All-or-nothing under one combined snapshot/restore across N packages. Real unlock for Terraform `apply`: cross-resource references become one server-side transaction. Need a combined-snapshot recipe and a precondition policy (any 4xx in the batch aborts the whole thing). No sidecar required.
- **`commit-confirmed` timed rollback.** Apply, wait N seconds for client `POST /commits/<id>/confirm`, auto-revert if no ack. Conflicts with the fork-per-request model (no place for a background timer in the handler); needs a small procd-managed sidecar daemon that holds the post-commit timer and runs the rollback. Breaks the "no daemon of our own" architectural principle: explicit decision required before adoption.
- **`/metrics` endpoint** (Prometheus-style). Counters and histograms need cross-fork shared state. Two paths: file-backed counters under `/tmp/uapi-metrics/` with `flock` (no daemon, simpler) or the same sidecar as `commit-confirmed` (more flexible). Pick simultaneously with the commit-confirmed decision.
- **Per-token rate limiting.** Token-bucket per token-id, persisted as a small file under `/var/run/uapi-ratelimit/<token-id>` with `flock(LOCK_SH)` reads and `flock(LOCK_EX)` writes. Returns `429 too_many_requests` (new error code) with `Retry-After`. No sidecar needed.
- **Token expiry + rotation.** `uci set uapi.<id>.expires_at = <epoch>` field plus an auth-time check. Add `POST /api/v1/tokens` (admin scope) for HTTP-side creation that doesn't require shell access. The token-mint endpoint needs scope-creation guard rails (a token can only mint sub-scopes of its own) to avoid privilege escalation on token compromise.
- **`/api/v1/auth/whoami`** returning `{token_id, name, scopes[], expires_at, source_ip}`. One read endpoint, no risk, big ergonomic win for Terraform provider debugging.
- **Dependency-aware ETags.** Today an ETag covers only the resource body. Changing a zone invalidates rules that reference it, but those rules' ETags don't reflect that. State-of-the-art: each resource declares its `depends_on` set; ETag mixes in the hash of every referenced resource. Would catch cross-resource staleness that today's `If-Match` misses.

## Hardening (next, no new wire surface)

- **Branch / line coverage measurement.** Today's `make coverage` is structural (does any test mention this module?). Real branch coverage would surface never-executed validate paths and was what would have caught the `apk info --installed` regression. Needs ucode instrumentation hooks or an external tracer; non-trivial.
- **Soak as a CI step.** `make soak` exists but requires a live target. Wiring it into the QEMU VM CI job as a short (~60s) read-only sweep that tracks RSS / fd / child counts would catch leaks pre-release.
- **Performance benchmark gate.** `make bench` reports per-endpoint latency. Storing a baseline per release and failing a PR that regresses P99 by >25% would close the perf-regression loop.
- **Lock-and-state audit.** Walk every fd-open / lock-acquire site and prove release on every exit including `die()`. Identify any `try` without `finally`-equivalent. Partial audit done alongside the per-package flock work (caught the `create_feed_handler` TOCTOU); a complete sweep is still pending.
- **Non-uci resource base library.** `packages/*` and `system/access` duplicate `with_lock` + audit + envelope plumbing. One shared helper would simplify both and any future non-uci addition. Threshold: refactor when the third non-uci resource lands.

## Out of scope by design

- **Localization of error `message` strings.** English-only; codes are stable and translatable client-side.
- **Async/parallel ubus.** `conn.call()` only, by design (see Concurrency).
- **In-memory caches across requests.** Forked children only.
- **Multi-tenant scoping.** Single admin namespace.
