# uapi architecture

Reader-facing technical overview. The design contract lives in `CLAUDE.md`;
this document explains the *current shape* of the implementation: where
state lives, how a request is served, what locks are held when, how ETags
are computed, how rate limits and metrics are stored, what the failure
modes are.

## Process model

`uapi` is not a daemon. There is no `uapi` process. There is no `uapid`,
no `procd` service definition, no procmon entry.

The code runs inside `uhttpd`'s existing fork-per-request CGI workers via
`uhttpd-mod-ucode`. A single `list ucode_prefix '/api/v3=/usr/share/uapi/main.uc'`
entry in `/etc/config/uhttpd` is the entire wiring.

Specifically, uapi shares the default `main` uhttpd instance with LuCI. Both serve configuration use cases; sharing keeps the footprint minimal and lets uapi inherit whatever TLS configuration the operator already set up for LuCI (acme certs, custom listen addresses, etc.). A dedicated uapi uhttpd instance was considered and rejected: it doubles the runtime cost without earning the isolation back (an attacker who can reach LuCI can already reach the same box).

```
                         uhttpd parent (always running)
                         ├── compiles main.uc once at startup
                         ├── module-level state warm in parent VM
                         │   (RESOURCES, SINGLETONS, RESOURCE_SOURCES,
                         │    BARE_RESOURCES, BARE_SINGLETONS, VERSION,
                         │    LOGGING)
                         │
        client ─HTTP─►  forks a child per request
                         │
                         child
                         ├── inherits parent VM via copy-on-write
                         ├── handle_request(env) runs
                         ├── any mutation is private to this fork
                         └── exit(0)
```

Validated in `tests/integration/01_concurrency_model_test.sh`: 5 concurrent
requests against a sleeping endpoint observe at least 2 distinct PIDs
(the assertion's floor; uhttpd caps concurrent CGI children at 3), total wall
time ≈ 1-2s instead of ≈ 5s.

### What this buys us

- Zero footprint when idle. No process to drive memory cost.
- Inherits uhttpd's TLS, listener layout, max-connection budget, and the
  operator's whitelist/blacklist config for free.
- No supervisor (no procd entry to maintain).

### What it costs

- No in-memory state across requests. Counters, caches, in-flight maps -
  none of it survives. The metrics and rate-limit subsystems are
  file-backed for exactly this reason.
- No timers. `commit-confirmed`-style auto-revert needs a background tick;
  the model precludes it. Deferred with prejudice (see `docs/roadmap.md`).
- Per-request VM startup cost. uhttpd-mod-ucode amortizes this via the
  parent's CoW, but the child still calls module top-level once (the
  copy-on-write avoids reparsing, not re-instantiation).

## Lock layout

Two flock files, used in three patterns:

```
/var/lock/uapi.lock                   shared by uci transactions,
                                       exclusive by non-uci writes
                                       (apk, system/access)
/var/lock/uapi.pkg.<package>.lock     exclusive per-package; serializes
                                       writes to the same uci package only
```

| Operation | Global lock | Per-package lock                          |
|-----------|-------------|--------------------------------------------|
| Read (any)         | none  | none                                       |
| uci write (any one pkg) | SH | EX on that one pkg                     |
| uci write (multi pkg, /batch) | SH | EX on each, sorted lexicographic order |
| Non-uci write (apk, system/access) | EX | none                              |

The interactions:

- Two writes against different packages: both take SH on the global file
  (compatible), each takes EX on its own per-package file → run in parallel.
- Two writes against the same package: both take SH on the global,
  contend on the per-package EX → second blocks (or returns
  `423 locked` with `Retry-After: 1` if its `LOCK_NB` attempt fails).
- A non-uci write (apk install / authorized_keys write) takes EX on the
  global → waits for any in-flight uci transaction (any package), and
  blocks new ones until done. Apk's own DB lock is downstream; the global
  EX ensures uapi never has two apk writers in flight.

All locks are non-blocking (`LOCK_NB`); contention surfaces as `423
locked` so the client can decide whether to back off and retry. The HTTP
worker never sleeps holding a lock.

Audit and verification: `docs/lock-state-audit.md` lists every fd-open and
lock-acquire site in the codebase, with proof of release on every exit path
including `die()`.

## Transaction recipe

Every write request follows this sequence. Failure at any step short-circuits
without uci state change.

0. **Pre-flight init-script check.** For each entry in the resource's
   `reload_services`, confirm `/etc/init.d/<svc>` exists and the name matches
   `^[A-Za-z0-9_-]+$`. Miss → `503 init_script_missing` with the missing path;
   no uci write attempted.
1. **Acquire flock.** SH on global + EX on the per-package file
   (non-blocking). `EWOULDBLOCK` → `423 locked` + `Retry-After: 1`.
2. **Snapshot.** `uci_export(<package>)` captures the current cursor state
   into an in-memory string.
3. **Validate.** Resource's `check_schema_types` + `validate(json, conn)`
   run inside the lock. Any field error → `422 validation_failed` with the
   full set of field errors (not fail-fast); no uci change.
4. **Stage.** `uci_set` / `uci_create_section` / `uci_delete` mutate the
   cursor (staging only).
5. **Commit.** `uci_commit(<package>)` writes the package file.
6. **Reload.** `/etc/init.d/<svc> reload` per `reload_services`, via
   `fs.popen`, exit code checked. Done directly (NOT through ubus) because
   ubus-mediated reload is fire-and-forget on OpenWrt; only `wait4` on a
   real child gives back the actual exit bit.
7. **Kernel apply.** For each peer operation the write collected (see below),
   skip it unless `network.interface.<name>` reports `up`, then run the
   matching `wg set`. Runs only after the reload returned zero, and reports the
   same way, so a failure here follows the recipe below. The interfaces actually
   applied are recorded and reported on the response as `X-Kernel-Status` and
   `X-Kernel-Applied` (`docs/errors.md` § Response headers), because a skip
   leaves the peer in uci alone and a caller otherwise cannot tell that from a
   write that reached the kernel.
8. **On reload or apply non-zero:** `uci_import(<package>, snapshot)` →
   `uci_commit(<package>)` → reload, then **reconcile** each touched interface
   against the restored uci. Then `500 reload_failed_restored` with the
   captured stderr/exit summary. If the restore itself fails,
   `500 reload_failed_unrecovered`.
9. **On success:** `200` with the refreshed resource.

### Why step 7 exists, and why it shells out to `wg`

A reload converges a daemon only when the daemon notices its config changed.
netifd reads WireGuard peers with `config_foreach wireguard_<iface>` *inside*
the proto setup step, so editing a peer leaves the parent `interface` section
untouched and `/etc/init.d/network reload` does nothing at all: the peer was
committed to uci and never reached the kernel, and deleting one did not revoke
it. `wireguard.sh` is the only proto handler under `/lib/netifd/proto/` that
reads its own uci sections, so this affects exactly one resource.

**This is a platform-wide defect, not a uapi one.** LuCI has it too, and says so
in its peer form: *"Enable / Disable peer. Restart wireguard interface to apply
changes."* Its Save and Apply resolves through
`ubus call uci apply` → `/sbin/reload_config` → a `config.change` event carrying
`{"package": "network"}` → `/etc/init.d/network reload` → `ubus call network
reload`, which is the same call uapi makes. That chain is package-granular: it
cannot express "interface wg3's peers changed", so a package-wide reload is the
only action available to it. uapi knows which resource was written and therefore
which interface is affected, so it can do better, and does.

**Why not ask netifd to re-apply.** Measured on hardware:
`ubus call network.interface.<i> renew` returns in 0 ms, so a failed apply is
undetectable, and on failure `proto_wireguard_setup` calls `proto_setup_failed`,
which takes the interface **down**. One peer with an unresolvable
`endpoint_host` dropped a working tunnel and its healthy peers while the API
answered `200`. A `down`+`up` restart behaves identically and additionally
interrupts a healthy tunnel on every peer edit. Every netifd-mediated path
applies the whole interface config as one unit, so one bad peer takes the
innocent ones with it.

`wg set` is the only per-peer path: it is atomic, so a bad endpoint fails that
one command and changes nothing, it reports a real exit code, and it leaves the
rest of the tunnel running. WireGuard exposes no ubus service for peers
(`wireguard` offers only `status`/`genkey`/`genpsk`/`pubkey`), which is why
netifd itself shells out to `wg syncconf` and LuCI's own backend shells out to
`wg`. Running `wg` is therefore not a way around the platform's abstraction for
peers, it is the platform's abstraction for peers. uci remains the only config
writer, the kernel state is derived from committed uci rather than from the
request, and nothing new runs in the background.

The one caller-supplied value that reaches the shell is `endpoint_host`. It is
quoted with the same idiom LuCI uses rather than validated, so no previously
accepted payload starts being rejected. Public keys and addresses are pattern
checked instead, since their charsets carry no shell metacharacters. A preshared
key is passed as a `0600` file on tmpfs, never as an argument, so it never
appears in `ps`.

`route_allowed_ips` asks for a route per allowed IP, which netifd installs from
the proto handler, so the apply installs them too: without that the peer is in
the kernel with no path to it and the flag only half works. They are spelled to
match netifd exactly (`proto static`, `scope link` on v4) and go into `ip4table`
/ `ip6table` when the interface sets one, since netifd puts them there rather
than in main. A prefix is only withdrawn when no remaining peer and no `config
route` section still wants it, because two peers can carry overlapping
`allowed_ips`. The kernel is never scanned for strays on the request path, only
on the reconcile that follows a rollback, so a route uapi did not install is not
at risk.

One consequence to know: netifd reports the routes it installs in
`network.interface.<name> status`, and routes installed here are not in that
list until the next `ifup`. The kernel is correct; netifd's bookkeeping lags.

A resource opts in with a `kernel_ops(kind, opts, sec_type, existing)` hook
returning the operations to apply. It reads the uci options rather than the
resource view because the view masks `preshared_key`, and the parent interface
off the section type because it is not stored as an option, so a `DELETE` can
only learn it from the section it is about to remove. A rotated public key emits
a remove for the old key before the set, or the kernel would keep the previous
peer and its access. A disabled peer is removed, matching what netifd omits when
it builds the config.

An interface that is down, or that netifd does not know, is skipped: there is no
kernel state to sync and `ifup` reads the peers from uci anyway. That is also
what keeps a peer orphaned by deleting its parent interface deletable.

## Multi-package transactions (`/batch`)

`POST /batch` composes N sub-requests under one combined snapshot/restore:

1. Pre-resolve every sub-request's target (path → package + reload services).
2. **Only WRITE sub-requests contribute to the lock/reload set.** Pure-read
   batches skip lock+snapshot+commit+reload entirely.
3. Acquire global SH + per-package EX in sorted package order
   (deadlock-free).
4. `uci_export()` each package into a snapshot.
5. Run each sub-request in order via `BARE_RESOURCES`/`BARE_SINGLETONS` -
   handlers that skip their own per-package flock + snapshot + commit + reload
   (since the outer multi_transaction has those covered).
6. First sub-request status ≥ 400 → abort: `uci_revert()` each package,
   return `{ code: "batch_partial_failure", aborted_at_index, error: ..., reverted: true }`
   with the failing sub's status.
7. All sub-requests 2xx → `uci_commit()` each package, run the union of
   reload services, then the collected kernel operations. Same failure recipe
   as the single-package transaction. Sub-requests accumulate into one ordered
   operation list shared through their sub-context, so a batch touching the same
   peer twice ends on its last state, and the restore reconciles rather than
   replaying, since a batch can apply several peers before failing on a later
   one.

## Schema layer

Every resource module exports `schema_properties`. `handler.check_schema_types`
walks it on every write to enforce:

- `type` (`string` / `integer` / `boolean` / `array` / `object` / `null`)
- `enum`
- `minimum` / `maximum`
- `pattern`
- `items` (array element schema, with index-bearing field paths like
  `tags[1]`)
- `properties` (nested object recursion)

PATCH schema-checks the WIRE DELTA only (the merged-with-existing post-image
inherits fromUci's string-form view of integer-typed fields, so type-checking
the merge would falsely 422 on integer-untouched patches). The full merged
body still goes through `resource.validate()` for cross-field logic.

### Unmodeled uci options: PUT replaces, PATCH preserves

A resource module curates a subset of its uci section's options; `toUci` emits
only those. The write path treats options outside that modeled set
differently per verb:

- **PUT (replace)** normalizes the section to the modeled set. `diff_apply`
  iterates the raw existing section and deletes every option not re-emitted by
  `toUci`, including ones the resource does not model. PUT means "this body is
  the whole resource," so uapi owns the section.
- **PATCH (partial update)** preserves unmodeled options. `diff_apply_patch`
  computes the modeled footprint as `toUci(fromUci(existing))` and only deletes
  within it (a modeled field the patch cleared). Raw uci options outside the
  footprint (which `toUci` cannot emit) are never enumerated, so a PATCH that
  touches one field leaves a hand-set or stock option like firewall `icmp_type`
  / unbound `dns64_prefix` untouched. This matches RFC 7396 merge-patch and
  avoids the silent data loss a naive delete-everything-absent would cause.

A consequence: the GET-then-PATCH-self round trip is lossless even for options
uapi does not model, but GET-then-PUT-self is not (PUT discards them). Tooling
that wants to preserve unmodeled state must use PATCH.

Field errors are deduped by `(field, code)`. Schema errors win over
validator errors for the same (field, code) tuple. The 422 body carries the
full set; clients fix everything in one round trip.

## ETag derivation

ETag = `sha256(canonical_json(body_without_runtime))`, truncated to 12 hex
chars.

`body_without_runtime` strips the resource's `runtime` block before
hashing. Runtime fields are live ubus/file state (uptime, signal, lease
count) that drifts second-to-second on unchanged config; including them
would make ETags non-deterministic and trip spurious 412s.

ETag is per-resource: a function of *this* section's content only. Sibling
sections in the same uci package do not influence each other's ETags, so
`If-Match` fires only when the resource the client is updating has
actually changed. (Cross-reference invariants like "rule's src_zone must
exist" are enforced at `resource.validate()` time on every write, not via
ETag mixing.)

Two GETs of the same unchanged section always return the same ETag.

Multi-resource collection endpoints (`GET /firewall/rules` without an id) do not currently carry an ETag. `If-Match` and `If-None-Match` only fire on resource-level endpoints; collections operate last-write-wins.

### Conditional GET

`If-None-Match: "<etag>"` (or `?if_none_match=`) on a GET: when the
response ETag matches, return `304 Not Modified` with no body and the ETag
header echoed. Cheaper for polling clients (Terraform refresh, dashboards).

### If-Match writes (precondition_check)

PUT/PATCH/DELETE with `If-Match: "<etag>"` (or `?if_match=`): when the
current ETag doesn't match, return `412 precondition_failed` BEFORE any uci
write. `If-Match: *` matches any existing resource. Absent header preserves
last-write-wins (opt-in concurrency).

uhttpd's CGI env strips `If-Match`, `If-None-Match`, `X-Request-Id`, and
`Idempotency-Key` (hard-coded allowlist in uhttpd source). All four have
`?if_match=` / `?if_none_match=` / `?request_id=` / `?idempotency_key=`
query-string fallbacks; a reverse proxy in front of uhttpd that forwards
the headers still works via the header path.

## Rate limit token bucket

Per-token bucket, file-backed at `/tmp/uapi-ratelimit/<token-id>.txt`
containing two floats: `<tokens_remaining> <last_refill_epoch_ms>`.

On each authed request:

```
elapsed_ms = now_ms - last_refill
refilled = min(burst, tokens + elapsed_ms * rate / 1000)
if refilled >= 1: allow, tokens = refilled - 1
else:             deny, retry_after = ceil((1 - refilled) * 1000 / rate)
write {tokens, last_refill = now_ms} atomically (tmpfile + rename)
```

Default rate 100/s, burst 200. Configurable via `config ratelimit { option
rate '...'; option burst '...' }` in `/etc/config/uapi`. Atomic-write
(tmpfile + rename) avoids flock contention on the hot path; the worst-case
race is one request's worth of drift across concurrent forks, bounded by
the burst size.

Worked example: default config, a client sends 250 req/s sustained against
one token. Burst absorbs the first 200; the next 50 spaced over 1s exhaust
the bucket at 100/s. Steady-state: 100/s through, 150/s rate-limited → 429.

## Metrics

File-backed under `/tmp/uapi-metrics/`. One file per (series, label-set)
combination:

```
/tmp/uapi-metrics/
  uapi_requests_total/
    method=GET/path=%2Ffirewall%2Frules/status=200.txt   "1247\n"
    method=POST/path=%2Ffirewall%2Frules/status=422.txt  "13\n"
  uapi_request_duration_seconds_bucket/
    le=0.01/method=GET/path=%2Ffirewall%2Frules.txt
    ...
  uapi_rate_limit_drops_total/
    token_id=ci_bot.txt
```

Path segments (`/` in label values) are percent-encoded as `%2F` to keep
filenames safe; decoded back when emitting. Increments are read-modify-write
with atomic rename; concurrent forks may lose increments under heavy
contention - acceptable for operational metrics, not for billing.

`GET /metrics` walks the tree, decodes the labels, emits Prometheus 0.0.4
text. Path templates are normalized (`/firewall/rules/:id` not
`/firewall/rules/r_01HX...`) to keep cardinality bounded as clients
create/destroy resources.

## Idempotency cache

`POST` requests carrying `Idempotency-Key` (header or `?idempotency_key=`)
are deduplicated for 24 h:

```
key = sha256(token_name || "|" || key)
file: /tmp/uapi-idempotency/<key>.json
contents: {
    fingerprint: sha256(token || "|" || key || "|" || body_text),
    status, headers, body
}
```

On second arrival:
- Same fingerprint → replay (`Idempotent-Replayed: true` marker header).
- Different fingerprint → `409 idempotency_key_conflict`.
- Past TTL → cache miss; the new request runs and re-populates.

Cache hits skip the entire handler stack except auth - they don't even
touch ubus. A client retrying a network-blipped POST gets the original
response back, never a duplicate resource.

## Audit and request_id

Every response carries `X-Request-Id` (a ULID by default; client-supplied
via `X-Request-Id` header or `?request_id=` query param, validated against
`^[A-Za-z0-9_-]{8,128}$`).

One syslog line per writeable request (POST/PUT/DELETE/PATCH) at NOTICE,
plus per-401/403/5xx at WARNING/ERROR. Reads are NOT audit-logged at
NOTICE level (the request_id still appears in any error line). `/healthz`
is excluded from all logging.

Format:
```
uapi <request_id> <token_name|-> <severity> <code|-> <method> <path> <status> [<duration_ms>ms]
```

Operator-facing fields use logfmt: bare for identifier-safe values,
JSON-escaped otherwise. The `request_id` correlates a wire response with
its audit line, an error report with the line, and (for batches) the
batch's request_id with each sub-request's `<request_id>.<index>` line.

## Where state lives

| State                        | Location                                   | Lifetime          |
|------------------------------|---------------------------------------------|-------------------|
| Tokens (salted hash + meta)  | `/etc/config/uapi`                          | Indefinite        |
| uci configuration            | `/etc/config/<package>`                     | Indefinite        |
| Authorized SSH keys          | `/etc/dropbear/authorized_keys`             | Indefinite        |
| DHCP leases                  | `/tmp/dhcp.leases`, `/tmp/(hosts/odhcpd|odhcpd.leases)` | Daemon-managed |
| Rate-limit buckets           | `/tmp/uapi-ratelimit/`                      | Until reboot      |
| Idempotency cache            | `/tmp/uapi-idempotency/`                    | 24 h, until reboot |
| Metrics counters             | `/tmp/uapi-metrics/`                        | Until reboot      |
| Token last-used sentinel     | `/var/run/uapi-token-update/`               | Until reboot      |
| Apk install lock             | (apk-internal)                              | Per-operation     |
| uapi global flock            | `/var/lock/uapi.lock`                       | Per-transaction   |
| uapi per-package flock       | `/var/lock/uapi.pkg.<pkg>.lock`             | Per-transaction   |

`/tmp` is tmpfs on OpenWrt: rate-limit buckets, idempotency entries, and
metrics counters reset on reboot. This is acceptable: operational
counters that span uptime aren't a uapi responsibility - point a
`node_exporter` or central collector at the box and aggregate there.
