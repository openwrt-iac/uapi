# Curated resources

This is a sketch of what each curated endpoint does. For the full schema (every field, its type, enum values where applicable), read `build/openapi.json` (also served at `/api/v1/openapi.json` on a live router) or open it in Swagger UI.

The curl example for each is in `examples/curl/`.

## `/api/v1/firewall/rules`

Wraps `config rule` in `/etc/config/firewall`. Full CRUD.

Curated shape uses a nested `match: {src_zone, dest_zone, src_ip, dest_ip, src_port, dest_port, proto, family}` block to keep the top level focused on what the rule *does* (`target`, `enabled`, `name`). Cross-reference validation rejects rules referencing zones that don't exist.

Reload: `firewall` (fw4).

## `/api/v1/firewall/zones`

Wraps `config zone`. `input`/`output`/`forward` policies, `network` list (interfaces this zone covers), `masq`/`mtu_fix` toggles.

Reload: `firewall`.

## `/api/v1/firewall/redirects`

Wraps `config redirect` (port forwards). Like rules but with `src_dport`/`dest_ip`/`dest_port` for DNAT and `target` defaulting to `DNAT`.

Reload: `firewall`.

## `/api/v1/network/interfaces`

Wraps `config interface` in `/etc/config/network`. `proto` (static/dhcp/dhcpv6/pppoe/none/ppp/wwan), `ipaddr`/`netmask`/`gateway`/`dns` for static, plus `device`, `mtu`, `auto`, `ip6assign`.

**Be careful editing the interface that backs your management connection.** `/etc/init.d/network reload` returns exit 0 even when an interface fails to come up at runtime; you can lose the box. uapi only sees the init script's exit code, not the daemon's runtime convergence. Use `/raw/network/<id>` if you need finer control over the timing, or front the API with a session that survives the reload.

Reload: `network` (netifd).

## `/api/v1/network/devices`

Wraps `config device` (bridges, VLANs, etc.). `type` enum (`bridge`, `8021q`, `8021ad`, `macvlan`, `veth`, `tun`, `tap`). For bridges, `ports` is the member-interface list. For 8021q, `vid` is the VLAN id.

Reload: `network`.

## `/api/v1/wireless/devices`

Wraps `config wifi-device` (radios). `type` (`mac80211`/`broadcom`), `band` (`2g`/`5g`/`6g`/`60g`), `channel`, `htmode`, `country`, `txpower`, `disabled`.

Reload: `network`.

## `/api/v1/wireless/interfaces`

Wraps `config wifi-iface` (SSIDs). `device` references a wifi-device id, `network` references a network interface, `mode` (`ap`/`sta`/etc.), `ssid`, `encryption`, `key`, plus flags.

**The `key` field is write-only.** `fromUci` does not return it. Responses include `has_key: true` when one is set, so clients can tell whether a key exists without seeing it. To rotate, send `{"key": "newvalue"}` via PATCH.

Reload: `network`.

## `/api/v1/dhcp/hosts`

Wraps `config host` (static leases) in `/etc/config/dhcp`. `mac` and `ip` required, plus optional `name`, `leasetime`, `tag`, `dns` (whether to add a DNS entry).

Reload: `dnsmasq`.

## `/api/v1/dhcp/leases` (read-only)

Source: `/tmp/dhcp.leases` (IPv4 only in v1). One entry per active lease: `expires_at` (unix ts), `mac`, `ip`, `hostname`, `duid`.

`GET /api/v1/dhcp/leases` returns the full list. `GET /api/v1/dhcp/leases/<mac>` returns one. All write methods return `405 method_not_allowed`.

IPv6 leases (via odhcpd) are not exposed in v1.

## `/api/v1/system` (singleton)

Wraps the lone `config system` section in `/etc/config/system`. `hostname`, `description`, `notes`, `timezone`, `zonename`, `log_size`, `log_ip`, `log_proto`, `log_remote`, `urandom_seed`.

GET and PATCH only. No POST or DELETE (you can't create or remove the singleton). The URL has no `/<id>` segment.

Reload: none (system config is read on demand).

## `/api/v1/raw/<package>/<id>` (generic)

The escape hatch for any uci config type uapi doesn't curate. See `docs/raw.md` for full semantics, scope composition rules, and the stability caveat.

## `/api/v1/healthz` and `/api/v1/openapi.json`

`/healthz` is a no-auth liveness probe (TLS-for-non-localhost still applies). Returns `{status: "ok", version}` or 503 if ubus is unreachable.

`/openapi.json` is the OpenAPI 3.1 spec, no auth, public for tooling.
