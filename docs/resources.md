# Curated resources

This document indexes the 32 curated resources shipped in v2.0. For the full
schema (every field, its type, enum values, ranges, patterns), read
`build/openapi.json` (also served at `/api/v2/openapi.json` on a live
router) or open it in Swagger UI. Per-resource sample curls live in
`examples/curl/`.

The authoritative inventory is the OpenAPI spec; if this document drifts,
the spec wins.

## The daemon must be installed first

Curated resources that drive a daemon shipped as a separate OpenWrt
package (`unbound/server`, `sqm/queues`, `snmpd/*`, `openvpn/instances`,
`mwan3/*`, `vnstat/*`, `lldpd/config`, `prometheus_node_exporter_lua/config`,
`uhttpd/instances` beyond `main`) need the underlying package installed
before writes succeed. Writing to a resource whose daemon is absent
returns `503 init_script_missing` with the missing
`/etc/init.d/<service>` path in the response body, before any uci
write. The pre-flight check is part of the atomic transaction recipe;
no partial state is left behind.

Install the daemon either out of band (`apk add unbound`, etc.) or
through uapi itself via `POST /api/v2/packages/installed`. The latter
is what a Terraform configuration would chain via `depends_on` on a
`uapi_package` resource. The base uapi package's `Depends:` only
covers what uapi *itself* needs to run (uhttpd, ucode mods); per-daemon
packages are deliberately not pulled in.

## Network

| Path | Wraps | Notes |
|---|---|---|
| `network/interfaces` | `config interface` | Static/dhcp/dhcpv6/pppoe/wireguard. `runtime` block carries live ubus state (uptime, ipv4/ipv6 addresses, route table). |
| `network/devices` | `config device` | Bridges, VLANs (8021q/8021ad), macvlan, veth, tun/tap. |
| `network/routes` | `config route` | Static routes; cross-refs interface. |
| `network/rules` | `config rule` | Policy routing. |
| `network/bridge_vlans` | `config bridge-vlan` | Bridge VLAN tagging (vlan 1-4094 + port spec). |
| `network/wireguard_peers` | `config wireguard_<iface>` (dynamic) | Peers on a wireguard interface; preshared_key masked on read. |

Reload: `network` (netifd).

**Editing the interface that backs your management connection is dangerous.**
`/etc/init.d/network reload` returns exit 0 even when an interface fails to
come up at runtime; uapi only sees the init script's exit code, not the
daemon's runtime convergence.

## Firewall

| Path | Wraps | Notes |
|---|---|---|
| `firewall/zones` | `config zone` | input/output/forward policies, `network` list. |
| `firewall/rules` | `config rule` | Nested `match: {src_zone, dest_zone, src_ip, dest_ip, src_port, dest_port, proto, family}`. |
| `firewall/redirects` | `config redirect` | DNAT + NAT loopback reflection. |
| `firewall/forwardings` | `config forwarding` | Zone-to-zone forwarding. |
| `firewall/defaults` (singleton) | `config defaults` | Global verdicts, syn_flood, synflood_burst/rate, tcp_syncookies, flow_offloading. |

Reload: `firewall` (fw4).

## Wireless

| Path | Wraps | Notes |
|---|---|---|
| `wireless/devices` | `config wifi-device` | Radios (mac80211/broadcom), band, channel, htmode, country, txpower. |
| `wireless/interfaces` | `config wifi-iface` | SSIDs. `key` write-only; responses include `has_key: bool`. `runtime` carries iwinfo state. |

Reload: `network`. Requires `rpcd-mod-iwinfo` at runtime for the
`runtime` block on `wireless/interfaces`.

## DHCP

| Path | Wraps | Notes |
|---|---|---|
| `dhcp/hosts` | `config host` | Static leases. `mac` (or `mac_aliases` for multi-MAC), `ip`, `name`, `leasetime`, `duid`, `tag`. |
| `dhcp/servers` | `config dhcp` | Per-interface server config. `runtime` carries active-lease counts. |
| `dhcp/dnsmasq` (singleton) | `config dnsmasq` | Global dnsmasq tuning; forwarders, address overrides, rebind protection. |
| `dhcp/odhcpd` (singleton) | `config odhcpd` | `maindhcp`, `leasefile`, `loglevel`. |
| `dhcp/leases` (read-only collection) | `/tmp/dhcp.leases` | IPv4 leases parsed from dnsmasq's lease file. |
| `dhcp/leases6` (read-only collection) | `/tmp/(hosts/odhcpd|odhcpd.leases)` | IPv6 leases from odhcpd. Per-IA-address entries. |

Reload: `dnsmasq` (the `dhcp` package's ucitrack fan-out covers odhcpd).

## System

| Path | Wraps | Notes |
|---|---|---|
| `system` (singleton) | `config system` | hostname, timezone, log_size, log_ip, log_proto, log_remote, urandom_seed. |
| `system/timeservers` | `config timeserver` | NTP server list; reloads sysntpd. |
| `system/password` | `/bin/busybox passwd` (non-uci, write-only) | `POST {user, password}` -> 204. Audit-logged without password. |
| `system/authorized_keys` | `/etc/dropbear/authorized_keys` (non-uci) | `GET`/`POST`/`PUT`/`DELETE` for SSH key entries. Server-side key-type validation. |

## Other daemons

| Path | Wraps | Notes |
|---|---|---|
| `dropbear/instances` | `config dropbear` | Per-instance SSH config (port, password_auth, root_login, etc.). |
| `uhttpd/instances` | `config uhttpd` | Per-instance HTTP server. Validate refuses to strip uapi's own `ucode_prefix` from `main` (self-lockout protection). |
| `uhttpd/certs` | `config cert` | px5g cert generation params. |
| `unbound/server` (singleton) | `config unbound` | Recursive DNS tuning. |
| `sqm/queues` | `config queue` | Per-interface SQM shaping. |
| `snmpd/agents` | `config agent` | SNMP listen addrs. |
| `snmpd/com2secs` | `config com2sec` | community-to-security mapping. |
| `snmpd/groups` | `config group` | SNMP group definitions. |
| `snmpd/accesses` | `config access` | group-to-view ACLs. |
| `snmpd/system` (singleton) | `config system` (snmpd) | sys_location, sys_contact, etc. (snake_case in v2). |
| `lldpd/config` (singleton) | `config config` (lldpd) | LLDP/CDP/etc. toggles. |
| `prometheus_node_exporter_lua/config` (singleton) | `config main` | listen + per-collector toggles. |
| `vnstat/config` (singleton) | `config vnstat` | database_dir, interface_5min_hours, month_rotate (snake_case in v2). |
| `vnstat/interfaces` | `config interface` (vnstat) | Per-iface enable. |

## Packages (non-uci)

| Path | Source of truth | Notes |
|---|---|---|
| `packages/installed` | apk DB | `GET` lists, `POST {name}` installs (`apk add`), `DELETE /<name>` removes. |
| `packages/feeds` | `/etc/apk/repositories.d/*.list` | `POST {name, url}` creates a feed file + `apk update`. |

## Generic raw passthrough

`/api/v2/raw/<package>/<id>` is the escape hatch for any uci config type
uapi doesn't curate. See `docs/raw.md` for full semantics, scope
composition rules, and stability caveat.

## System endpoints

| Path | Auth | Notes |
|---|---|---|
| `GET /healthz` | none | `{status, version, checks: {ubus, uci, lock_dir, time_sync}}`. 503 when any subsystem is degraded. |
| `GET /openapi.json` | none | The OpenAPI 3.1 spec. |
| `GET /schema/<package>/<resource>` | none | One resource's `schema_properties`. `GET /schema` lists all keys. |
| `GET /auth/whoami` | any token | Token introspection: id, scopes, source_ip, expires_at, allowed_cidrs, last_used. |
| `GET /tokens`, `POST /tokens`, `DELETE /tokens/<id>` | `uapi:tokens:rw` (or `*:rw`) | HTTP token rotation. POST requires the requested scopes to be a strict subset of the caller's. |
| `GET /metrics` | `uapi:metrics:ro` (or `*:ro`) | Prometheus 0.0.4 text. |
| `GET /diagnostics` | `uapi:diagnostics:ro` | Version, uptime, loaded resources, current lock holders. |
| `POST /batch` | each sub-request scope-checked | Multi-package all-or-nothing transaction (max 50 ops). |
