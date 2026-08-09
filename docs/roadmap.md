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
  soak harness in CI, per-endpoint latency measurement in CI, signed-tag
  verification, reproducible SDK pin.

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
- The authz model was unsettled and freezing it would have cost a major bump to
  fix. **Now decided** (`docs/commit-confirm.md`): every operation that can move
  state, arming either way plus ack and rollback, requires `uapi:confirm:rw`
  and `:rw` on every curated resource backed by the derived package set, because
  the revert's unit is the uci package and authority has to match blast radius.
  That departs from rc1 on two counts, which is exactly why it had to be settled
  before the surface froze.

The dependency is not the blocker: `apply-confirm` 0.1.0 is released and on
the apk feed. The hold is the wire-contract commitment.

Plan: ship the whole feature once, coherently, in one minor (per-write
`?confirm` plus the standalone `POST /confirm` arm under Features below, with
one reviewed authz model). One of the two gates is now closed: the authz model
is decided and recorded, so the feature can be scoped into a minor whenever its
consumer appears. The other is not. Nothing exercises the surface, and freezing
a v2 contract that nothing uses is precisely why it came out of 2.3.0, so there
is still no target release. Design reference: `docs/commit-confirm.md`.


## Shipped in 2.5.0

The next release is a minor, and its job is as much to make a clean 3.0.0
possible as to ship features. The v3 list is in § v3 objectives above and has
grown past what a single major used to be expected to carry, which is the point:
a major is expensive to have and cheap to fill. What a minor has to do first is
serve the notice `docs/deprecations.md` requires, because the window runs from
the release that announces a removal, not the one that performs it. Cutting a
major before a minor announces the rest would break clients with no window,
spend the major, and still leave the changes unmade.

Committed, in rough dependency order:

1. **Announce the three v3 changes.** Done ahead of the rest, since the window
   runs from the release that ships it, not from the release that removes:
   `ipaddr` deprecated as a write input, and the list-reads-`null` and
   `dhcp/hosts.tag` convention changes recorded under "Announced response-shape
   changes". The `ipaddr` case carries no `deprecated: true` flag on purpose; the
   reasoning is in the deprecations log.

   `tag` carried work beyond the announcement, because the schema promised a
   string the resource does not always return: a `list tag`, which is what LuCI
   writes, already read back as an array. The read is settled in this minor rather
   than deferred: a stored scalar is split on the way out, so responses are always
   an array. Deferring it was a mistake, and the reasoning is worth keeping because
   the shape of the error recurs. The objection was to normalizing *storage*, which
   would rewrite `option tag` into `list tag` under a client that had only read the
   section. That observation was right; the conclusion that the read had to wait did
   not follow from it. What remains for the major is the write form, since a
   space-separated string is still accepted for clients generated against 2.4.1.
2. **Kernel-apply reporting.** Done: `X-Kernel-Status` and `X-Kernel-Applied`,
   mirroring the reload pair. Closes the gap the kernel apply left, where a
   client writing a peer to a down tunnel got a `200` it could not distinguish
   from one that reached the kernel. `values.platform_bool` landed alongside it,
   because reading a netifd boolean with `normalize_bool` reported the
   operator's intent rather than netifd's behaviour.
3. **`disabled` on the network resources**
   ([#64](https://github.com/openwrt-iac/uapi/issues/64)). Done. Deferred for a
   while on the grounds that netifd parses the flag differently per section type,
   which is real but does not need an upstream fix: each resource reads it with the
   helper matching its own parser rather than all three sharing one. See the
   Features entry.

4. **Validation sweep on `/diagnostics?validate=1`** (#47). Done. Reports the
   sections a write would now reject, before a write finds them one at a time.

5. **Advisory management-path guard.** Done. The cheap protection against the
   lockout class commit-confirm was meant to cover: `GET /diagnostics` reports
   `management_path`, the interface this request arrived through, and a
   `network/interfaces` write that moves that interface's `disabled`, `proto`,
   `ipaddr` or `netmask`, or deletes it, carries `X-Mgmt-Path-Warning`.

   Advisory, not a refusal: renumbering the management path is legitimate, and
   LuCI warns rather than blocking on the same four field names. Scope is LuCI's
   deliberately, with no firewall analysis, because predicting a firewall lockout
   means modelling fw4 ordering and a guess dressed as a warning is worse than
   silence. The interface comes from the kernel's route lookup rather than prefix
   containment, which is what makes it correct for an operator arriving from
   another network, the case that matters most, and what makes it work for IPv6.

   Its limit is structural and documented: if the write really does strand the
   caller, the response never arrives. `management_path` is the pre-flight half
   for anyone who wants to check first.

Decided, and deliberately still not scheduled:

- **Commit-confirmed apply.** The authz model that blocked it is settled
  (`docs/commit-confirm.md`), so that gate is closed. It stays out of 2.5.0 on
  two others, and the second is now stronger than when the feature was deferred.

  No first-party consumer exercises the surface. And a provider cannot be that
  consumer: the plugin protocol has no apply-scoped hook, and the one lifecycle
  that looks like it fits, ephemeral resources, closes its window when its own
  dependency chain finishes rather than when the apply does, so on a successful
  apply it would confirm while other resources are still being written. Measured;
  the analysis is in `docs/commit-confirm.md`. So the consumer can only be an
  operator wrapper, and an SSH wrapper gets most of the benefit at zero wire
  surface here.

  Two consequences for whenever it is picked up. The per-write `?confirm` half
  should be dropped rather than shipped: it has no consumer named in this repo and
  a multi-resource apply using it fails at the second write and reverts the first.
  And the standalone arm needs a renewal path before it is useful, which the
  NETCONF prior art has had since 2011. The near-term protection for this risk
  class is the advisory management-path guard under Features, not the timer.

Deliberately not in 2.5.0: the mirrored-name retirement itself (only its
announcement lands here, the removal is v3), and anything under Hardening, which
carries no wire surface and needs no release to take effect.

## v3 objectives

`docs/versioning.md` § What a major is for sets the policy: a major is expensive to have and
cheap to fill, so when one happens it should break as much as it needs to in order to raise
quality and remove complexity. This section is the list that makes that actionable. Anything
deferred with "needs a major" belongs here with enough detail to act on later, because the
failure mode is arriving at v3, shipping the items someone remembered, and paying the cost
again for the rest.

**Announced, with the deprecation window already running.** These carry ledger rows in
`docs/deprecations.md` and appear in the published spec's own "Upcoming in v3" block:

- `network/interfaces.name` as a create input: removed, `id` is the universal spelling.
- `network/interfaces.ipaddr` as a *write* input: removed, `ipaddrs` wins. `ipaddr` becomes
  `readOnly` rather than disappearing.
- `dhcp/hosts.mac` and `dhcp/hosts.mac_aliases`: removed entirely, `macs` is the only name.
  Neither corresponds to a real uci option, so nothing survives as a read.
- List-valued fields read back `null` rather than `[]` when the uci key is absent.
- `dhcp/hosts.tag` stops accepting a space-separated string on write.

**All announced as of 2.5.0.** The list below is now covered by `docs/deprecations.md` and
the published spec's own "Upcoming in v3" block, which the reference lint keeps in step by
count. It was not, when this section was first written: the claim that a removal with no
migration target needs no window was wrong, since the notice is for the reader, not for the
migration:

- Fields no OpenWrt component reads at all, found by auditing every option against its
  reader on a running device (`scripts/audit-dead-fields.sh`, since several of these packages
  ship only a Makefile in the SDK feed): `lldpd/config.enable_lldpmed`,
  `unbound/server.enabled`, `unbound/server.prefetch`, `mwan3/globals.rtmon_interval`,
  `mwan3/globals.local_source`, `vnstat/config.database_dir`, `interface_5min_hours` and
  `month_rotate`, `usteer/config.max_assoc_sta`, and
  `prometheus_node_exporter_lua/config.listen_ipv6` plus its seventeen collector toggles.
  Each writes a uci option the daemon ignores, and none has a correctly-named counterpart
  to point at, which is what separates them from the three below.

  `vnstat/interfaces` is on this list as a whole endpoint rather than a field: it models a
  section type vnstat never reads. `vnstat/config.interfaces` replaces it.

  Three fields that looked identical were **fixed rather than announced** in 2.5.0, because
  a correctly-named option did exist: `lldpd/config.lldp_capabilities` now writes
  `lldp_capability_advertisements`, `unbound/server.dnssec_enabled` writes `validator`, and
  `snmpd/system.sys_services` writes `sysService`. They are not part of the v3 removal set.
- `managed` leaves the request half of every resource schema. It is derived from uci's
  `.anonymous` flag and no `toUci` reads it, so a `PUT` sending `managed: false` has always
  answered 200 with `managed: true`; management state moves only through
  `POST /<resource>/{id}/adopt`. 2.5.0 annotates it `readOnly`, which is the notice a
  regenerated client acts on; v3 completes the split.

- Separate request and response schemas. One schema serves both directions today, which is
  what forces `tag` to keep `string` in its type for writers, forces `ipaddr` to be
  described in prose instead of `readOnly`, and makes any read/write asymmetry unstatable.
  This is the single change that unblocks the most others.
- ~~`412` rather than a silently-ignored precondition when `If-None-Match` arrives on a
  write.~~ Done in 2.5.0, not deferred: the precondition seam already ran before the
  transaction, so the change was a guard rather than the restructure this entry assumed.
  RFC 9110 13.1.2 requires it; doing it properly means evaluating the precondition before
  the transaction runs (13.2.2), which is a restructure rather than a guard.
- The `X-Reload-Status` / `X-Kernel-*` header set on `POST /batch`, which currently reports
  nothing about the sub-writes it performed.

**The audit gap is closed.** Five packages ship only a Makefile in the SDK feed, so their
options could not be checked against a reader from the sources: firewall4, netifd, odhcpd,
usteer and sqm-scripts. Extracting the feeds was never needed, because every one of those
readers is installed on a running device: firewall4 is ucode at `/usr/share/ucode/fw4.uc`,
sqm-scripts is shell, and a uci option name a C daemon looks up is a literal in its string
table, so `strings` answers for netifd, odhcpd and usteerd.

All 174 options those modules write were checked against the reader that consumes them, with
the harness self-checked in both directions first. An earlier run of it reported 63 dead
firewall4 options, all of them false: the corpus variable was misnamed, so the lookup ran
against nothing and everything looked unread. A sweep that finds nothing and a sweep that
reads nothing are indistinguishable from the outside, so the harness now asserts it can find
an option that is unmistakably live and cannot find an invented one.

The sweep has since been widened to every curated resource and checked in as
`scripts/audit-dead-fields.sh`, so the answer is re-runnable rather than a claim: 426 options
across all 45 modules and 18 packages, 11 with no reader, all 11 accounted for as announced,
decided or an artifact. Nothing unannounced.

One real finding, `usteer/config.max_assoc_sta`, now announced. usteer is the one package
where "the name appears in the daemon" is too weak a test: its init forwards a fixed list of
uci options over ubus, and an option missing from that list never reaches usteerd no matter
what the binary contains. `max_assoc` is in the daemon and is not on the list, so it is not
a repoint target.

**Simplification the removals unlock.** Worth doing in the same pass, since each exists only
to serve a compatibility case v3 deletes:

- `resolve_for_replace` and `merge_for_patch` on `network/interfaces` and `dhcp/hosts`. Both
  exist solely to decide which of two names for one uci option the caller meant. With one
  name per option they are dead code, along with the conflict rules in both `validate`s.
- The mirrored-pair section of `docs/adding-a-resource.md` and its carve-out, which document
  a hazard that stops existing.
- `values.normalize_bool`'s remaining callers, once the libvalidate accepted set is actually
  read out of ubox rather than guessed at. See `docs/ucode-quirks.md`.

## Features (additive, future minor bumps in v2.x)

- **`dhcp/hosts.match_tag`.** Not modelled, though LuCI exposes it on the same
  form as `tag` and dnsmasq's host handler reads it with `config_list_foreach`,
  so it is a list on both sides with none of the scalar ambiguity `tag` carries.
  Found while settling the `tag` shape. Additive, and it should be declared an
  array from the start per that decision.

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

- **Stop mirroring one uci option into two writable wire names.** Two resources
  do it: `ipaddr` / `ipaddrs` on `network/interfaces`, and `macs` / `mac` /
  `mac_aliases` on `dhcp/hosts`. One uci list option is exposed under names that
  are all readable and all writable, so a full-replace client carries every one
  of them back with the ones it did not change now stale, and every write path
  has to guess which the caller meant.
  `resolve_for_replace` and `merge_for_patch` decide that per method
  ([#60](https://github.com/openwrt-iac/uapi/issues/60),
  [#65](https://github.com/openwrt-iac/uapi/issues/65), both in 2.4.1, the
  second caused by the fix for the first) rather than removing the cause.

  The durable fix is one writable name per uci option. The list form is the
  general one, so `ipaddr` becomes read-only: still surfaced for the v1.0
  contract and for clients that only understand a scalar, but no longer
  accepted on write, with `ipaddrs` the only input.
  That is a removal from the write surface, so it needs a deprecation window
  (`docs/deprecations.md`) announced in a minor and completed in v3, not a
  patch. Until then the per-method resolution stays.

  `dhcp/hosts` is the same defect one step further along, and shows what the
  window costs. There the split was worse than a mirror: `mac` held the first
  entry of `list mac` and `mac_aliases` the rest, so no single field ever
  answered what a reservation matched, and it was the one place in the API
  where a uci list option did not surface as a JSON array. 2.5.0 adds `macs`,
  the whole list under one name, and deprecates both old names for removal in
  v3. Doing so means three writable names for one option during the window,
  which is why the rule in `docs/adding-a-resource.md` § Mirrored field pairs
  permits a new mirror only when it retires an existing one and carries a
  removal target.

- **`disabled` on `network/interfaces`, `network/routes` and `network/rules`.**
  Filed as [openwrt-iac/uapi#64](https://github.com/openwrt-iac/uapi/issues/64).
  uci carries `option disabled` on all three section types and netifd honours it
  (`config.c` skips a disabled interface, `interface-ip.c` and `iprule.c` declare
  the attribute), but none of the three models it, so an inert section reads back
  as ordinary active config and a declarative client sees a converged resource
  set with nothing to apply. It also cannot be cleared through the API, because a
  `PUT` cannot unset a field the model does not have. `network/wireguard_peers`
  already models it and is the shape to copy. Add it next to `auto` on
  `network/interfaces` rather than in place of it: `auto '0'` leaves the
  interface configured but not started at boot, `disabled '1'` makes netifd
  ignore the section outright.

  **Shipped in 2.5.0, with the asymmetry handled rather than waited out.** netifd parses the interface flag with
  a literal compare against `"1"` while route and rule go through the boolean
  blob converter, which also takes `true` (and only `true`; `on` and `yes` are
  accepted by neither, and uci drops the option instead). So on 25.12.5
  `option disabled 'true'` disables a route or a rule and leaves an interface
  running, and reading it with one truthy parse would report an interface as
  disabled while it is up. That is the same lie as the bug being fixed, inverted.

  Upstream closed the asymmetry in netifd `e97e36f`, 2026-07-16, "config: accept
  'true' for the interface disabled option", but as of 2026-08-04 no OpenWrt branch
  pinned it, master included. Waiting turned out to be the wrong call: the parser
  difference is a fact about the device, so the read follows it per section type.
  `network/interfaces` uses `strict_bool`, the other two use `platform_bool`, and a
  unit test pins the difference in both directions, because unifying them puts the lie
  back whichever way it is unified. When a branch carries `e97e36f` the interface
  helper can widen, and that test is what will say so.

  The first cut shared one helper across all three and shipped the inverted lie for a
  day: an interface carrying `disabled 'true'` read back as disabled while netifd had
  it registered and running. Caught by re-reading this entry, and measured three times
  against a reset baseline before and after.

  Two alternatives were weighed and turned down, recorded so they are not
  re-argued from scratch:

  - **Ship routes and rules now, defer interfaces.** They need nothing from
    upstream, since `values.platform_bool` is exactly right for both netifd
    versions there. Rejected because it delivers the harmless two thirds and
    defers the dangerous one, the interface being where disabling takes the
    addresses, routes and peers with it; because `disabled` on two of three
    sibling resources is an asymmetry no operator can explain from outside; and
    because the provider would add attributes twice for one issue.
  - **Ship all three and let `runtime` carry the disagreement**, the way
    `effective_proto` already exposes netifd running something other than what
    uci asked for. Closer to the house pattern, and tempting. Rejected because
    the signal is weaker than `effective_proto`'s: `disabled: true` with
    `runtime.up: true` does prove the disagreement, but `disabled: true` with
    `runtime.up: false` cannot separate disabled-and-honoured from
    enabled-but-failed, which is the case an operator most needs told apart. If
    the wait runs long enough to hurt, this is the option to revisit first.

  Additive, so a minor bump. `terraform-provider-uapi` needs matching attributes
  on `uapi_network_interface`, `uapi_network_route` and `uapi_network_rule` once
  the fields exist.

- **Standalone confirm arm over HTTP (`POST /confirm`).** The per-write
  `?confirm` never shipped (built in 2.3.0-rc1, removed before stable) and
  should not: a DAG apply is N isolated provider RPCs with no apply-level
  begin/end hook, and only one window can exist at a time, so a second
  `?confirm` write gets `409 already_armed` with its own change rolled back. The Terraform-useful shape is apply-confirm's
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

## Install the deferred packages in CI

Partly done in 2.5.0. lldpd and vnstat2 are installed by `install_uapi`'s bootstrap, about
560 KiB together, so `lldpd/config` and `vnstat/config` are exercised by
`tests/integration/49_daemon_gated_resources_test.sh` and included in the stock-config
round-trip. The install sits in the bootstrap rather than inside a test, which is what avoids
the QEMU SLIRP failure that cost hours of CI when it was tried inline.

Still outside the image, so still unexercised: snmpd, mwan3, sqm, usteer,
prometheus-node-exporter-lua and openvpn. unbound is installed by `40_unbound_uci_ext_test.sh`
but only while that test runs, which is not a guarantee another test can lean on.

The cost of leaving it is measurable rather than theoretical: `vnstat/interfaces` modelled a
section type vnstat never reads and shipped that way, because a resource for an uninstalled
package is never exercised against real configuration, so a wrong section type is
indistinguishable from a right one.

Note for whoever picks up the rest: on the standing test box the distfeeds needed pointing at
25.12.5 and the kmods feed at kernel `6.12.94-1-a7bc15f4...`, or every `kmod-*` dependency
is unresolvable.

## Hardening (next, no new wire surface)

- **Decide whether the perf bench should gate, and on what.** It measures
  per-endpoint p99 on every CI run and gates nothing: the comparison in
  `tests/bench/ci_bench.sh` runs only against a committed `bench/baseline.json`,
  which has never existed, so any size of latency regression has always shipped
  green. The naive fix is to commit a baseline, and it is probably wrong: a p99
  recorded on one GitHub runner class says little on another, so a percentage
  threshold would flake instead of catching anything, and a flaky gate gets
  ignored and then removed. The options worth weighing are an absolute ceiling
  loose enough to survive runner variance while still catching an order-of-
  magnitude regression, or leaving it as measurement and reading the numbers at
  release time. Deciding needs a few runs' worth of variance data across runners,
  which nobody has gathered. Until then the tree says measurement, not gate.

- **Finish the lock-state audit.** `docs/lock-state-audit.md` covers 17 of the 36
  sites its own reproduction command finds, and roughly seven of its line ranges have
  drifted. Nine modules are absent entirely: `error_ring`, `idempotency`, `metrics`,
  `mgmt`, `ratelimit`, `token_store`, `dhcp.leases`, `dhcp.leases6`, `dhcp.servers`. The
  doc no longer claims completeness, so this is a coverage gap rather than a false
  statement, but the missing sites are real fd and lock acquisitions with no release
  proof written down. Re-run the command, audit each site, and consider whether the count
  can be checked mechanically the way the read-honesty case list is.

- **Reporting-surface consumption is the provider's.** `X-Kernel-Status`,
  `management_path` and `?validate=1` are all emitted and documented here, and
  `terraform-provider-uapi` consumes none of them. That is the provider's call, not a gap
  in this repo, and it is recorded here only so the question is not re-opened as uapi
  work.

- **Derive the property-fuzz resource list from the resource registry.**
  `tests/unit/read_honesty_test.uc` now does exactly this and is the pattern to
  copy: it walks `src/resources/` and fails naming any module with a `validate()`
  that has no case, so the list cannot fall behind the tree.
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
