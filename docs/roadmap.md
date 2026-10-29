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

(Preserved for historical context; new features land under v3.x.)

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

2.5.0 was a minor, and its job was as much to make a clean 3.0.0
possible as to ship features. The v3 list is in § Shipped in 3.0.0 below and had
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
   helper matching its own parser rather than all three sharing one.

   **The asymmetry was handled rather than waited out.** netifd parses the interface flag with
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

4. **Validation sweep on `/diagnostics?validate=1`** (#47). Done. Reports the
   sections a write would now reject, before a write finds them one at a time.

5. **Advisory management-path guard.** Done. The cheap protection against the
   lockout class commit-confirm was meant to cover: `GET /diagnostics` reports
   `management_path`, the interface this request arrived through, and a
   `network/interfaces` write that moves that interface's `disabled`, `proto`,
   `ipaddrs` or `netmask`, or deletes it, carries `X-Mgmt-Path-Warning`.

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

## Shipped in 3.0.0

Everything 2.5.0 announced, plus the simplification the removals unlocked. The ledger's
`Removed in past releases` section and `docs/migration-v2-to-v3.md` are the operator-facing
record; this is the engineering one.

**Removals**, all announced in the 2.5.0 spec's own "Upcoming in v3" block:

- `network/interfaces.name` as a create input; `id` is the only section-name input.
- `dhcp/hosts.mac` and `mac_aliases`; `macs` is the only name.
- The 27 fields writing a uci option no OpenWrt component reads, across `mwan3/globals`,
  `vnstat/config`, `lldpd/config`, `unbound/server`, `usteer/config` and
  `prometheus_node_exporter_lua/config`, which drops from 20 modelled fields to 2.
- `vnstat/interfaces` as a whole endpoint, replaced by `vnstat/config.interfaces`.

**Convention changes:**

- List-valued fields read back `null`, not `[]`, when the uci key is absent
  ([#39](https://github.com/openwrt-iac/uapi/issues/39)). 46 properties. The issue's stated
  scope of 32 was stale and its derivation query missed the 13 arrays nested under the
  writable `match` objects, so re-derive rather than trusting a recorded count.
- Every resource is described by `<Name>Request` and `<Name>Response`. This is what makes
  `managed` absent from request models, `network/interfaces.ipaddr` `readOnly`, and
  `dhcp/hosts.tag` array-only in both directions: one schema serving both directions could
  state none of them. The 13 singletons gained a real request schema in place of an untyped
  object.
- The mount moved to `/api/v3`, as it moved to `/api/v2` across the previous major. The
  install hook strips every older prefix, because a leftover mount would serve the removed
  surface under v3 semantics.

**Additive, and the one item that was never announced because it did not need to be:**

- `POST /batch` reports its transaction outcome on the 207, aggregated over the sub-writes.
  It cannot be per-operation: the results array carries `{status, body}` and drops
  sub-response headers, which is the same reason the management-path guard is inert inside a
  batch.

**Simplification the removals unlocked**, all dead code once the mirrored names were gone:
`merge_for_patch` and `resolve_for_replace` on both `dhcp/hosts` and `network/interfaces`,
`equal_list`, the mirrored-pair conflict rules in both `validate`s, and the
`resolve_for_replace` seam in `handler.uc` along with its contract in
`docs/adding-a-resource.md`.

**Not done, and deliberately:** retiring `values.normalize_bool`'s remaining callers. The
precondition is reading libvalidate's accepted set out of ubox rather than guessing at it, and
that has not happened. It could change which strings are accepted on the wire, so acting on a
guess is the opposite of what a major is for. See `docs/ucode-quirks.md`.

## Shipped in 3.1.0

- **`system/cron_jobs`**, the first resource over `/etc/crontabs/root`. It was not on this
  roadmap: it came from asking whether LuCI's Scheduled Tasks page could be an API surface
  ([#192](https://github.com/openwrt-iac/uapi/issues/192)). Reads follow busybox crond's own
  parser, including line continuation, and writes refuse what OpenWrt's crond misreads.
- **`dhcp/hosts.match_tag`**, the roadmap's one ready additive feature. Measured with a real
  DHCP client before it shipped: it works with tags dnsmasq sets from the request, such as a
  vendor class, while `known` and the range's own tag never match, whatever LuCI's help says.
- **`dhcp/hosts` stopped passing dnsmasq syntax through `name` and `tag`**, which allowed a
  newline in `name` to add any dnsmasq directive. One check in `values.uc` now covers every
  field that lands in the `dhcp-host` line.
- **A full filesystem no longer empties `authorized_keys` or the crontab.** ucode's `close()`
  drops `fclose`'s error, so a write that ran out of space renamed an empty file over the old
  one and answered 200. The shared writer now checks that the file holds every byte that it
  wrote.
- **Package installs survive a feed rebuild.** `apk add` refreshes a stale index on its own
  only after 4 hours, so an install now refreshes and retries once when it fails
  ([#191](https://github.com/openwrt-iac/uapi/issues/191)).
- **The changelog is written in each PR and checked by CI**, on the Grafana Mimir model, and a
  ruleset on `main` requires that check and the CI jobs.

## Shipped in 3.2.0

- **Reads follow what netifd and the scripts read.** `network/interfaces`, `routes`, `rules`,
  `devices`, `bridge_vlans` and `wireguard_peers` read a hex or octal integer, a scalar list as
  its words, a table name as its id and a service name as its port, as netifd, `wireguard.sh`
  and wg do. Before, a PUT of a read could remove the ports of a bridge, move a route into the
  main table or change the port of a tunnel.
- **`network/interfaces` knows which proto takes which field.** A write refuses a field that the
  proto does not take, a read omits it, and a PATCH that changes `proto` removes the options of
  the old one. The options that netifd reads on every proto, such as `metric`, `ip4table`,
  `ip6hint` and `ip6ifaceid`, apply to every proto, and `sourcefilter`, `ip6class`, `ip6weight`
  and `broadcast_flag` are new.
- **A write that the daemon refuses or ignores no longer answers 200.** An `mtu` that netifd or
  pppd does not apply, table 0, a `goto` that the kernel refuses and a raw option that uci
  cannot store answer 422, and a package with no file under `/etc/config/` answers
  `503 config_missing`. A commit that libuci refuses answers an error, and a `POST /batch` then
  restores what it committed and runs no reload and no kernel apply (#277). A `dhcp_option`
  entry in which an address is followed by whitespace and a second option answers 422, and a
  write whose generated config `dnsmasq --test` refuses answers `500 reload_failed_restored`
  and restores the previous config (#279). The request schemas declare the bounds that a write
  accepts, through `x-uapi-write`. A write to `dhcp/servers`, `dhcp/hosts` or the raw `dhcp`
  package reloads odhcpd too, and one to `dhcp/odhcpd` reloads dnsmasq too, while procd runs
  that daemon, so neither daemon keeps its old config after a write that answered 200 (#280).
- **A PUT of the read of a radio or an SSID keeps its hardware binding and its 802.11r group.**
  Before, the first apply that changed a radio removed its `path`, and the radio stayed down
  with all its SSIDs.
- **Raw writes answer with what uci stored**, refuse what uci cannot store, and remove an option
  for `null` and `""`. Every write reads the package only after it takes the lock, so a commit
  by LuCI just before it is no longer invisible to it.
- **Audits of the values that reach a root shell or a daemon config.** A WireGuard peer's
  `allowed_ips` and a stored `persistent_keepalive` reached a root shell, `endpoint_host` and a
  wireless `key` added lines to a daemon config, a raw `.type` passed the scope check as another
  type, and an IPv6 `allowed_cidrs` entry could admit every address. Each one is fixed. The
  values that init scripts copy into the configs and commands of snmpd, dnsmasq, unbound, lldpd,
  mwan3, netifd and wifi-scripts refuse the characters that end a line or an argument, and
  `docs/security.md` lists the write scopes that reach root.
- **Values that a daemon refuses or misreads answer 422.** A wireless `ssid` over 32 bytes, a
  `key` in a form that hostapd or wpa_supplicant refuses, mode `wds`, a dnsmasq value with a
  double quote, an lldpcli value with a backslash and an snmpd access without a `context` no
  longer answer 200 while the daemon fails. A WireGuard peer reads its keys, prefixes, host,
  keepalive and list options as wg, netifd and wireguard.sh do, so the apply, the restore and
  the route withdraw act on the peer that the kernel holds. The response schemas of the curated
  resources declare no `pattern`. The items of
  [#249](https://github.com/openwrt-iac/uapi/issues/249) that 3.2.0 does not fix stay open
  there, and the newline rule moves to [#276](https://github.com/openwrt-iac/uapi/issues/276).
- **A write that makes a daemon read stored values checks them.** Turning a radio on, giving it
  a type, moving an SSID onto an enabled radio, switching an interface to wireguard and enabling
  a wireguard interface check the stored values of its SSIDs or peers that the daemon would
  refuse, and a write after which unbound stops answers an error instead of 200 (#259 to #262,
  #272). The restore of the peers of an interface no longer stops at a peer without a key or
  without allowed IPs (#272).
- **A merge PATCH has its own schema.** Each `<Name>Patch` has the properties of `<Name>Request`
  without `required`, conditionals or defaults, and takes null where the server removes the
  field, so a strict client sends what the server takes (#258, #263).
- **A write answers what uci then holds.** The body and the ETag of a write come from the
  section that it staged, and a PATCH that changes nothing writes nothing, keeps the comments of
  the package (#272, #275), and runs no reload and no kernel apply (#277). An option that a
  daemon splits into words, such as an lldpd `interface` or a dnsmasq `dhcp_option` or `mac`,
  reads as its words (#274), and `wireless/devices` reads its numbers as netifd does (#257).
- **The state that uapi keeps in tmpfs is private.** The idempotency cache, the metrics, the
  rate-limit buckets, the error ring and the last-used markers of the tokens keep their files
  under `/var/run`, in directories of mode 0700 with files of mode 0600 (#266, #270).

## Features (additive, future minor bumps in v3.x)

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

- **Upstream: widen the interface `disabled` reader once 25.12 carries netifd `e97e36f`.**
  netifd accepts `disabled 'true'` on an interface since that commit, 2026-07-16, so
  `network/interfaces` can then read the flag with `platform_bool` like routes and rules.
  As of 2026-10-28, OpenWrt `main` pins a netifd from 2026-10-28, which carries it, but
  `openwrt-25.12` still pins 2026-02-26, and so does 25.12.6. The unit test that pins the
  per-type difference is what will say when the widening is right.

- **Standalone confirm arm over HTTP (`POST /confirm`).** The per-write
  `?confirm` never shipped (built in 2.3.0-rc1, removed before stable) and
  should not: a DAG apply is N isolated provider RPCs with no apply-level
  begin/end hook, and only one window can exist at a time, so a second
  `?confirm` write gets `409 already_armed` with its own change rolled back. The Terraform-useful shape is apply-confirm's
  `stage` primitive (arm once over a package set, ack once after the apply)
  exposed over HTTP, so a wrapper can arm, run the apply, then ack or let it
  auto-revert with no SSH hop. `ac_stage` exists only in the reverted rc1 code
  (commit `a85a5cd`), and the bare
  `POST /confirm` slot is free (unrouted, so 404 like any unknown path). Locked design constraints if
  built: the body names curated **resources/scopes, never raw packages**, and
  uapi derives the package set and reload-service union from `RESOURCE_SOURCES`
  (the same fold `/batch` does), which keeps the union correct-by-construction
  and client strings out of the shell. Authz requires `uapi:confirm:rw` **and**
  `:rw` on every curated resource backed by the *derived* package set, not just
  the resources named: apply-confirm reverts whole uci packages while scopes
  are per-resource and one package backs many (`network` backs 6 scopes,
  `firewall` 6, `dhcp` 6), so package-granularity authz is the only way the
  deadline auto-revert cannot restore a resource the caller could not write.
  Corollary for operators: the wrap token is necessarily broader than the
  apply it guards (wrapping a `network:routes`-only apply needs `:rw` on all
  6 `network`-backed resources, since the revert can restore any of them), so
  the guide must say "mint the wrap token at package granularity" or a narrow
  token gets a confusing 403 on arm. New endpoint, so a minor bump, not a
  patch. Defer the merge until `apply-confirm` is feed-stable and a
  concrete consumer asks: the
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
  IP on `network/interfaces`". Scope-level is enough today, and this is
  enterprise creep. Don't add until requested by a real deployment.
- **Content-Type negotiation (YAML, msgpack).** Single-content-type
  (`application/json`) is correct for IaC. Defer indefinitely.
- **CORS.** Admin UI is LuCI; no browser-direct use case for uapi.
- **More resources.** Curation completeness rule in `docs/adding-a-resource.md`: add when a
  typical real configuration sets options the curated layer doesn't
  surface.
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

- **A request that uhttpd kills after its commit leaves the write half done.** uhttpd
  sends `SIGKILL` to the request process, and to no other, when the client closes the
  connection before the response and when `script_timeout` runs out (60 s unless set). A
  Terraform interrupt or a client-side timeout does the first. No ucode code runs after a
  `SIGKILL`. `transaction()` commits, then reloads, runs the stay-up watch and the kernel
  apply, and after a failure restores the snapshot and reloads again, all in that process.
  A kill after the commit leaves uci with the new config, runs no check and no restore, and
  answers nothing. The reload that the request started runs on, and since the lock fds
  close on exec the kill also releases the lock, so the next write can commit and reload
  beside it. `multi_transaction()` and the crontab apply in `crontab.uc` have the same
  shape. The steps after the commit are not short: each reload, the stay-up watch, which
  waits up to 2 s and again on a restore, and the kernel apply.
  Nothing inside the request can close this, so it needs a design change. The shapes seen
  so far, none chosen:
  - A record of the write in flight, written before the commit and removed when the
    recipe ends, which the next request that takes the lock of the package finds. It could
    report the interrupted write, which adds wire surface, or finish it, which needs a
    decision on whether one request may restore a write that is not its own.
  - The steps after the commit in a process that uhttpd does not kill. That is work that
    outlives the request, which `docs/concurrency.md` rules out, and the client still gets
    no answer.
  - A change to uhttpd to send `SIGTERM` and wait before `SIGKILL`, so that a request can
    ignore it with ucode's `signal()` until its recipe ends. That is upstream work, and the
    wait would bound how long a recipe may take.
  The details are under Open findings in `docs/lock-state-audit.md`.

- **Reporting-surface consumption is the provider's.** `X-Kernel-Status`,
  `management_path` and `?validate=1` are all emitted and documented here, and
  `terraform-provider-uapi` consumes none of them. That is the provider's call, not a gap
  in this repo, and it is recorded here only so the question is not re-opened as uapi
  work.

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
- The property-fuzz pass derives its resource list from `src/resources/` since
  3.2.0 (`tests/unit/property_test.uc`). It skips the read-only collections
  (`dhcp.leases`, `dhcp.leases6`), which have no `validate()`, and fails naming
  any other module without one. The hand-written list it replaced had left
  `unbound.srv` and `unbound.ext` unfuzzed. `tests/unit/read_honesty_test.uc`
  walks the same directory, but only to check that its hand-written cases cover
  every writable module.
- The lock-state audit is complete. It covered 16 of the 36 sites its command found,
  and that command missed every ubus connection, every uci cursor and the lock
  acquisitions of `multi_transaction()`. `docs/lock-state-audit.md` now has a release
  proof for each site the wider command finds, and `make lint-lock-audit` fails when a
  site is missing from its table or a range no longer holds one. The defects the audit
  found that are not fixed yet are recorded there under Open findings. The unchecked
  writes of a preshared key file and of a feed file, the shared temp file of the error
  ring, the rename checks of the error ring and the metrics, which never ran, and a
  revoke that dropped its rate-limit bucket before the commit are fixed (#267). The
  restore replaces the package with a rename, and the uci cursor no longer reads or
  commits what a shell staged (#268). The lock files close on exec, so a request that
  uhttpd kills no longer leaves its lock to the children it started, a mint or a revoke
  reaps the files in tmpfs of the tokens that no longer authenticate, a path that no
  route serves adds no metric files, and `uapi-token` takes the uapi lock (#269).
  Two idempotency stores of one key no longer share a temp file (#270).

## Objectives for the next major

- **Routes `table` and rules `lookup` accept table names on write.** netifd resolves both
  through `/etc/iproute2/rt_tables`, and LuCI writes the name. Since 3.2.0 a read resolves a
  stored name to its id, so the integer type stays and a PUT of the read writes the id. Taking
  a name on write needs the type to become a string or a union, which is breaking under
  `docs/versioning.md` ([#240](https://github.com/openwrt-iac/uapi/issues/240)).

- **`network/interfaces.ip6prefix` stops taking a string on write.** Since 3.2.0 a read is
  always an array, and a write still takes the space-separated string that the 3.1 spec
  declared ([#241](https://github.com/openwrt-iac/uapi/issues/241)). The removal deletes, in one
  go: `"string"` in the type, the `x-uapi-write-string` marker and its branch in
  `build/gen_openapi.uc` (the check in `tests/lint_openapi_shape.uc` that no source marker
  reaches the spec stays), the string path in `toUci` and `validate()`, the sentence in the
  field description, the row in `docs/deprecations.md` and the `ip6prefix` example in
  `docs/versioning.md`, and it adds a row to the v3-to-v4 migration document.

- **One rule for newlines in curated strings.** 3.2.0 refuses a newline field by field, after an
  audit of the daemon that reads each field, and each new field that a daemon reads as one line
  needs the same audit. About a third of the writable string fields still take a newline or a
  carriage return, and only `system.notes` holds several lines on purpose. A default refusal of
  both in `check_schema_types`, with an opt-out annotation for `system.notes`, ends the audits.
  It is breaking for the free-text fields, such as descriptions, where no daemon gives the
  evidence that the tightening carve-out needs
  ([#276](https://github.com/openwrt-iac/uapi/issues/276)).

- **`mwan3/interfaces.family` is required, or an unset one reads as `ipv4`.** mwan3 reads an
  unset family as ipv4 (`mwan3.sh` and `mwan3track` both default it), and a read gives null. The
  spec requires the key and takes null, and `validate()` does not require a value. So on the
  stock `wan6`, which sets `family 'ipv6'`, `PATCH {"family": null}` answers 200, and mwan3 then
  handles wan6 as IPv4 while the read says null. Since 3.2.0 the field description says that a
  null removes the option and that mwan3 then uses ipv4. Refusing the null tightens what a write
  takes, and reading `ipv4` changes what a read of an unset family gives, so either waits for
  the major.

- **A `wireless/interfaces` section with no `mode` reads as null instead of `ap`.** wifi-scripts
  sets up nothing for such a section, because its switch on the mode skips an absent mode as it
  skips any mode that it does not know (`mac80211.sh:260`). uapi reads the section as `ap`, so a
  read reports an access point that does not exist. The read change is breaking, because the
  Response then takes null and every such section reads differently.

- **Whether to check every field at each save, as LuCI does.** LuCI validates each visible field
  of a form when it saves, so a stored value that breaks a rule blocks every save of the section
  until it is fixed. For the rules in `validate_new()`, uapi refuses a write only for an error
  that the write adds (`new_errors()` in `src/lib/handler.uc`): one in a field that it changes,
  one that the section did not have, or a dormant one that it makes live. So a write that leaves
  a stored value alone passes, even one that only disables the section, and
  `GET /api/v3/diagnostics?validate=1` lists the value. LuCI's model refuses writes that 3.1.0
  accepts, so adopting it is breaking.

## Out of scope by design

- **Localization of error `message` strings.** English-only; codes are
  stable and translatable client-side.
- **Async/parallel ubus.** `conn.call()` only, by design (see
  `docs/concurrency.md`).
- **In-memory caches across requests.** Forked children only; the design
  precludes them. State that must span requests lives in a file or in uci.
- **Multi-tenant scoping.** Single admin namespace. Adding multi-tenancy
  would require a richer auth model than scopes-on-tokens.
