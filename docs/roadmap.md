# Roadmap

Things deliberately not yet shipped. Each entry says why and what shape the
change would take. Update this file when an item moves between sections.

## Shipped in v2.0.0

The 35-item consolidation that paid for the major bump. Authoritative
catalog in `CHANGELOG.md`'s v2.0.0 section; migration table in
`docs/migration-v1-to-v2.md`. Highlights:

- snake_case rename across dropbear/snmpd/vnstat + strict integer typing +
  full `schema_properties` completeness sweep.
- Conditional GET, `WWW-Authenticate` on 401, inbound `X-Request-Id`,
  `/healthz` subsystem checks, `/schema/<...>`, `/auth/whoami`.
- Token expiry, IP scoping (`allowed_cidrs`), last-used tracking,
  `/tokens` HTTP route, scope subset guard on mint.
- Per-token rate limit (`429 too_many_requests`), Prometheus `/metrics`,
  idempotency keys, cursor pagination, `/diagnostics`.
- `POST /batch` (multi-package all-or-nothing), JSON Patch (RFC 6902),
  per-resource ETags + `If-Match` optimistic concurrency.
- Non-uci base library, lock-and-state audit, function-level coverage gate,
  soak harness in CI, performance benchmark gate, signed-tag verification,
  reproducible SDK pin.

## Shipped in v1.x

(Preserved for historical context; new features land under v2.x or v3.)

- **ETags / `If-Match` optimistic concurrency** in v1.2.
- **Schema-driven type check** in `handler.uc` (v1.2).
- **Round-trip property tests + adversarial fuzz harness** (v1.2).
- **Coverage inventory** (`make coverage` walks `src/resources` and
  `src/lib`; CI gates on 100% structural coverage).
- **Latency benchmark** (`make bench` reports p50/p95/p99 across
  representative reads).
- **Soak harness** (`make soak`, long read-only load loop with SSH-side
  RSS/fd/child sampling).
- **Per-package flock** (v1.2): SH on `/var/lock/uapi.lock` + EX on
  `/var/lock/uapi.pkg.<package>.lock`.
- **Security headers on every response** (HSTS, nosniff, no-referrer,
  no-store) (v1.2).
- **Central enum / min / max / pattern / items enforcement** (v1.2).
- **Per-resource validate dedup** (v1.2; -103 LOC).

## Needs more reflection

Items that are interesting but conflict with an architectural principle or
have an unresolved design question. Not "later"; "later if the right shape
appears".

### `commit-confirmed` timed rollback

Apply, wait N seconds for client `POST /commits/<id>/confirm`, auto-revert
if no ack. Cancelled in v2 planning after user-driven analysis of the
failure mode:

> If the router gets no confirmation because of a network temporary issue
> between the router and Terraform, it reverts, but Terraform thinks it's
> OK. That state-divergence is worse than the original race we're trying
> to solve.

Two viable redesigns to keep open:

1. **Sidecar with webhook-on-revert.** Auto-revert posts to a client-side
   webhook URL on rollback so the client knows to refresh its state. Breaks
   "no daemon of our own" (needs a procd-managed timer holder), but the
   sidecar is small and bounded.
2. **Fully synchronous "stage-and-test" pattern.** Stage uci changes to a
   shadow config, run a separate `POST /commit/<id>/test` request that the
   server runs internally with full reload + a programmable acceptance
   probe, and only then accept-or-revert. No timer; the entire decision is
   server-side and the wire response is the final answer.

Either path is post-v2 work; needs a real Terraform-provider use case to
drive the choice.

## Features (additive, future minor bumps in v2.x)

- **Webhooks / change notifications.** Push notification to a configured
  URL after a successful write. Needs reliable retry + dead-letter queue;
  likely needs a sidecar. Defer until there's a concrete subscriber.
- **Server-Sent Events / streaming.** Long-lived connections for log
  streaming or change feeds. Fundamentally incompatible with the
  fork-per-request model. Punt.
- **Per-field RBAC.** Granular write permissions like "can edit MTU but not
  IP on `network/interfaces`". Scope-level is enough for v2; this is
  enterprise creep. Don't add until requested by a real deployment.
- **Content-Type negotiation (YAML, msgpack).** Single-content-type
  (`application/json`) is correct for IaC. Defer indefinitely.
- **CORS.** Admin UI is LuCI; no browser-direct use case for uapi.
- **More resources.** Curation completeness rule in `CLAUDE.md`: add when a
  typical real configuration sets options the curated layer doesn't
  surface. Current gap candidates worth opportunistic curation:
  `mwan3/*`, `usteer/*` (passive band-steering daemon for OpenWrt 22+
  multi-AP setups), `openvpn/*` (the daemon is supported by uci natively).

## Hardening (next, no new wire surface)

- **Constant-time hash comparison in auth.** Today's `==` on sha256 hex is
  not constant-time; a timing-attack hardening is cheap and could close
  the side-channel disclosed under "Threat model out of scope" in
  `docs/security.md`. Worth doing.
- **Per-token request budget metrics.** `uapi_requests_total{token_id}` is
  in scope but currently uses path-templated cardinality. Adding the
  `token_id` label would let operators see who's burning the budget.
  Token IDs are stable identifiers, so cardinality is bounded by the
  total number of tokens (small).
- **`/diagnostics` ring buffer of recent errors.** Plan called for "last
  N errors from /tmp/uapi-error-ring/". Currently `/diagnostics` lists
  lock state and uptime; the ring is future work.
- **Property test coverage gate.** Every resource has fuzz coverage; CI
  could gate on a minimum number of fuzz iterations per resource per CI
  run. Today's harness is `tests/property_harness.uc`.

## Out of scope by design

- **Localization of error `message` strings.** English-only; codes are
  stable and translatable client-side.
- **Async/parallel ubus.** `conn.call()` only, by design (see Concurrency
  in CLAUDE.md).
- **In-memory caches across requests.** Forked children only; the design
  precludes them. State that must span requests lives in a file or in uci.
- **Multi-tenant scoping.** Single admin namespace. Adding multi-tenancy
  would require a richer auth model than scopes-on-tokens.
