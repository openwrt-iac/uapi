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

### `commit-confirmed` timed rollback (shipped 2.3.0)

Resolved by the sidecar path (option 1 below), built as a separate package
(`apply-confirm`) so uapi gains no daemon of its own; uapi integrates by
invoking its CLI. See `docs/commit-confirm.md`. The original
state-divergence objection ("the router reverts but Terraform thinks it's OK")
is handled by making the ack client-driven: a confirmed write returns 202 + a
token, and the client confirms only after verifying reachability. If the client
never sees the response, it also never acks, so its own apply is not marked
complete; the auto-revert and the client's view stay consistent.

Sequencing: the wire surface ships in 2.3.0 but the 2.3.0 tag is held until
`apply-confirm` reaches a stable, feed-published release (it is a safety
primitive that soaks RC-first). The integration is optional and
feature-detected, so an install without apply-confirm is unaffected.

The original v2-planning analysis, kept for context:

> If the router gets no confirmation because of a network temporary issue
> between the router and Terraform, it reverts, but Terraform thinks it's
> OK. That state-divergence is worse than the original race we're trying
> to solve.

The webhook-on-revert refinement (push a rollback notification to the client)
remains open as a future enhancement, not a requirement. The fully-synchronous
"stage-and-test" pattern is now specified concretely as a standalone HTTP arm
endpoint under Features below.

## Features (additive, future minor bumps in v2.x)

- **Standalone confirm arm over HTTP (`POST /confirm`).** The per-write
  `?confirm` shipped in 2.3.0 cannot wrap a whole `terraform apply`: a DAG
  apply is N isolated provider RPCs with no apply-level begin/end hook, and
  each `?confirm` mints a separate last-writer-wins window, so they never
  merge into one transaction. The Terraform-useful shape is apply-confirm's
  `stage` primitive (arm once over a package set, ack once after the apply)
  exposed over HTTP, so a wrapper can arm, run the apply, then ack or let it
  auto-revert with no SSH hop. `ac_stage` already exists and the bare
  `POST /confirm` slot is free (currently 405). Locked design constraints if
  built: the body names curated **resources/scopes, never raw packages**, and
  uapi derives the package set and reload-service union from `RESOURCE_SOURCES`
  (the same fold `/batch` does), which keeps the union correct-by-construction
  and client strings out of the shell. Authz requires `uapi:confirm:rw` **and**
  `:rw` on every curated resource backed by the *derived* package set, not just
  the resources named: apply-confirm reverts whole uci packages while scopes
  are per-resource and one package backs many (`network` backs 7 scopes,
  `firewall` 5, `dhcp` 6), so package-granularity authz is the only way the
  deadline auto-revert cannot restore a resource the caller could not write.
  New endpoint, so a minor bump (2.4.0+), not a 2.3.x patch. Defer the merge
  until `apply-confirm` is feed-stable and a concrete consumer asks: the
  provider stays Option A (write path untouched) and the wrap is operator-
  driven. Two residual hazards want a reference wrapper-with-ack/rollback-trap
  shipped alongside, not prose alone: the box-global single-pending lock is
  held for a whole apply (serializing other operators, per-write confirms,
  LuCI, and parallel CI), and a forgotten ack reverts the entire armed package
  to its arm-time snapshot, silently undoing sibling-resource changes a
  partially-failed apply already committed. Origin: terraform-provider-uapi
  integration feedback.
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
- **`unbound/server` listen-address / interface binding.** Field
  feedback (v2.0.0 migration) flagged the inability to bind unbound to
  a specific address (loopback-only recursive backend behind dnsmasq,
  `127.0.0.1@5353`). Blocked upstream: OpenWrt's
  `/usr/lib/unbound/unbound.sh:386` carries an explicit `# TODO: add
  UCI list for interfaces to bind`. The only knobs the init script
  reads today are `listen_port`, `interface_auto`, and the per-trigger
  `interface` (used for reload gating, not bind), so there is no uci
  surface to curate. Path forward: open a PR against the OpenWrt
  unbound package adding `list interface_bind '...'` (and likely
  `list interface_outgoing '...'`), then curate the new options here
  once a release ships them. Floor option if upstream rejects or
  takes too long: a non-uci `unbound/extra_server_conf` resource
  writing `/etc/unbound/unbound_srv.conf` (high bar per
  `docs/non-uci-state.md`; only if option (a) genuinely stalls).

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
