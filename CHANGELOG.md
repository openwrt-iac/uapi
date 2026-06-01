# Changelog

All notable changes to this project will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- (Reserved for next-cycle changes.)

## [1.2.0] - 2026-06-01

Minor release driven by a real Terraform-provider migration that exercised the v1.1 surface against an actual edge router. Three themes:

1. Closing the last "must drop to /raw/" gaps in the curated surface (proto=dhcp/dhcpv6 client options, NAT-loopback reflection on redirects, DHCPv6-reservation fields on dhcp/hosts, parity audit on unbound/server).
2. Surfacing the runtime state Terraform readers need (ubus-derived runtime blocks on network/interfaces, dhcp/servers, wireless/interfaces; new read-only dhcp/leases6 collection).
3. Closing the substantive deferred feature from v1.0's roadmap: ETags / If-Match optimistic concurrency.

Plus two non-uci additions (`system/password`, `system/authorized_keys`) for credential bootstrap, and a formalised "Non-uci resources" registry in CLAUDE.md so the bar for future non-uci additions stays high.

Purely additive: every endpoint, field, scope, response shape, and error code from 1.0.x and 1.1.x continues to work unchanged.

### Added

- **`network/interfaces` proto-conditional DHCP/DHCPv6 client fields.** Under `proto=dhcp`: `peerdns`, `defaultroute`, `metric`, `hostname`, `clientid`. Under `proto=dhcpv6`: `peerdns`, `reqprefix`, `reqaddress`, `ip6hint`, `ip6ifaceid`, `delegate`. Closes the "WAN with PD and noresolv" use case that previously required either dnsmasq workarounds or /raw/.
- **`firewall/redirects` NAT loopback.** New fields: `reflection` (bool), `reflection_src` (enum `internal`/`external`), `reflection_zone` (list). Native fw4 options; no more split-horizon-DNS workaround.
- **`dhcp/hosts` parity audit.** New fields: `duid` (DHCPv6 client id), `hostid` (IPv6 host-id hint), `mac_aliases` (additional MACs via uci `list mac`, backward-compatible with single-string `mac`), `broadcast` (`--dhcp-broadcast` workaround for older clients), `instance` (cross-refs `dhcp/dnsmasq` section names). validate requires either `mac` OR `duid`.
- **`unbound/server` parity audit.** New fields: `manual_conf`, `extended_stats`, `interface_auto`, `localservice`, `hide_binddata`, `rebind_protection`, `num_threads`, `ttl_min`, `domain`, `domain_type`. Listen-address binding deliberately not added; documented in `docs/non-uci-state.md` (no clean uci option exists upstream; use `/etc/unbound/unbound_srv.conf`).
- **`dhcp/leases6` (NEW read-only collection).** Parses `/tmp/(hosts/odhcpd|odhcpd.leases)` to surface odhcpd IPv6 lease state. Per-IA-address entries with `duid`, `iaid`, `hostname`, `interface`, `ia_type`, `ip`, `prefix_length`, `expires_at`. Forgiving parser fails soft on odhcpd format drift across versions.
- **`network/interfaces` runtime block.** Populated from `ubus call network.interface.<name> status`: `up`, `pending`, `available`, `l3_device`, `uptime`, `ipv4-address[]`, `ipv6-address[]`, `ipv6-prefix[]`, `route[]`. Drift-safe for Terraform (field already declared computed).
- **`dhcp/servers` runtime block.** Surfaces `active_leases_v4_total` (box-wide; dnsmasq doesn't tag leases by interface) and `active_leases_v6_iface` (per-interface; odhcpd does).
- **`wireless/interfaces` runtime block.** Looks up the kernel ifname via `network.wireless status`, then queries `iwinfo info`/`assoclist` via ubus. Surfaces `ifname`, `bssid`, `channel`, `frequency`, `signal`, `noise`, `txpower_actual`, `assoclist_count`. Requires new dep `rpcd-mod-iwinfo`.
- **`system/password` (non-uci, write-only).** `POST {user, password}` → 204. Shells out to `/bin/busybox passwd <user>` with the password piped twice via stdin (LuCI's recipe). Validates user as `^(root|[a-z][a-z0-9_-]*)$` and password as `>= 8` characters with no control bytes. Under `transaction.with_lock`. Audit log line carries the user name, never the password.
- **`system/authorized_keys` (non-uci).** `GET` lists; `POST` adds one; `PUT` replaces wholesale; `DELETE /<id>` removes one. File ops on `/etc/dropbear/authorized_keys` (mode 0600, atomic tmp+rename, symlink-safe). Server-side key validation against the allowed type set (`ssh-rsa`, `ssh-ed25519`, three ECDSA curves, two SK variants). Rejects newline/NUL injection in any key field. Stable id = sha256 prefix of the public-key blob (with a 48-bit dual-djb2 fallback in test environments without ucode-mod-digest).
- **ETags / `If-Match` optimistic concurrency.** Every CRUD `GET`, singleton `GET`, and successful write response carries an `ETag` header (sha256 prefix of the canonical JSON body, excluding the runtime block so live ubus drift doesn't trip spurious 412s). `PUT`, `PATCH`, `DELETE`, and singleton `PATCH` honour `If-Match`: stale value returns `412 precondition_failed` and aborts before any uci write. Multi-value (`"a", "b"`), `W/` weak prefix, and `*` (any-existing) all supported. Absent `If-Match` preserves last-write-wins. **uhttpd carve-out:** uhttpd's CGI env has a hard-coded HTTP_* allowlist that excludes If-Match; pass the ETag via `?if_match=<etag>` query parameter as the portable path (uapi accepts either).
- **New error code:** `412 precondition_failed`.
- **Non-uci resources registry in CLAUDE.md.** Six rows: `packages/installed`, `packages/feeds`, `dhcp/leases`, `dhcp/leases6`, `system/password`, `system/authorized_keys`. Each with source-of-truth, lock semantics, reload, audit shape. Adding a new non-uci resource means adding a row.
- **`docs/non-uci-state.md`.** Operator-facing companion to the registry, plus the out-of-scope state catalog (unbound listen-address binding, inittab, etherwake, px5g, FreeBSD sysctl, RRD/NetFlow history) with recommended out-of-band path for each.
- **Curation completeness rule** (CLAUDE.md): "*does this resource expose the options a typical real configuration of this section actually sets?*" as the test for any future curation gap.
- **`examples/curl/`** grew from 5 files to 15: `network_interfaces.sh`, `firewall_redirects.sh`, `firewall_forwardings.sh`, `wireguard_peers.sh`, `dhcp_servers.sh`, `uhttpd_instances.sh`, `sqm_queues.sh`, `dropbear_instances.sh`, `packages_installed.sh`, plus the existing ones.

### Changed

- **`handler.uc` resource factory** now passes `conn` as the second arg to every `fromUci` callsite (list, get_one, replace, patch, remove, adopt, singleton get/patch). Resources that don't need it ignore the extra arg; resources that want runtime data from ubus use it. Default behaviour unchanged for v1.0 resources.
- **`schema_properties` filled in** on seven v1.1 resources that shipped with empty stubs (`dhcp/odhcpd`, `snmpd/{com2secs,system}`, `uhttpd/certs`, `vnstat/{config,interfaces}`, `prometheus_node_exporter_lua/config`). OpenAPI codegen for downstream tooling now sees field types/ranges.
- **`uhttpd/certs.country`** validator accepts `^[A-Za-z]{2}$` (case-insensitive) and normalizes to uppercase in `toUci`. v1.1 accepted any 2-char string; the early v1.2 work tightened it to `^[A-Z]{2}$`, which was a backward-compat break and is now relaxed.
- **`unbound/server` enums** match upstream OpenWrt unbound: `protocol` now `{default, mixed, ip4_only, ip6_only, ip6_local, ip6_prefer}` (`auto` was rejected by the daemon); `resource` picks up `default`.
- **`tests/integration/14_observability_test.sh`** asserts the TLS-bypass audit-log gap is closed: a WRITE via `/etc/uapi.insecure` emits both the `uapi-insecure-bypass` NOTICE and the standard AUDIT line.
- **`tests/integration/22_network_extras_test.sh`** installs an `EXIT/INT/TERM` trap so the throwaway `br-uapitest` bridge is always cleaned up.

### Documentation

- **CLAUDE.md** updated: concurrency section describes the shipped ETag feature plus the uhttpd carve-out; the `v1.1+ roadmap` entry for ETags marked shipped; the curated endpoint list at the top still points readers at the generated `build/openapi.json` for the current authoritative list.
- **`docs/operations.md`** `/metrics` deferred-feature wording rewritten to reflect that the fork-per-request model is the actual blocker.
- **`docs/non-uci-state.md`** (NEW), see Added.

### Dependencies

- New runtime dep: `rpcd-mod-iwinfo` (for `wireless/interfaces` runtime block).

### Tests

- Unit: 350 (v1.1.1) → 422 (+72).
- Integration: 27 (v1.1.1) → 30 (+24_uhttpd_self_lockout, 25_dropbear_instances, 26_packages, 27_runtime_and_leases6, 28_system_access, 29_etags — already partly in v1.1.x; net +3 new files in v1.2).

### Notes

- Generated `openapi.json` grew to ~267 kB describing the expanded surface; spec carries `info.version: "1.2.0"`.
- Clients pinned to `uapi>=1.0` or `>=1.1` continue to work. Clients depending on any of the new endpoints or fields should pin `uapi>=1.2`.

## [1.1.1] - 2026-05-31

Patch release driven by a structured review of v1.1.0. No on-the-wire breaking changes. Two real bugs fixed, plus a security hardening sweep across the new v1.1 surface and several validation gaps closed.

### Fixed

- **handler.uc dynamic-type PUT/PATCH response leaked the sentinel `.type` instead of the real uci type.** For `network/wireguard_peers` this meant a successful write responded with `interface: "peer"` (substring after `"wireguard_"`) rather than the real parent interface name; a Terraform-style client refreshing from the write response would see drift on the next plan. The persisted uci state was always correct; only the response body was wrong. Static-type resources were unaffected (sentinel == real type). Added a regression test that PUT/PATCHes a wireguard peer and asserts the response `interface` matches the request.
- **`uhttpd/instances` self-lockout protection was documented but unimplemented.** The v1.1.0 code declared a `UAPI_PREFIX` constant and a `uapi_prefix_present` helper, but `validate()` was a no-op; a PATCH or PUT that stripped uapi's own `ucode_prefix` entry from the `main` instance silently locked the operator out of the API until console intervention. `validate(json, conn, id)` now enforces the check when `id == "main"` and rejects the write with `422 conflict` on the `ucode_prefix` field. To support this, `handler.uc` now passes `id` as a third argument to `validate()` (existing resources ignore it).

### Security

- **`packages/installed` and `packages/feeds` regex tightening (apk flag injection guard).** `PKG_NAME_RE` was `^[A-Za-z0-9_+.-]+$` and `FEED_NAME_RE` was `^[A-Za-z0-9_.-]+$`, both of which accepted a leading `-` or `.`. A name like `--allow-untrusted` or `--repository=http://attacker/` was regex-valid and reached `apk add` as a flag rather than a positional argument. Names starting with `.` (`.bashrc`, `..foo`) similarly bypassed the intended scoping. Patterns are now `^[A-Za-z0-9_+][A-Za-z0-9_+.-]*$` and `^[A-Za-z0-9_][A-Za-z0-9_.-]*$`; all `apk` invocations also use `--` to separate flags from positional arguments. Unit + integration tests cover both rejection paths.
- **`packages/*` writes now acquire the global `/var/lock/uapi.lock`.** The v1.1.0 implementation bypassed the transaction recipe's flock step; two concurrent installs raced apk's own DB lock and produced nondeterministic `5xx` instead of a clean `423 locked` with `Retry-After`. Refactored via the new `transaction.with_lock` helper, which acquires the same flock without the uci snapshot/reload machinery (apk doesn't go through uci).
- **`packages/*` error envelope no longer dumps raw apk stderr.** `apk add` / `apk del` failures previously surfaced the full stderr in `message`, which can contain absolute paths, mirror URLs, and on misconfigured feeds embedded credentials. The full output is now logged to syslog under the request_id; the response carries a generic `apk add failed (exit N); see syslog <request_id> for details` and the exit code.
- **`packages/*` info_one version-parse regex was broken.** `[:space:]` POSIX char-class syntax does not work in ucode/PCRE; `version` was silently always null. Now parses real `apk info` output.
- **`network/wireguard_peers` secret-masking now matches `wireless/interfaces`.** Previously the `preshared_key` field was returned as the literal string `"(set)"` on read; the field is now omitted on read and only `has_preshared_key: bool` surfaces. The PATCH path still carries the existing key forward via `merge_for_patch`.

### Changed

- **Resource validation gaps closed across v1.1 endpoints.** `snmpd/com2secs` now requires `source` (was silently accepting nonsense sections). `snmpd/accesses` cross-refs `group` against `snmpd/groups`. `vnstat/interfaces` cross-refs `interface` against `network/interfaces`. `network/rules` requires `goto` when `action=goto` (mirroring the existing `lookup` check). `system/timeservers` requires a non-empty server list when `use_dhcp=false`. `uhttpd/instances` validates `listen_http`/`listen_https` format and integer-field bounds. `firewall/defaults` validates `synflood_burst` / `synflood_rate` as positive ints. `uhttpd/certs` requires `commonname` and bounds `days` to 1-36500. `network/routes` validates `source` as IPv4/CIDR. `dhcp/dnsmasq` caps `cachesize` at 1000000 and requires `port` in 1-65535. `dhcp/servers` bounds `start`/`limit` to 0-254 (dnsmasq pool offset/size within a /24). `dropbear/instances` normalizes `PasswordAuth` / `RootPasswordAuth` / `GatewayPorts` to `"1"`/`"0"` (instead of mixed `"on"`/`"off"` and `"1"`/`"0"`).
- **`dhcp/servers` reload list narrowed to `["dnsmasq"]`.** ucitrack already cascades the `dhcp` package to `odhcpd`; the explicit listing produced a double reload.
- **CI: tag glob simplified to `v*` and concurrency cancels in-progress for non-tag refs.** The previous `v[0-9]+.[0-9]+.[0-9]+*` was GitHub filter-pattern syntax (where `+` is literal, not a regex quantifier) and worked by accident; the real release gate is the job-level `if: startsWith(github.ref, 'refs/tags/v')`. Branch and PR pushes now cancel superseded runs (saves runner minutes) but tag runs are never cancelled mid-publish.
- **`tests/integration/22_network_extras_test.sh`** installs an `EXIT/INT/TERM` trap so the throwaway `br-uapitest` bridge is always cleaned up on mid-test failure.

### Added

- **New integration tests for previously uncovered v1.1 endpoints:** `tests/integration/24_uhttpd_self_lockout_test.sh`, `25_dropbear_instances_test.sh`, `26_packages_test.sh`. The packages test specifically exercises the security hardening above against real `apk`.
- **`transaction.with_lock`** helper for non-uci write paths that need the same global serialization the uci recipe gets.

### Documentation

- **CLAUDE.md refreshed.** The curated endpoint list and the scope tree were stale (both still described v1.0); now point at the authoritative sources (`build/openapi.json`, `src/lib/scope.uc`) and enumerate the v1.1 additions.

## [1.1.0] - 2026-05-30

Comprehensive curation pass. Every additional uci section type a typical edge-router configuration relies on now has a curated CRUD or singleton endpoint, and uapi can manage its own runtime package set (apk install/remove and apk feeds). An orchestrator built on this release can drive `/api/v1/...` exclusively without falling through to `/raw/`. Purely additive: every endpoint, field, scope, and response shape from 1.0.x continues to work unchanged.

### Added

- **`network` extensions.**
  - `network/routes` (`network.route`) static routes; target/gateway/interface/table/metric/mtu/type. Validates target as CIDR/IP and cross-refs interface (skipped for blackhole/unreachable).
  - `network/rules` (`network.rule`) policy routing rules; in/out/src/dest/priority/lookup/goto/action/invert/mark.
  - `network/bridge_vlans` (`network.bridge-vlan`) bridge VLAN tagging; device/vlan/ports, vlan 1-4094, port spec regex, bridge cross-ref.
  - `network/wireguard_peers` dynamic-type resource over `wireguard_<parent_iface>`. Cross-refs the parent interface and requires it to be `proto=wireguard`. Preshared key is masked on read and carried through PATCH via `merge_for_patch`.
  - `network/interfaces` now accepts `proto=wireguard` with fields `private_key`, `listen_port`, `addresses` (CIDR list), `mtu`, `nohostroute`, `ip4table`, `ip6table`. `private_key` is masked on read (surfaced as `has_private_key: true`) and preserved across PATCH.
- **`firewall` extensions.**
  - `firewall/forwardings` (`firewall.forwarding`) zone-to-zone forwarding; cross-refs both zones.
  - `firewall/defaults` singleton input/output/forward verdict, syn_flood, drop_invalid, synflood_burst/rate, tcp_syncookies, flow_offloading.
- **`dhcp` extensions.**
  - `dhcp/servers` (`dhcp.dhcp`) per-interface DHCP server config; reloads dnsmasq + odhcpd.
  - `dhcp/dnsmasq` singleton global dnsmasq config; forwarders, address overrides, rebind protection, cache size, etc.
  - `dhcp/odhcpd` singleton odhcpd config; maindhcp, leasefile, loglevel.
- **`system` extensions.** `system/timeservers` (`system.timeserver`) enabled/enable_server/server list/use_dhcp; reloads sysntpd.
- **`dropbear/instances` (`dropbear.dropbear`).** Port, PasswordAuth, RootPasswordAuth, RootLogin, BannerFile, Interface, GatewayPorts.
- **`uhttpd` resources.**
  - `uhttpd/instances` (`uhttpd.uhttpd`) per-instance config; listen_http/listen_https/home/cert/key/ucode_prefix etc.
  - `uhttpd/certs` (`uhttpd.cert`) px5g cert generation params; days/bits/commonname/organization/location/state/country.
- **`unbound/server` singleton (`unbound.unbound`).** Recursive DNS server tuning; enabled/listen_port/dhcp_link/dnssec_enabled/recursion/resource/protocol/query_minimize/prefetch.
- **`sqm/queues` (`sqm.queue`).** Per-interface SQM shaping; interface/download/upload/qdisc/script/linklayer/overhead with enum validation.
- **`snmpd` resources.**
  - `snmpd/agents`, `snmpd/com2secs`, `snmpd/groups`, `snmpd/accesses`, and the `snmpd/system` singleton; together they cover the standard SNMPv1/v2c/v3 ACL stack.
- **`lldpd/config` singleton (`lldpd.lldpd`).** Protocol toggles (CDP/FDP/SONMP/EDP/LLDP-MED), lldp_class, mgmt IP, interface list.
- **`prometheus_node_exporter_lua/config` singleton.** listen_ipv6/listen_interface/listen_port plus per-collector booleans for cpu, meminfo, netdev, loadavg, filesystem, diskstats, uname, netstat, stat, vmstat, boottime, entropy, time, hwmon, textfile, thermal_zone, edac.
- **`vnstat` resources.** `vnstat/config` singleton (DatabaseDir/Interface5MinHours/MonthRotate) and `vnstat/interfaces` (per-iface enable).
- **`packages/installed` (apk packages).** CRUD-shaped resource over the on-router apk store. GET lists installed packages, POST installs (`apk add`), DELETE removes (`apk del`). Package names validated against `^[A-Za-z0-9_+.-]+$`. No uci involvement; shells out via `fs.popen` like `default_reload`.
- **`packages/feeds` (apk repositories).** Manages files under `/etc/apk/repositories.d/`. POST writes a new `.list` file with the supplied URL and runs `apk update`; DELETE removes the file and re-runs `apk update`. URL validated as `http(s)://`; feed name validated as `^[A-Za-z0-9_.-]+$`.
- **Scope tree.** New scopes: `network:routes`, `network:rules`, `network:bridge_vlans`, `network:wireguard_peers`, `firewall:forwardings`, `firewall:defaults`, `dhcp:servers`, `dhcp:dnsmasq`, `dhcp:odhcpd`, `system:timeservers`, `dropbear`, `dropbear:instances`, `uhttpd`, `uhttpd:instances`, `uhttpd:certs`, `unbound`, `unbound:server`, `sqm`, `sqm:queues`, `snmpd`, `snmpd:agents`, `snmpd:com2secs`, `snmpd:groups`, `snmpd:accesses`, `snmpd:system`, `lldpd`, `lldpd:config`, `prometheus_node_exporter_lua`, `prometheus_node_exporter_lua:config`, `vnstat`, `vnstat:config`, `vnstat:interfaces`, `packages`, `packages:installed`, `packages:feeds`. Wildcard `*:rw` continues to cover all of them.
- **Raw access composition.** `/raw/<package>/<id>` now consults the curated domain tree for every new section type above (including a `wireguard_*` prefix match for WG peers), so tokens carrying a curated scope but not `raw:rw` still see writes blocked or allowed consistently with the curated equivalent.

### Changed

- **`handler.uc` resource factory now supports dynamic uci types.** New optional hooks on the resource module: `type_predicate(t)`, `create_type(body)`, `id_prefix`. Default behavior is unchanged (a static `type` string still works exactly as in 1.0.x). The wireguard peers resource is the first user.

### Notes

- Generated `openapi.json` grew to ~250 kB describing the expanded surface; the spec carries `info.version: "1.1.0"`.
- Clients pinned to `uapi>=1.0` continue to work. Clients depending on any of the new endpoints should pin `uapi>=1.1`.

## [1.0.1] - 2026-05-30

Packaging fixes for the upgrade path. No API surface change; existing clients see no difference.

### Fixed

- **`apk upgrade uapi` now picks up the new code immediately.** uhttpd-mod-ucode compiles `main.uc` at parent startup and caches the VM; a plain reload does not re-read the script. 1.0.0's postinst only ran the uci-defaults wiring (which self-deletes after first install) and never told uhttpd to restart on upgrade, so operators upgrading from 1.0.0 would keep serving the previous compiled code until they manually `/etc/init.d/uhttpd restart`. 1.0.1's postinst restarts uhttpd unconditionally after the uci-defaults dance.
- **Bootstrap message no longer shown on upgrades.** The "Create a token / Verify reachable / OpenAPI spec at" banner only prints on first install (no tokens defined yet). Upgrades and remove/reinstall (where the conffile-preserved token store survives) suppress it.

## [1.0.0] - 2026-05-29

First stable release. Identical surface and behavior to 1.0.0-rc2; the version bump promotes the release candidate after CI and end-to-end testing confirmed the post-rc1 architectural changes (real-exit-code reload via `fs.popen`, TOCTOU fix, mid-tree scope wildcards, observability knobs, full integration coverage for every curated resource) hold up under real ubus/uci/netifd.

See the [1.0.0-rc1] and [1.0.0-rc2] entries below for the cumulative content shipping in v1.

## [1.0.0-rc2] - 2026-05-29

Major release-candidate iteration driven by an exhaustive code review of rc1 and a follow-on round of architectural hardening. The on-the-wire API contract is unchanged from rc1; the response semantics are now actually honest about what they claim.

### Fixed

- **Reload mechanism (the big one).** rc1 issued daemon reloads via `ubus call <service> reload`, which is fire-and-forget for every non-daemon service on OpenWrt (`firewall`, `dhcp`/`dnsmasq`): rpcd accepts the call, defers the init script, and unconditionally completes the request with `UBUS_STATUS_OK` regardless of the actual exit code. Net effect on rc1: uci writes hit disk, the API returned 200, the audit log said "success", and `fw4` never actually picked up the change until the next reboot. rc2 reloads via `fs.popen("/etc/init.d/<svc> reload")` and inspects the exit code directly. Reload failures now correctly trigger `500 reload_failed_restored` / `reload_failed_unrecovered` and the snapshot-restore recipe runs end-to-end.
- **TOCTOU window in handler.uc closed.** Every CRUD method (replace/patch/remove/adopt + raw equivalents) now loads the target section *inside* the flock callback. rc1 loaded outside, checked, then locked: a competing writer could mutate state between check and lock.
- **Raw create with explicit `id` now refuses to silently overwrite an existing section.** rc1's `POST /raw/<pkg>` with `body.id = <existing>` would clobber the section's type and merge options; rc2 returns `409 conflict` (pre-flight) plus a defense-in-depth recheck under the lock. The supplied id must also match `^[A-Za-z0-9_]+$` or the request gets `422 invalid_format`.
- **Top-level exception handler.** Uncaught throws inside `dispatch()` (commit failure, malformed scope, unexpected ubus error) now return a `500 internal_error` envelope with `X-Request-Id` and emit an `ERROR` audit line plus a `uapi-internal <request_id>` syslog trace. rc1 let them escape as a broken-CGI response with no envelope.
- **Healthz 503 envelope.** Now `{status:"degraded",errors:[...]}` (matching CLAUDE.md). rc1 incorrectly returned the standard error envelope.
- **System resource envelope.** `id` and `managed` are now stamped at the top level (every other curated resource already had them). `reload: ["system", "log"]` declared so `system` PATCH actually reloads the affected daemons. `log_remote` and `urandom_seed` normalized to JSON booleans on read.
- **Wifi PATCH key preservation.** rc1's PATCH on an encrypted `wireless.interfaces` section forced the caller to resend the cleartext passphrase. rc2 carries the key through via a `merge_for_patch` hook so `PATCH {"ssid":"new"}` works without exposing or losing the key.
- **bus wrapper handles ucode-mod-ubus null-return semantics.** ucode's `conn.call()` returns null on error and stashes the message in a separate `ubus.error()` accessor (not a thrown exception). rc1's `try/catch` therefore never fired. rc2's `bus.call` wrapper checks `r == null && ubus.error() != null` and surfaces real errors via `die()`.
- **Lock open-failure surfaces 500.** rc1 collapsed `fs.open("/var/lock/uapi.lock") == null` (infrastructure problem) into `423 locked` (transient contention). rc2 distinguishes them: contention is `423` with `Retry-After`, infrastructure failure is `500 internal_error` with the path.
- **Audit gating.** `ERROR`/`WARN` syslog now scoped to 401/403/5xx (matching CLAUDE.md). `/healthz` excluded from all log categories. Non-auth 4xx (404/405/409/422/423) no longer emit log lines.
- **ucitrack `/etc/init.d/<package>` fallback.** Now implemented (rc1 promised it; the code path was missing). Lets `/raw/` writes against packages without a ucitrack entry still trigger the right service.
- **OpenAPI schema accuracy.** `dhcp.leases` schema now lists `{expires_at,mac,ip,hostname,duid}` instead of a `{id,managed}` stub. `wireless.interfaces` surfaces `key` (writeOnly) and `has_key` (readOnly).
- **CIDR validation.** `999.0.0.0/24` is now rejected; rc1 only checked digit shape.
- **firewall.redirects** ports/IPs are now arrays (matching firewall.rules).
- **PATCH `match` deep-merge generalized.** rc1 hardcoded the `match` key in `handler.make().patch()`; rc2 uses a per-resource `merge_for_patch` hook, eliminating a latent footgun for the next nested-object resource.

### Added

- **Mid-tree scope wildcards.** `firewall:*:ro` permits ro on every firewall subresource but not the bare domain. `*:rules:ro` matches the `rules` subresource of every domain. Exact segments beat wildcards at the same depth.
- **Observability knobs.** `/etc/config/uapi`'s `config logging` section enables `option access '1'` (every request emits an `ACCESS` INFO line) and `option debug '1'` (per-ubus-call trace at `LOG_DEBUG`). Both default off.
- **`/etc/uapi.insecure` marker now leaves an audit trail.** Every request that bypasses TLS via the marker emits a `uapi-insecure-bypass <request_id> <method> <path> status=<n> remote=<addr>` syslog NOTICE.
- **Mutual TLS docs.** `docs/installation.md` covers the `tls_client_cert_file` / `tls_require_client_cert` route for service-account-as-cert auth.
- **`lib/values.uc` shared helpers.** `normalize_bool`, `as_list`, `is_valid_ipv4`, `is_valid_ipv6`, `is_valid_ip`, `is_valid_cidr` — dedupes 9 modules of inline copies (one of which had drifted).
- **Sample syslog output.** `docs/operations.md` includes example lines for every audit category plus the insecure-bypass and internal-error formats.
- **README "Why this approach" section** framing how uapi differs from prior REST-for-OpenWrt attempts.

### Security

- **Service-name regex guard in `default_reload`.** `^[A-Za-z0-9_-]+$` enforced before interpolating into the `/etc/init.d/<svc>` command string. Defense-in-depth against a future ucitrack entry that could otherwise carry shell metacharacters.
- **`validate()` runs inside the flock.** rc1 ran cross-reference checks (e.g. `firewall.rules.match.src_zone` exists) before acquiring the lock; rc2 runs them inside the transaction so a concurrent zone delete cannot race a rule creation.

### Tests

- **17 new integration tests** covering: TLS-required from non-loopback, lock contention (`423 locked` with `Retry-After`), reload-failure rollback (fail-once injection via `/tmp/fw-fail-once`), audit-line emission, observability knobs, top-level exception handler, raw-409 conflict, token-lifecycle + revocation propagation, CRUD for every previously-uncovered curated resource (network.devices, wireless.devices, wireless.interfaces), adoption flow for every CRUD-capable resource.
- **mac80211_hwsim** auto-loaded in the QEMU VM so wireless tests run for real instead of skipping.
- **Conffile preservation** verified across a same-version reinstall in `release_apk_smoke.sh`.
- **Audit-log assertion** in `03_firewall_rules_crud_test.sh` (captures `X-Request-Id`, greps `logread`).
- Unit suite grew from 253 to 270 cases.

### Removed

- 11 dead exports across `lib/` (`errors.STATUS_BY_CODE`/`FIELD_CODES`, `ids.ALPHABET`/`ULID_LEN`, `scope.KNOWN_PATHS`, `transaction.LOCK_PATH`, `ucitrack.FALLBACK`, `values.IPV4_RE`/`IPV6_RE`/`CIDR_RE`/`is_valid_ipv6`).
- Dead helpers `auth.stub_enabled` / `auth.stub_token` (no longer needed after the real auth implementation landed in v1.0.0-rc1).
- Dead `bus.uci_add` (every write path uses `uci_create_section`).

### Docs

- `CLAUDE.md` rewritten "Atomic transaction recipe" to describe the `fs.popen` reload path and the rationale (every ubus-mediated reload is fire-and-forget).
- "Deferred / future work" reorganized into a "v1.1+ roadmap" with explicit reasoning for each item still missing in v1; the items rc2 implemented (TOCTOU fix, mid-tree wildcards, ucitrack init.d fallback, reload-rollback integration test, ACCESS/DEBUG knobs) are gone from the list.
- Process items dropped from the roadmap (feed submission, raw→curated promotion, i18n).

## [1.0.0-rc1] - 2026-05-28

First release candidate. Native HTTP REST API for OpenWrt 25.12+ packaged as a single `.apk`. The on-the-wire API contract (`/api/v1/...`) is what 1.0.0 will ship; the package version stays `rc` until real-world deployments shake out the install path on a variety of router configurations.

### Surface

- Bearer-token auth with hierarchical scopes (`*:rw`/`*:ro`, `<domain>:rw/ro`, `<domain>:<sub>:rw/ro`), deepest-match-wins, raw access requires both raw-tree and domain-tree permission.
- 10 curated resources: `firewall/{rules,zones,redirects}`, `network/{interfaces,devices}`, `wireless/{devices,interfaces}`, `dhcp/{hosts,leases}`, `system`.
- Generic `/raw/<package>/<id>` passthrough for any uci section type uapi does not curate.
- `/healthz` (no auth) probes ubus reachability.
- `/openapi.json` serves the OpenAPI 3.1 spec (no auth).
- Token CLI: `uapi-token create/list/show/revoke`. Cleartext tokens printed exactly once at creation, stored salted-sha256.

### Guarantees

- Atomic writes: per-request global flock (`/var/lock/uapi.lock`), uci snapshot, validate, stage, commit, daemon reload, restore on reload failure.
- Concurrent reads are lock-free and always permitted at the scope level.
- Audit log line per successful write (syslog `daemon.notice`, plain text, parseable by `logread`).
- Stable resource IDs (ULID with one-char type prefix) survive `/etc/config` rewrites; anonymous sections from other tools are surfaced read-only with `managed: false` until explicit `POST .../adopt`.
- v1 API is additive-only: see CLAUDE.md "API versioning policy" for what triggers v2.

### Distribution

- Single `.apk` package built against the OpenWrt 25.12.4 SDK.
- Conffile-marked token store at `/etc/config/uapi` preserved across upgrades and removal.
- uci-defaults install hook wires `uhttpd.main.ucode_prefix` and self-deletes; pre-remove hook unwires it.
- Release-tier CI builds the APK and runs a full install/use/remove smoke test in a fresh QEMU VM.

[Unreleased]: https://github.com/raspbeguy/uapi/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/raspbeguy/uapi/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/raspbeguy/uapi/compare/v1.0.0-rc2...v1.0.0
[1.0.0-rc2]: https://github.com/raspbeguy/uapi/compare/v1.0.0-rc1...v1.0.0-rc2
[1.0.0-rc1]: https://github.com/raspbeguy/uapi/releases/tag/v1.0.0-rc1
