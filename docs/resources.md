# Curated resources

This document indexes the 44 curated resources shipped in v3.x. For the full
schema (every field, its type, enum values, ranges, patterns), read
`build/openapi.json` (also served at `/api/v3/openapi.json` on a live
router) or open it in Swagger UI. Per-resource sample curls live in
`examples/curl/`.

`GET /schema/<package>/<resource>` serves a module's declared properties as one set, without the
request and response split the OpenAPI document makes. It is the module's own view: a property
marked `readOnly` there is absent from that resource's `*Request` schema, a property marked
`x-uapi-read-nullable` has `null` added to its type (and to its `enum`) in both halves, as the
next paragraph explains, a property marked `x-uapi-write-string` keeps `string` in its type only
in the `*Request` schema, the keywords under a property's `x-uapi-write` (such as `minimum: 68`
on `mtu`) apply only in the `*Request` schema, and `id`, `managed` and `runtime` are stamped by
the framework rather than declared by the module. For the two halves, read `build/openapi.json`.

`x-uapi-read-nullable` marks a property a read can answer null for, and widens its type (and
`enum`) with null in **both** halves. Both, because every IaC apply is a read-modify-write: the
response view goes back out as the next request body, so a request schema that refused those
nulls would describe the round trip as invalid while the server accepts it. Widening does not
weaken a required field, since the type is not what guards one; `resource.validate()` is, and it
answers 422 naming the field for a null `target` on a create.
`tests/lint_response_nullability.uc` calls each resource's real `fromUci` on a bare section and
fails if anything it returns null for is not null-permitted in the response schema.

The authoritative inventory is the OpenAPI spec; if this document drifts,
the spec wins.

## The daemon must be installed first

Curated resources that drive a daemon shipped as a separate OpenWrt
package (`unbound/server`, `sqm/queues`, `snmpd/*`, `openvpn/instances`,
`mwan3/*`, `vnstat/config`, `usteer/config`, `lldpd/config`,
`prometheus_node_exporter_lua/config`,
`uhttpd/instances` beyond `main`) need the underlying package installed
before writes succeed. Writing to a resource whose daemon is absent
returns `503 init_script_missing` with the missing
`/etc/init.d/<service>` path in the response body, before any uci
write. The pre-flight check is part of the atomic transaction recipe;
no partial state is left behind.

The uci config file has to exist too. `wireless/devices` and
`wireless/interfaces` need `/etc/config/wireless`, which `wifi config`
writes only when it finds a radio, and LuCI never creates a radio
section. On a router without one, a write answers `503 config_missing`
with the missing path, before any uci write. That includes a PUT, PATCH
or DELETE of an id that a GET answers 404 for, as with
`init_script_missing`. A read answers an empty list. The same applies
to any package whose file was removed. An empty file is enough.

Install the daemon either out of band (`apk add unbound`, etc.) or
through uapi itself via `POST /api/v3/packages/installed`. The latter
is what a Terraform configuration would chain via `depends_on` on a
`uapi_package` resource. The base uapi package's `Depends:` only
covers what uapi *itself* needs to run (uhttpd, ucode mods); per-daemon
packages are deliberately not pulled in.

## Network

| Path | Wraps | Notes |
|---|---|---|
| `network/interfaces` | `config interface` | Protos static, dhcp, dhcpv6, pppoe, ppp, wwan, wireguard and none. Optional `id` picks the section name at create time (uci section-name charset, 32 chars, tightened to 15 for `proto=wireguard` because netifd uses it as the kernel netdev name); absent, the server emits a 14-char `wg_<rand>` for wireguard or a 28-char ULID otherwise. `runtime` block carries live ubus state (uptime, ipv4/ipv6 addresses, route table). Some fields apply only to some protos, as the `allOf` entries on `proto` in the spec say: a read omits the others, a write that names one with a value other than null, `""` or `[]` answers `422 conflict`, and a proto switch removes the old proto's options. The options that netifd reads for every proto (`metric`, `defaultroute`, `delegate`, `ip4table`, `ip6table`, `dns`, `mtu`, the `ip6assign` group) apply to all of them. netifd applies `mtu` to the interface's device only when that device has no `config device` section of its own, as `br-lan` has in the stock configuration, and to every device that joins the interface later, such as a Wi-Fi netdev. A device with its own section takes its MTU from `network/devices`. On ppp and pppoe, `mtu` goes to pppd, which takes 128 to 16384. `listen_port` reads a service name as the port that wg resolves, and -1 when the name does not resolve. A write that switches an enabled interface to wireguard, or enables a wireguard interface, answers `422 conflict` while one of its stored `network/wireguard_peers` holds a value for which a peer write refuses to enable the peer, such as one that makes wg refuse the whole interface. On a proto that uapi does not model, such as `6in4`, a read shows the modelled options that uci stores, a POST or PUT answers `422 not_in_enum`, and a PATCH that leaves `proto` out refuses only `broadcast_flag` and keeps the options of the proto's handler. |
| `network/devices` | `config device` | Bridges, VLANs (8021q/8021ad), macvlan, veth, tun/tap. `mtu` below 68 is refused on write, because netifd ignores it; a stored one reads as it is. |
| `network/routes` | `config route` | Static routes; cross-refs interface. `table` reads a stored name as its id (253 `default`, 254 `main`, 255 `local`, or the id in `/etc/iproute2/rt_tables`), and 0 when netifd cannot resolve it and drops the route. A write takes an id from 1 to 4294967295. |
| `network/rules` | `config rule` | Policy routing. `lookup` reads and writes like the `table` of `network/routes`. netifd parses no `lookup` or `goto` action: a rule without `action` is a goto rule when `goto` is set and a lookup rule otherwise, so a read derives `action` that way and a write stores no action for those two. A `goto` must jump forward, past `priority`, and goes only with action goto. |
| `network/bridge_vlans` | `config bridge-vlan` | Bridge VLAN tagging (vlan 1-4094 + port spec). |
| `network/wireguard_peers` | `config wireguard_<iface>` (dynamic) | Peers on a wireguard interface; preshared_key masked on read. `endpoint_port` reads a service name such as `https` as its port from `/etc/services`, as wg resolves it, and 0 when the name does not resolve. `persistent_keepalive` reads `off` as 0, and -1 when wg cannot read the stored value. |

**`option disabled` is modelled on `network/interfaces`, `network/routes` and
`network/rules`.** netifd drops a disabled section outright on all three: a disabled
interface is never registered, so it has no ubus object and its addresses and routes
are absent, and a disabled route or rule is never installed. Each resource reads the
option with the helper matching its own parser, because netifd does not parse it the
same way for all three: `strict_bool` on the interface, where netifd compares the
value literally against `1`, and `platform_bool` on routes and rules, where it goes
through the boolean blob converter that also accepts `true`. `network/wireguard_peers`
models `disabled` as well.

[#64](https://github.com/openwrt-iac/uapi/issues/64) tracked the gap while it was
open; `docs/roadmap.md` carries the reasoning and the alternatives that were turned
down.

Reload: `network` (netifd).

**Editing the interface that backs your management connection is dangerous.**
`/etc/init.d/network reload` returns exit 0 even when an interface fails to
come up at runtime; uapi only sees the init script's exit code, not the
daemon's runtime convergence.

## Firewall

| Path | Wraps | Notes |
|---|---|---|
| `firewall/zones` | `config zone` | input/output/forward policies, `network` list. |
| `firewall/rules` | `config rule` | Nested `match: {src_zone, dest_zone, src_ip, dest_ip, src_port, dest_port, proto, family, mark, dscp}`. MARK and DSCP targets carry `set_mark` / `set_xmark` and `set_dscp`. `src_zone` is required only for NOTRACK, matching fw4. |
| `firewall/redirects` | `config redirect` | DNAT + NAT loopback reflection. DNAT and SNAT. Every `match` field except `proto` is a scalar, because firewall4 refuses a list on them and drops the section. `match.src_dip` is the external address matched on a DNAT (and the address NAT reflection uses) and the rewrite source on an SNAT, where it is required along with a named `match.dest_zone`. Prefer `firewall/nat` for new source NAT; LuCI migrates these sections there. |
| `firewall/nat` | `config nat` | Source NAT: SNAT (`snat_ip` / `snat_port`), MASQUERADE, or ACCEPT to exempt traffic from rewriting. `match.src_zone` is the outbound zone. An unset `match.family` means IPv4 only, which is fw4's default for NAT. |
| `firewall/forwardings` | `config forwarding` | Zone-to-zone forwarding. |
| `firewall/defaults` (singleton) | `config defaults` | Global verdicts, syn_flood, synflood_burst/rate, tcp_syncookies, flow_offloading. |

Reload: `firewall` (fw4).

## Wireless

| Path | Wraps | Notes |
|---|---|---|
| `wireless/devices` | `config wifi-device` | Radios (mac80211/broadcom), the `path`, `macaddr`, `phy` and `radio` that bind them to their hardware, band, channel, htmode, country, txpower, cell_density, legacy_rates. |
| `wireless/interfaces` | `config wifi-iface` | SSIDs, with every 802.11r option of LuCI's WLAN roaming tab. `key`, `r0kh` and `r1kh` are write-only, and a PUT that leaves them out keeps them. Responses include `has_key`, `has_r0kh` and `has_r1kh`. wifi-scripts writes `key`, `nasid`, `mobility_domain`, `r1_key_holder`, `r0kh` and `r1kh` into the daemon's config as lines, so a write refuses a newline in them, more than 1024 bytes in each of them but `key`, and a key holder entry that hostapd reads and cannot parse. A write is refused for such a value only when it adds the error, for example when it changes the field, sets the SSID up, which wifi-scripts does only while the SSID and its radio are enabled, or turns 802.11r on. A write also refuses the values that the daemons refuse or misread: an `ssid` over 32 bytes, a `key` in a form that hostapd or wpa_supplicant refuses for the mode and encryption, a `nasid` over 253 bytes on an EAP access point, `ieee80211r` with owe on an access point, a `reassociation_deadline` outside 1000 to 65535, a `mobility_domain` other than 4 hex digits, an `r1_key_holder` other than 12, and mode `wds`. The same rule applies to these: a write that leaves a stored value as it is is refused for it only when it makes the daemon read it. A write to `wireless/devices` that turns a radio on is refused while an enabled SSID of the radio holds any of these values. The validation sweep lists every SSID that holds such a value. These rules follow the ucode variant of wifi-scripts, which OpenWrt 25.12 uses, and not the shell variant of OpenWrt 24.10. `validate()` and the schema check run as before: every write still requires `key` for the EAP modes, which LuCI writes without one. A create or a PUT that sends no `mode` stores `ap`, which a read reports for a section with no mode. `runtime` carries iwinfo state. |

Reload: `network`. Requires `rpcd-mod-iwinfo` at runtime for the
`runtime` block on `wireless/interfaces`.

## DHCP

| Path | Wraps | Notes |
|---|---|---|
| `dhcp/hosts` | `config host` | Static leases. `macs` (the whole uci `list mac`), `ip`, `name`, `leasetime`, `duid`, `tag` (tags the host sets), `match_tag` (tags a request must carry). |
| `dhcp/servers` | `config dhcp` | Per-interface server config. `runtime` carries active-lease counts. |
| `dhcp/dnsmasq` (singleton) | `config dnsmasq` | Global dnsmasq tuning; forwarders, address overrides, rebind protection. |
| `dhcp/odhcpd` (singleton) | `config odhcpd` | `maindhcp`, `leasefile`, `loglevel`. |
| `dhcp/leases` (read-only collection) | `/tmp/dhcp.leases` | IPv4 leases parsed from dnsmasq's lease file. |
| `dhcp/leases6` (read-only collection) | `/tmp/(hosts/odhcpd|odhcpd.leases)` | IPv6 leases from odhcpd. Per-IA-address entries. |

Reload: `dnsmasq`, except `dhcp/odhcpd`, which declares `odhcpd`.

## System

| Path | Wraps | Notes |
|---|---|---|
| `system` (singleton) | `config system` | hostname, timezone, log_size, log_ip, log_proto, log_remote, urandom_seed. |
| `system/timeservers` | `config timeserver` | NTP server list; reloads sysntpd. |
| `system/password` | `/bin/busybox passwd` (non-uci, write-only) | `POST {user, password}` -> 204. Audit-logged without password. |
| `system/authorized_keys` | `/etc/dropbear/authorized_keys` (non-uci) | `GET`/`POST`/`PUT`/`DELETE` for SSH key entries. Server-side key-type validation. |
| `system/cron_jobs` | `/etc/crontabs/root` (non-uci) | `GET`/`POST`/`DELETE` for one crontab line each. Lines from packages stay as they are. `runtime.crond_running` reports whether crond runs, and `runtime.runs_as_written` flags a line crond misreads. |

## Other daemons

| Path | Wraps | Notes |
|---|---|---|
| `dropbear/instances` | `config dropbear` | Per-instance SSH config (port, password_auth, root_login, etc.). |
| `uhttpd/instances` | `config uhttpd` | Per-instance HTTP server. Validate refuses to strip uapi's own `ucode_prefix` from `main` (self-lockout protection). |
| `uhttpd/certs` | `config cert` | px5g cert generation params. |
| `unbound/server` (singleton) | `config unbound` | Recursive DNS tuning. |
| `unbound/srv` (singleton) | `config unbound_srv 'main'` | Server-clause directives (`interface_bind`, `interface_outgoing`, `ip_transparent`, plus a raw `srv_line` passthrough). Requires `apk add unbound-uci-ext` from the openwrt-iac feed; otherwise the first write returns `503 init_script_missing`. |
| `unbound/ext` (singleton) | `config unbound_ext 'main'` | Outside-server clauses (`forward-zone:`, `view:`, `stub:`, `remote-control:`) expressed as a verbatim `ext_line` list (one entry per rendered line). Same install dependency as `unbound/srv`. |
| `sqm/queues` | `config queue` | Per-interface SQM shaping. |
| `snmpd/agents` | `config agent` | SNMP listen addrs. |
| `snmpd/com2secs` | `config com2sec` | community-to-security mapping. |
| `snmpd/groups` | `config group` | SNMP group definitions. |
| `snmpd/accesses` | `config access` | group-to-view ACLs. |
| `snmpd/system` (singleton) | `config system` (snmpd) | sys_location, sys_contact, etc. (snake_case in v2). |
| `lldpd/config` (singleton) | `config lldpd 'config'` | LLDP/CDP/etc. toggles. |
| `prometheus_node_exporter_lua/config` (singleton) | `config prometheus-node-exporter-lua 'main'` | `listen_interface` + `listen_port`. |
| `vnstat/config` (singleton) | `config vnstat` | `interfaces`, the devices vnstat tracks (kernel device names, not uci interface names). The only vnstat option any shipped code reads. |
| `mwan3/globals` (singleton) | `config globals` | `mmx_mask`, `logging`, `loglevel`. |
| `mwan3/interfaces` | `config interface` (mwan3) | Per-WAN tracking: `track_ip`, `track_method`, probe sizing and timing, up/down thresholds, `flush_conntrack`. |
| `mwan3/members` | `config member` | Binds an `mwan3/interfaces` section to a `metric` and a `weight`. |
| `mwan3/policies` | `config policy` | `use_members` plus a `last_resort` verdict. |
| `mwan3/rules` | `config rule` (mwan3) | Traffic match (family, proto, src/dest ip and port, ipset) routed to a `use_policy`. |
| `openvpn/instances` | `config openvpn` | Per-instance OpenVPN config. `key`, `tls_auth` and `pkcs12` are write-only; responses carry `has_key` / `has_tls_auth` / `has_pkcs12`. |
| `usteer/config` (singleton) | `config usteer` | Band-steering and roaming thresholds for the usteer daemon. |

When unbound runs, a write to one of the three unbound resources waits 2 s after the reload. If unbound stops in that time, the write answers `500 reload_failed_restored` and restores the previous config. unbound stops for a line of `srv_line` or `ext_line` that it cannot parse. Two of these writes at the same time answer `423 locked` for the second, because each restarts unbound.

## Packages (non-uci)

| Path | Source of truth | Notes |
|---|---|---|
| `packages/installed` | apk DB | `GET` lists, `POST {name}` installs (`apk add`), `DELETE /<name>` removes. |
| `packages/feeds` | `/etc/apk/repositories.d/*.list` | `POST {name, url}` creates a feed file + `apk update`. |

## Anonymous sections and adoption

OpenWrt's uci distinguishes **named** sections (stable identifier across rewrites) from **anonymous** sections (auto-assigned `cfgXXXXXX` ids that change on rewrite). Anonymous ids are useless for IaC state tracking.

uapi-managed sections are always named: when a client POSTs to create a resource, the server emits a ULID-style identifier (Crockford base32, alphanumeric only, fitting uci's `[A-Za-z0-9_]` charset) and writes it as the section's `.name`. From that point on, the section behaves like any other named uci section and its id is stable. Optional one-character type prefix for grep-ability (`r_01HX...` for rules, `i_01HX...` for interfaces). No `uapi_` namespace prefix; uapi is just another writer to uci.

Section names are caller-pickable on every CRUD resource (since 2.2.0). `POST /<resource>` accepts an optional `id` field; if supplied it becomes the section name (after charset / length / collision checks). Absent, the server emits the ULID.

### Pre-existing anonymous sections

The common starting state for a router under management is a mix of LuCI-named sections, hand-edited sections, and anonymous sections from prior tooling. Posture: **read-only by default, explicit adoption.**

- `GET /<resource>` returns existing anonymous sections with a content-derived synthetic id and `managed: false`.
- `PUT`/`PATCH`/`DELETE` on a `managed: false` section returns `409 unmanaged_resource`.
- `POST /<resource>/<id>/adopt` on an **anonymous** section renames it under uapi's ULID scheme and flips it to `managed: true`. The section is writable like any other after that.
- `POST /<resource>/<id>/adopt` on a **named** section is an idempotent acknowledgement: the section keeps its name and the response carries the existing view with `managed: true`. The 2.2.0 behavior change replaced the prior rename-to-ULID which broke uci cross-references where sections referenced this one by name (`firewall.zones.lan` → `firewall.rules.src_zone = "lan"`).

Sections that already have a `.name` (e.g. LuCI-named `myrule`) are managed normally, using their existing `.name` as the id. uapi does not rewrite names it didn't author.

`GET` on a collection includes both managed and unmanaged sections by default. Clients filter via `?managed=true` / `?managed=false` when they want one or the other.

## Generic raw passthrough

`/api/v3/raw/<package>/<id>` is the escape hatch for any uci config type
uapi doesn't curate. See `docs/raw.md` for full semantics, scope
composition rules, and stability caveat.

## System endpoints

| Path | Auth | Notes |
|---|---|---|
| `GET /healthz` | none | `{status, version, checks: {ubus, uci, lock_dir, time_sync}}`. 503 when any subsystem is degraded. |
| `GET /openapi.json` | none | The OpenAPI 3.1 spec. |
| `GET /schema/<package>/<resource>` | none | One resource's `schema_properties`. `GET /schema` lists all keys. |
| `GET /auth/whoami` | any token | Token introspection: token_id, scopes, source_ip, expires_at, allowed_cidrs, last_used_at, last_used_ip. |
| `GET /tokens`, `POST /tokens`, `DELETE /tokens/<id>` | `uapi:tokens:rw` (or `*:rw`) | HTTP token rotation. POST requires the requested scopes to be a strict subset of the caller's. |
| `GET /metrics` | `uapi:metrics:ro` (or `*:ro`) | Prometheus 0.0.4 text. |
| `GET /diagnostics` | `uapi:diagnostics:ro` | Version, uptime, loaded resources, current lock holders. |
| `POST /batch` | each sub-request scope-checked | Multi-package all-or-nothing transaction (max 50 ops). |
