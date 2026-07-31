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

### `commit-confirmed` timed rollback (built, deferred from 2.3.0)

Built and validated, then deferred out of 2.3.0 stable. The sidecar path
won: a separate package (`apply-confirm`) owns the durable rollback timer
and snapshot state so uapi gains no daemon of its own; uapi integrates by
invoking its CLI. A confirmed write returns `202` + a token via per-write
`?confirm=<seconds>`, and the ack is client-driven, which resolves the
original state-divergence objection (the client acks only after verifying
reachability, so a lost response prevents both the ack and the client
marking its own apply complete):

> If the router gets no confirmation because of a network temporary issue
> between the router and Terraform, it reverts, but Terraform thinks it's
> OK. That state-divergence is worse than the original race we're trying
> to solve.

The full per-write surface shipped in 2.3.0-rc1 and was soaked on live
hardware, then removed before stable (recoverable from commit `a85a5cd`).
Why deferred rather than shipped:

- No first-party consumer: the Terraform provider ships 2.3.0 without
  consuming confirm, so the surface would enter a permanent v2 contract
  with nothing exercising it.
- The authz model is unsettled and freezing it would cost a major bump to
  fix. Per-write arming currently rides the write's own resource `:rw` with
  no `uapi:confirm` requirement, and ack/rollback are window-agnostic (a
  `uapi:confirm:rw` token can ack any window); the package-granularity
  escalation analysis (a per-write arm snapshots and reverts the whole uci
  package, not just the resource written) suggests these may need to change.
  Committing them to v2 now forecloses that without a 3.0.0.

The dependency is not the blocker: `apply-confirm` 0.1.0 is released and on
the apk feed. The hold is the wire-contract commitment.

Plan: ship the whole feature once, coherently, in a 2.4.0 (per-write
`?confirm` plus the standalone `POST /confirm` arm under Features below,
with one reviewed authz model), gated on a settled authz model and a
concrete consumer. Design reference: `docs/commit-confirm.md`.


## Features (additive, future minor bumps in v2.x)

- **`X-Kernel-Applied` response header.** The kernel-apply step added in 2.4.1
  (`docs/architecture.md` § Transaction recipe, step 7) skips an interface that
  is down or that netifd does not know, since there is no kernel state to sync
  and `ifup` reads the peers from uci anyway. That means a client writing a peer
  to a down tunnel gets a `200` whose config is in uci but not in the kernel,
  with no way to tell it apart from a `200` that did reach the kernel. A header
  naming what was actually applied, mirroring `X-Reload-Services`, closes that.
  Held out of 2.4.1 because a new header is additive wire surface, which
  `docs/versioning.md` puts outside a patch release.

- **Upstream: one unresolvable peer endpoint should not take a tunnel down.**
  Filed as [openwrt/openwrt#24511](https://github.com/openwrt/openwrt/issues/24511).
  `wg syncconf` is all or nothing and the proto handler escalates any failure to
  `proto_setup_failed`, so a peer whose endpoint hostname does not resolve stops
  the interface coming up at all, healthy peers included. Measured: `up=false`,
  zero peers, no addresses, netifd retrying and giving up.

  This is the half that still matters to us. The `wg set` apply protects the
  *write*, not the *boot*: a peer whose endpoint resolves when written and stops
  resolving later sits in uci, and the next reboot runs it through the proto
  handler and drops the tunnel. No amount of local code fixes that, because the
  platform owns the boot path.

  The **peer change detection** half needs nothing from us. It was reported
  twice, on the devel list in 2023 and as
  [netifd#66](https://github.com/openwrt/netifd/pull/66) in 2026, and neither
  landed in that form; it is instead solved in master by the ucode proto rewrite
  (`package/network/utils/wireguard-tools/files/wireguard.uc`), whose `config`
  function loads peers so the framework's change detection covers them. That
  rewrite also fixed route metrics
  ([#23199](https://github.com/openwrt/openwrt/issues/23199)) but left
  `proto.setup_failed()` exactly as it was.

  Neither outcome retires `src/lib/wg.uc`. Even with both fixed, a netifd-driven
  apply stays asynchronous, so uapi still could not report whether a write
  reached the kernel, which is what the transaction contract needs. Retiring the
  local code would take netifd applying peer deltas synchronously, which is not
  on anyone's roadmap.

- **Standalone confirm arm over HTTP (`POST /confirm`).** The per-write
  `?confirm` shipped in 2.3.0 cannot wrap a whole `terraform apply`: a DAG
  apply is N isolated provider RPCs with no apply-level begin/end hook, and
  each `?confirm` mints a separate last-writer-wins window, so they never
  merge into one transaction. The Terraform-useful shape is apply-confirm's
  `stage` primitive (arm once over a package set, ack once after the apply)
  exposed over HTTP, so a wrapper can arm, run the apply, then ack or let it
  auto-revert with no SSH hop. `ac_stage` already exists and the bare
  `POST /confirm` slot is free (unrouted, so 404 like any unknown path). Locked design constraints if
  built: the body names curated **resources/scopes, never raw packages**, and
  uapi derives the package set and reload-service union from `RESOURCE_SOURCES`
  (the same fold `/batch` does), which keeps the union correct-by-construction
  and client strings out of the shell. Authz requires `uapi:confirm:rw` **and**
  `:rw` on every curated resource backed by the *derived* package set, not just
  the resources named: apply-confirm reverts whole uci packages while scopes
  are per-resource and one package backs many (`network` backs 7 scopes,
  `firewall` 5, `dhcp` 6), so package-granularity authz is the only way the
  deadline auto-revert cannot restore a resource the caller could not write.
  Corollary for operators: the wrap token is necessarily broader than the
  apply it guards (wrapping a `network:routes`-only apply needs `:rw` on all
  7 `network`-backed resources, since the revert can restore any of them), so
  the guide must say "mint the wrap token at package granularity" or a narrow
  token gets a confusing 403 on arm. New endpoint, so a minor bump (2.4.0+),
  not a 2.3.x patch. Defer the merge
  until `apply-confirm` is feed-stable and a concrete consumer asks: the
  provider stays Option A (write path untouched) and the wrap is operator-
  driven. Two residual hazards want a reference wrapper-with-ack/rollback-trap,
  owned by the provider repo (the concrete consumer), not prose alone: the
  box-global single-pending lock is held for a whole apply (serializing other
  operators, per-write confirms, LuCI, and parallel CI, so no parallel CI
  against one box), and a forgotten ack reverts the entire armed package to its
  arm-time snapshot, silently undoing sibling-resource changes a partially-
  failed apply already committed. The wrapper's ack-vs-rollback must key on
  management-path reachability, not `terraform apply`'s exit code: a partial
  failure where the box is still reachable should ack (Terraform has already
  recorded the resources that succeeded, so acking keeps the box consistent
  with state); only an unreachable box should be left to auto-revert (`apply;
  if reachable then ack else let-expire`, never `if exit 0 then ack`). Origin:
  terraform-provider-uapi integration feedback.
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

- **Derive the property-fuzz resource list from the resource registry.**
  `tests/unit/property_test.uc` keeps `RESOURCES` as a hand-written literal, so a
  new curated resource gets no fuzz coverage until somebody remembers to add it.
  That is how `unbound.srv` and `unbound.ext` went unfuzzed: both are writable and
  both have a `validate()`, and neither was in the list. They are in it now, but
  the next resource can slip the same way. The read-only collections
  (`dhcp.leases`, `dhcp.leases6`) have no `validate()` and are correctly excluded,
  so a derived list needs that one filter.

Everything else this section used to list has shipped, and the section had gone
stale enough to be misleading:

- Constant-time hash comparison in auth landed in v2.0.0
  (`values.constant_time_equals`, used at `src/lib/auth.uc`).
- `uapi_requests_total` already carries the `token_id` label
  (`src/lib/metrics.uc`).
- `/diagnostics` already returns `recent_errors` from the ring buffer
  (`src/lib/error_ring.uc`, exposed in `src/main.uc`).
- CI already runs the property pass at a fixed 1000 iterations per resource
  (`PROPERTY_ITERS=1000 make test-property`), which was the iteration gate this
  section asked for.

## Out of scope by design

- **Localization of error `message` strings.** English-only; codes are
  stable and translatable client-side.
- **Async/parallel ubus.** `conn.call()` only, by design (see Concurrency
  in CLAUDE.md).
- **In-memory caches across requests.** Forked children only; the design
  precludes them. State that must span requests lives in a file or in uci.
- **Multi-tenant scoping.** Single admin namespace. Adding multi-tenancy
  would require a richer auth model than scopes-on-tokens.
