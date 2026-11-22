# Roadmap

Things deliberately not yet shipped. Each entry says why and what shape the
change would take. Update this file when an item moves between sections.

## Shipped

The section of each release in `CHANGELOG.md` is the full record.

- [3.5.0][r350]: interrupted writes in diagnostics, request bounds in uci.
- [3.4.0][r340]: the v4 program announced in the spec and the deprecations log.
- [3.3.0][r330]: the kernel view of WireGuard peers, bounded body reads.
- [3.2.0][r320]: reads follow the daemons, and a write they refuse answers 422.
- [3.1.0][r310]: `system/cron_jobs` and `dhcp/hosts.match_tag`.
- [3.0.0][r300]: the removals that 2.5.0 announced, and the `/api/v3` mount.
- [2.5.0][r250]: kernel-apply headers, `disabled` on network resources.
- [2.0.0][r200]: the 35-item consolidation behind the v2 major.
- [1.2.0][r120]: ETags, the schema type check and the per-package locks.

[r350]: https://github.com/openwrt-iac/uapi/blob/main/CHANGELOG.md#350---2026-11-21
[r340]: https://github.com/openwrt-iac/uapi/blob/main/CHANGELOG.md#340---2026-11-04
[r330]: https://github.com/openwrt-iac/uapi/blob/main/CHANGELOG.md#330---2026-11-03
[r320]: https://github.com/openwrt-iac/uapi/blob/main/CHANGELOG.md#320---2026-10-29
[r310]: https://github.com/openwrt-iac/uapi/blob/main/CHANGELOG.md#310---2026-10-11
[r300]: https://github.com/openwrt-iac/uapi/blob/main/CHANGELOG.md#300---2026-08-13
[r250]: https://github.com/openwrt-iac/uapi/blob/main/CHANGELOG.md#250---2026-08-09
[r200]: https://github.com/openwrt-iac/uapi/blob/main/CHANGELOG.md#200---2026-06-04
[r120]: https://github.com/openwrt-iac/uapi/blob/main/CHANGELOG.md#120---2026-06-01

## Features (additive, future minor bumps in 4.x)

- **Upstream: one unresolvable peer endpoint should not take a tunnel down.**
  Filed as
  [openwrt/openwrt#24511](https://github.com/openwrt/openwrt/issues/24511), and
  fixed on OpenWrt main by ecd9120f04 (2026-11-18). `wg syncconf` is all or
  nothing and the proto handler escalates any failure to `proto_setup_failed`,
  so a peer whose endpoint hostname does not resolve stopped the interface
  coming up at all, healthy peers included. Measured: `up=false`, zero peers,
  no addresses, netifd retrying and giving up. The ucode handler of main now
  leaves out the endpoint, preshared key or keepalive line that wg would
  refuse, and the peer of a key that is not a WireGuard key, so the other peers
  come up. An allowed IP that wg refuses still takes the tunnel down, and so
  does an endpoint host of digits and dots that inet_aton does not read, such
  as `10.0.0.256`, which the handler gives wg as an address with no lookup. A
  write refuses such a host. A write to an interface that a peer from another
  writer keeps down keeps its commit and answers `X-Kernel-Status: blocked`,
  with the peer in `X-Kernel-Blocked`.

  25.12 keeps `wireguard.sh`, where the half that matters to us remains: the
  `wg set` apply protects the *write*, not the *boot*. A peer whose endpoint
  resolves when written and stops resolving later sits in uci, and the next
  reboot runs it through the proto handler and drops the tunnel. No amount of
  local code fixes that, because the platform owns the boot path.

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

- **Upstream: widen the interface `disabled` reader once 25.12 carries netifd
  `e97e36f`.**
  netifd accepts `disabled 'true'` on an interface since that commit,
  2026-07-16, so
  `network/interfaces` can then read the flag with `platform_bool` like routes
  and rules.
  As of 2026-10-28, OpenWrt `main` pins a netifd from 2026-10-28, which carries
  it, but
  `openwrt-25.12` still pins 2026-02-26, and so does 25.12.6. The unit test that
  pins the
  per-type difference is what will say when the widening is right.

- **Upstream: uhttpd serves its request queue last-in first-out.** When every
  `max_requests` handler slot is taken, uhttpd queues a new request and serves
  the
  newest queued one first, so a client that keeps the slots busy keeps the
  earliest
  queued request waiting the longest, and it needs no token to do so. uapi's 10
  s body
  deadline frees its own slots, but the order of the queue is uhttpd's and no
  ucode
  handler can change it. Found while measuring the body reads of
  [#296](https://github.com/openwrt-iac/uapi/pull/296) and
  [#299](https://github.com/openwrt-iac/uapi/pull/299) on uhttpd 2025.10.03. A
  fix
  belongs to uhttpd, and this is recorded so the question is not re-opened as
  uapi work.

- **Upstream: luci-base reads a request body with no deadline.** LuCI's ucode
  runtime
  reads a POST body with `uhttpd.recv` on the same blocking pipe as uapi and
  sets no
  deadline (`modules/luci-base/ucode/uhttpd.uc`, `luci.http`), so a body that
  stalls
  holds one of the shared `max_requests` slots until the script timeout of
  uhttpd, the
  login included. uapi bounds its own bodies
  ([#299](https://github.com/openwrt-iac/uapi/pull/299)). LuCI's requests share
  the same
  slots and keep their behavior. A fix belongs to luci-base, and this is
  recorded so the
  question is not re-opened as uapi work.

- **Standalone confirm arm, `POST /uapi/confirm`
  ([#324](https://github.com/openwrt-iac/uapi/issues/324)).** Additive, so a
  4.x minor can ship it. It waits for a consumer that asks for it.
  `docs/commit-confirm.md` holds the design, the authz model and the reasons
  for the wait.
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
- **More resources.** Curation completeness rule in `docs/adding-a-resource.md`:
  add when a
  typical real configuration sets options the curated layer doesn't
  surface.
## Install the deferred packages in CI

Partly done in 2.5.0. lldpd and vnstat2 are installed by `install_uapi`'s
bootstrap, about
560 KiB together, so `lldpd/config` and `vnstat/config` are exercised by
`tests/integration/49_daemon_gated_resources_test.sh` and included in the
stock-config
round-trip. The install sits in the bootstrap rather than inside a test, which
is what avoids
the QEMU SLIRP failure that cost hours of CI when it was tried inline.

Still outside the image, so still unexercised: snmpd, mwan3, sqm, usteer,
prometheus-node-exporter-lua and openvpn. unbound is installed by
`40_unbound_uci_ext_test.sh`
but only while that test runs, which is not a guarantee another test can lean
on.

The cost of leaving it is measurable rather than theoretical:
`vnstat/interfaces` modelled a
section type vnstat never reads and shipped that way, because a resource for an
uninstalled
package is never exercised against real configuration, so a wrong section type
is
indistinguishable from a right one.

Note for whoever picks up the rest: on the standing test box the distfeeds
needed pointing at
25.12.5 and the kmods feed at kernel `6.12.94-1-a7bc15f4...`, or every `kmod-*`
dependency
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
  release time. Deciding needs a few runs' worth of variance data across
  runners,
  which nobody has gathered. Until then the tree says measurement, not gate.

- **A request that uhttpd kills after its commit still leaves the write half
  done.** uhttpd
  sends `SIGKILL` to the request process, and to no other, when the client
  closes the
  connection before the response and when `script_timeout` runs out (60 s unless
  set). A
  Terraform interrupt or a client-side timeout does the first. No ucode code
  runs after a
  `SIGKILL`. `transaction()` commits, then reloads, runs the stay-up watch and
  the kernel
  apply, and after a failure restores the snapshot and reloads again, all in
  that process.
  A kill after the commit leaves uci with the new config, runs no check and no
  restore, and
  answers nothing. The reload that the request started runs on, and since the
  lock fds
  close on exec the kill also releases the lock, so the next write can commit
  and reload
  beside it. `multi_transaction()` and the crontab apply in `crontab.uc` have
  the same
  shape. The steps after the commit are not short: the reloads, which uapi waits
  for up to
  20 s in all, the stay-up watch, which waits up to 2 s and again on a restore,
  and the kernel
  apply.
  The write journal reports such a write in `GET /uapi/diagnostics` since
  3.5.0. It does not finish or restore the write: one request may not undo a
  write that is not its own, because the scopes of the request that started the
  write are the only authority over what its revert may touch. Nothing inside
  the request can close the rest, so it needs a design change. The shapes left,
  none chosen:
  - The steps after the commit in a process that uhttpd does not kill. That is
    work that
    outlives the request, which `docs/concurrency.md` rules out, and the client
    still gets
    no answer.
  - A change to uhttpd to send `SIGTERM` and wait before `SIGKILL`, so that a
    request can
    ignore it with ucode's `signal()` until its recipe ends. That is upstream
    work, and the
    wait would bound how long a recipe may take.
  The details are under Open findings in `docs/lock-state-audit.md`.

- **The restore after a failed reload leaves a package that another writer
  committed to during
  the reload, and the operator repairs it.** LuCI and a shell take no uapi lock,
  so they can commit
  to the package while its daemons reload, into the file that the request
  committed. The restore
  wrote back the snapshot from before both, so it undid that commit too. It now
  compares the file
  with what the request committed, under libuci's flock, leaves a file that
  differs as it is, and
  answers `reload_failed_unrecovered` with the package named in `restore_error`.
  The package then
  keeps the write that the daemon refused beside the other commit. A commit that
  libuci renames
  between the comparison and the rename of the restore is still undone, and so
  is one between the
  rename of the request's own commit and the read of the file that follows it.
  Two ways to recover
  such a package without the operator were not chosen:
  - Undo only the writes of the request: load the file as it is, set back what
    the request wrote
    and commit through libuci. That needs a rule for an option that both wrote,
    puts a section that
    a DELETE removed back at the end of the package with a new name when it was
    anonymous, drops
    the comments of the file, and gives up the check of its own write that the
    restore makes,
    because libuci does not check its write.
  - Hold libuci's flock from the commit to the end of the restore: libuci's own
    load and commit in
    the request would wait on that lock, LuCI would wait for the whole reload,
    and libuci releases
    its flock before its rename anyway.

- **Reporting-surface consumption is the provider's.** `X-Kernel-Status`,
  `management_path` and `?validate=1` are all emitted and documented here, and
  `terraform-provider-uapi` consumes none of them. That is the provider's call,
  not a gap
  in this repo, and it is recorded here only so the question is not re-opened as
  uapi
  work.

- **The idempotent retry of a POST that lost its answer is the provider's.**
  uhttpd can
  kill a request after its commit, which leaves the write applied and no answer
  sent, and
  the idempotency store replays a 2xx answer to the same key and body for 24 h,
  so the
  retry is client work
  ([terraform-provider-uapi#45](https://github.com/openwrt-iac/terraform-provider-uapi/issues/45)).
  Recorded here only so the question is not re-opened as uapi work.

- **`unbound/srv.ip_transparent` still reads with `normalize_bool`.**
  [#310](https://github.com/openwrt-iac/uapi/issues/310) moved the other
  boolean reads to the parser of their daemon. The reader of this option, in
  `unbound-uci-ext`, has not been checked yet, so the right helper is not known.
  See `docs/ucode-quirks.md`.

The open defects that the lock-state audit found are under Open findings in
`docs/lock-state-audit.md`.

## Objectives for the next major

The sweep list for v4, tracked in the [v4
milestone](https://github.com/openwrt-iac/uapi/milestone/1). At v4 planning,
read it top to bottom: every line must resolve to an issue in the milestone, or
be explicitly descoped in the release PR with the reason. An issue is closed
when its work merges into `main`, the 4.x line since the `v4` branch merged, and
that work ships with v4. The mechanisms, the evidence and the open questions
live in the issues.

**Left the milestone:**

- [Widen `network/interfaces.disabled` to the platform
  boolean](https://github.com/openwrt-iac/uapi/issues/311): OpenWrt 25.12,
  which 4.x supports, does not carry netifd `e97e36f`, and the widening is
  breaking, so it waits for the major after v4.
- [Ship the standalone confirm
  arm](https://github.com/openwrt-iac/uapi/issues/324): additive, so a 4.x
  minor can ship it, as `POST /uapi/confirm` with the scope `uapi:confirm:rw`.

**Merged, and closed:**

- [Routes `table` and rules `lookup` accept table names on
  write](https://github.com/openwrt-iac/uapi/issues/240): the request type
  becomes a union, breaking, and a read still answers the id.
- [`network/interfaces.ip6prefix` stops taking a string on
  write](https://github.com/openwrt-iac/uapi/issues/241): announced since 3.2.0,
  the only open deprecation window.
- [One rule for newlines in curated
  strings](https://github.com/openwrt-iac/uapi/issues/276): a default refusal in
  `check_schema_types`, with an opt-out for `system.notes`.
- [`mwan3/interfaces.family` is required, or an unset one reads
  `ipv4`](https://github.com/openwrt-iac/uapi/issues/306): either way breaking.
- [A `wireless/interfaces` section with no `mode` reads null instead of
  `ap`](https://github.com/openwrt-iac/uapi/issues/307): a read today reports an
  access point that does not exist.
- [Refuse a write for any stored error the section holds, as LuCI
  does](https://github.com/openwrt-iac/uapi/issues/308): the schema check and
  every rule judge the section that a write leaves, so what the sweep lists
  blocks the write.
- [Retire `normalize_bool`, boolean reads follow the platform's
  reader](https://github.com/openwrt-iac/uapi/issues/310): prerequisite is
  [reading libvalidate's accepted set out of
  ubox](https://github.com/openwrt-iac/uapi/issues/312), shipped in 3.4.0.
- [Group the special endpoints under
  `/uapi/...`](https://github.com/openwrt-iac/uapi/issues/319): the paths and
  the scopes disagree today, breaking.
- [Merge `dhcp/leases6` into
  `dhcp/leases`](https://github.com/openwrt-iac/uapi/issues/320): one endpoint
  less, breaking.
- [One documented runtime envelope on every
  resource](https://github.com/openwrt-iac/uapi/issues/322): every resource
  answers a `runtime` that its schema requires, breaking for generated clients.
- [Prune dead error codes from the
  enum](https://github.com/openwrt-iac/uapi/issues/323):
  `unsupported_media_type` is the documented-dead one, breaking for generated
  clients.
- [Consolidate the `x-uapi-*` marker
  namespace](https://github.com/openwrt-iac/uapi/issues/329): four vendor
  markers, one of which dies with #241, internal.
- [WireGuard peers on OpenWrt
  main](https://github.com/openwrt-iac/uapi/issues/359): the kernel apply waits
  for the restart of netifd's ucode handler, and a restart that does not end
  fails the write.
- [dnsmasq on OpenWrt main](https://github.com/openwrt-iac/uapi/issues/360): the
  test writes `dhcpv4 'server'`, as the stock config of main does.
- [A v4 lease without a client id reads duid
  `"*"`](https://github.com/openwrt-iac/uapi/issues/392): dnsmasq writes `*`
  for a missing client id, which reads null, as for the hostname.
- [mwan3 `loglevel` `err` and `warn`, and a member `metric` above
  256](https://github.com/openwrt-iac/uapi/issues/407): uapi took them and the
  daemon did not. A write now refuses them.
- [A firewall `synflood_rate` with a unit and a zone without a policy read
  another value than fw4 uses](https://github.com/openwrt-iac/uapi/issues/408):
  reads that change, with a new ETag at the upgrade.
- [The HTTP token mint takes a scope that the server does not
  know](https://github.com/openwrt-iac/uapi/issues/415): it answers 422, as
  `uapi-token create` refuses it, announced in 3.5.0.
- The mount moves to `/api/v4` and the install hook strips every older prefix,
  as each major moved it before. The v3-to-v4 migration document rides the
  release.

## Out of scope by design

- **Dropping `managed` and the adopt flow**
  ([#321](https://github.com/openwrt-iac/uapi/issues/321), withdrawn before v4).
  libuci names an anonymous section at each load from its ordinal in the package
  and a hash of its type, so the name moves to another section when an earlier
  one is deleted. A client that stored such a name and wrote or deleted through
  it reached another section with a 2xx. `adopt` is how a client gets a name
  that holds, and `managed` is how it knows that it needs one.
- **Localization of error `message` strings.** English-only; codes are
  stable and translatable client-side.
- **Async/parallel ubus.** `conn.call()` only, by design (see
  `docs/concurrency.md`).
- **In-memory caches across requests.** Forked children only; the design
  precludes them. State that must span requests lives in a file or in uci.
- **Multi-tenant scoping.** Single admin namespace. Adding multi-tenancy
  would require a richer auth model than scopes-on-tokens.
