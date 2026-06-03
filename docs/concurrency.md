# Concurrency rules for contributors

uapi runs inside `uhttpd-mod-ucode`'s fork-per-request CGI model. That changes what's safe to write compared to a long-lived process. Read this before adding caches, background work, or "obvious" performance optimizations.

The model is described in detail in [`docs/architecture.md`](architecture.md); this page is the contributor-facing rules summary.

## The model in one sentence

The handler script runs ONCE in the parent uhttpd at startup. Every HTTP request is a forked child that inherits the parent VM via copy-on-write, calls `handle_request(env)`, and exits.

Consequences:

- Anything you compute at module top level (constants, loaded resources, parsed tables) lives in the parent VM and is visible to every request via COW.
- Anything you MUTATE at module top level during a request is private to the fork and lost when the fork exits.
- Two concurrent requests run in separate processes. They cannot communicate via in-memory state.

## What you can do safely

- **Compute static tables at startup.** `RESOURCES`, `SINGLETONS`, `KNOWN_PATHS`, all the resource module return-objects are built once and treated as read-only.
- **Read uci on every request.** uci reads are millisecond-scale and the request volume is low. There is no benefit to caching uci state in memory across requests, and the integration test for the parent-fork model would catch you if you tried.
- **Acquire flocks before writing.** Use `transaction.transaction()` for single-package uci writes; it takes SH on the global lock + EX on the per-package lock. Use `transaction.with_lock()` for non-uci writes; it takes EX on the global. Use `transaction.multi_transaction()` for cross-package atomic writes (`/batch`).
- **Use file-backed state for cross-request data.** The token-bucket rate limiter writes to `/tmp/uapi-ratelimit/<token>.txt`. The idempotency cache writes to `/tmp/uapi-idempotency/`. File IO + atomic rename + flock is the cross-fork channel.

## What you cannot do

### No module-level mutable state for caching

```ucode
let TOKEN_CACHE = null;        // <- DON'T
function get_tokens() {
    if (TOKEN_CACHE == null) TOKEN_CACHE = load_tokens();
    return TOKEN_CACHE;
}
```

This compiles. It works on the first request. The cache is private to the fork; the second request gets a fresh `null` and re-loads. Worse: a token rotation in one fork is invisible to every other fork. Use the file-backed pattern (re-read on each request, atomic-rename to publish updates) instead.

### No `conn.defer()` for ubus

Use `conn.call()` only. Async ubus does not buy you any concurrency you don't already have from forking, and the synchronous failure path is easier to reason about. There is an existing lint that flags `defer()` in code review.

### No "background" work after the response

The fork exits as soon as `handle_request` returns. There is no `setTimeout`, no thread, no detached task. If you need work to outlive the request, write to a file the next request will pick up, or rely on an external cron/timer.

### No in-process pubsub / event bus

Same reason as the cache: state does not survive `fork().exit()`.

## Lock layout

Three lock files matter:

| File | Holder | Purpose |
|---|---|---|
| `/var/lock/uapi.lock` (SH) | every uci transaction | lets multiple uci writes run in parallel ON DIFFERENT PACKAGES, while still serializing against the global EX |
| `/var/lock/uapi.lock` (EX) | non-uci writes (apk, system passwords) | blocks all uci transactions for the duration of the non-uci op |
| `/var/lock/uapi.pkg.<package>.lock` (EX) | a uci transaction on `<package>` | serializes writes to the same package; cross-package writes do not collide |

This is the recipe taken by `transaction.uc`. New write paths should go through one of the three existing entry points (`transaction()`, `multi_transaction()`, `with_lock()`) so the locking is consistent. Direct `fs.open` + `fs.lock` in a new code path is a smell; pause and check if you can route through `transaction.uc` instead.

GETs are lock-free. Reads of uci state run without acquiring any lock.

## Lock ordering for `/batch`

`multi_transaction` acquires per-package EX locks in sorted (lexicographic) order. This is the standard deadlock-avoidance pattern: two batches touching the same set of packages will both acquire in the same order, so one waits for the other, neither holds-and-waits.

If you add a code path that takes multiple locks at once, follow the same sorted-acquire rule. Don't invent a new ordering.

## Test coverage for concurrency claims

The concurrency model is asserted by integration tests, not just docs:

- `tests/integration/01_concurrency_model_test.sh` confirms fork-per-request (5 concurrent requests, 5 distinct PIDs).
- Lock granularity is asserted live: two concurrent writes to DIFFERENT packages both succeed; two to the SAME package serialize with the second returning 423.

If you change the locking model, run integration tests in QEMU before opening the PR.

## When in doubt

The fork-per-request property is the constraint that drives most of the otherwise-surprising design choices in uapi (file-backed rate limit, re-read tokens on every request, no in-process subscriber model). When something feels harder than it should be, ask: "would this approach require state to survive `fork().exit()`?" If yes, that's why.
