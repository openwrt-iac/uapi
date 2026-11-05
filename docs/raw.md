# `/api/v3/raw/<package>/<id>`: generic uci passthrough

The curated endpoints (`/firewall/rules`, `/network/interfaces`, etc.) wrap a small set of OpenWrt config types with stable schemas and Terraform-friendly JSON. For everything else, `/raw/` gives you the underlying uci surface with the same atomic-transaction guarantees and the same auth model.

**`/raw/` is not raw ubus.** The endpoint exposes arbitrary uci packages and section types, not arbitrary ubus services. Sending ubus calls directly through uapi remains off-limits. The closest uapi gets to ubus is reading the runtime block (`runtime: {...}`) that curated resources populate from selected ubus calls; that is per-resource, hand-curated, and read-only.

## Stability

**URL structure, verbs, auth/scope behavior, and error envelope are
stable within a package major** (today: v3.x). The composition rule
(`raw:*` permission + the section's domain-tree permission both
required) is part of the contract and will not loosen across minor
bumps.

**Payload shape follows uci.** uci is OpenWrt's moving target: when an
OpenWrt release renames a field, drops a section type, or changes the
default for an option, `/raw/<that-package>/...` payloads change with
it. Track those upstream changes the way you'd track them if you were
editing `/etc/config/...` directly.

If you want a stable, semver-bound contract, use the curated endpoint
for that resource if one exists, or open an issue to add one.

## Shape

`GET /api/v3/raw/<package>` lists every section in the package as an array. Each item has:

```json
{
  "id": "<section name>",
  ".type": "<section type>",
  "managed": true,
  "<option1>": "...",
  "<option2>": ["..."],
  ...
}
```

`managed: true` means the section has a real `.name` (named at creation by uapi or by another tool); `managed: false` means it is anonymous (`cfg012345`-style). uapi does not distinguish between writes to anonymous and named sections via `/raw/`. It is derived from uci's `.anonymous` flag on every read and is never stored, so `/raw/` ignores it on write: sending `managed` in a body neither changes the section nor lands as an option. Before 2.5.0 it did land, as a literal `option managed`, and that stored string then shadowed the derived value on read. `reloaded`, `reload_services` and `reload_note`, which a write response adds, are ignored the same way, so a client can send a response back unchanged. Before 3.2.0 they landed as options too. A `PATCH` removes these four stored options, as a `PUT` does. Since v4 (#321) there is no adopt flow: a pre-existing section is addressed by its name, anonymous or not.

`GET /api/v3/raw/<package>/<id>` returns one section in the same shape.

`id` is always the section name, also when the path gives a position that uci resolves, such as `@rule[0]` or `@[-1]`. A write then acts on the section that the position named before the lock, and an `id` in its body must be that name. A section that stores an option named `id`, such as a zerotier `network`, does not show that option, and a `PUT` keeps it.

`POST /api/v3/raw/<package>` creates a section. The request body must include `.type`. If `id` is supplied, it must match `/^[A-Za-z0-9_]+$/` (uci's section-name charset) and must not collide with an existing section; otherwise uapi returns `422 validation_failed` with field `id` and code `invalid_format`, or `409 conflict` respectively. If `id` is omitted, `null` or empty, uapi generates a ULID-style id. Its prefix is the first letter of the type in lowercase, or `u` when the type does not start with a letter.

```json
{
  ".type": "rule",
  "target": "ACCEPT",
  "src": "lan",
  "dest_port": "8080",
  "proto": "tcp"
}
```

The response is the section as uci stores it, as a `GET` reads it, plus:

```json
{
  ...
  "reloaded": true,
  "reload_services": ["firewall"]
}
```

`reloaded: false` plus a `reload_note` string when uapi does not know which service to reload for the package. The configuration is on disk, and you must reload the relevant daemon manually. Since 3.2.0 a `PATCH` that sends no option also answers `reloaded: false`, an empty `reload_services` and a `reload_note`, because it writes nothing and so reloads nothing. A write to `dhcp` when procd runs none of dnsmasq, odhcpd and unbound answers the same, with a `reload_note` that says so. A `dhcp` write whose `dnsmasq --test` check did not finish within 10 s answers `reloaded: true` and a `reload_note` that says so, and keeps its commit. So does a write whose reload was still running when uapi stopped waiting for it, 20 s after the first reload of the request started: the `reload_note` names that reload and the ones that follow it. Since 3.3.0 a `PUT` or `PATCH` skips each option that uci already holds as sent, a boolean as `1` or `0` and a number as its text, so a `PUT` of the read commits nothing and answers the same way. Such a write still answers `409 conflict` when another writer deleted the section during the request. A list sent for an option that uci holds as a single value, or the reverse, is a change.

A package needs its file under `/etc/config/` before a write, as with `uci` itself. Without one, a `POST` answers `503 config_missing` and creates nothing, and a `PUT`, `PATCH` or `DELETE` answers `404`, because no section can exist. An empty file is enough, for example after `touch /etc/config/<package>`.

An option name takes letters, digits and `_`, the names that uci stores. Names that start with `.` are reserved. A value is a string, a number, a boolean or a list of them. uci stores text, so a read gives back `true` as `"1"`, `false` as `"0"`, and a number as its text with at most 14 significant digits. `null`, `""` and `[]` remove an option. A list of several items cannot start with `""`, because uci drops that item. `.type` takes printable ASCII without spaces and without `"`, `#`, `'`, `;` or `\`, because uci writes the type unquoted and would read these back as syntax. Anything else answers `422`, with every refused field in one response. On every endpoint, a key or a string with a NUL, or with a control character other than tab, newline and carriage return, answers `400`.

`PUT` replaces all non-meta options. `PATCH` merges. `DELETE` is `204 No Content`. In a `PUT` or `PATCH`, a `.type` or `id` must match the section, because raw cannot retype or rename it. Another value answers `422 read_only`.

## Auth

Every raw request needs **two** scope checks, evaluated independently:

1. **Raw tree**: `raw` or `raw:<package>` must permit the verb.
2. **Domain tree**: the section's `.type` is mapped to its curated domain path (`firewall.rule` -> `firewall:rules`, etc.) and the same verb must be permitted there. For packages not in the curated map, the domain path is just `[<package>]`.

The dual check exists so granting `raw:rw` does not silently bypass a carefully-scoped `firewall:rules:ro`. If the deepest matching scope on either tree denies, the request is denied.

For packages absent from that map (e.g. `openvpn`, `mwan3`, `usteer`), only `*:rw` or a package-level scope like `openvpn:rw` permits the domain side.

## Reload mapping

The reload service list is computed from `/etc/config/ucitrack` plus a small fallback table for known packages:

| Package    | Reload services |
|------------|-----------------|
| network    | network, then odhcpd while procd runs it |
| wireless   | network         |
| firewall   | firewall        |
| dhcp       | dnsmasq, odhcpd and unbound, each while procd runs it |
| system     | system, then dnsmasq, odhcpd and unbound, each while procd runs it |

If `/etc/config/ucitrack` has an entry for the package, its `option init` (plus `list affects` chain) takes precedence over the fallback table. The fallback follows what a LuCI save reloads, except for `network` and `wireless`. dnsmasq, odhcpd and unbound have a procd trigger on `dhcp`, dnsmasq and odhcpd one on `system`, and odhcpd one on `network`. LuCI's `/usr/share/ucitrack/luci-mod-system-system.json` has `system` affect `dhcp`, its `luci-mod-network-interfaces.json` has `network` affect `dhcp`, and its `luci-mod-network-wireless.json` has `wireless` affect `network`, so a LuCI save of any of these packages reloads all three. Since 3.3.0 a `network` write reloads odhcpd, which reads the network config, and leaves dnsmasq and unbound out on purpose, and a `wireless` write reloads `network` only, as before. From `/etc/config/network`, dnsmasq.init reads only `ula_prefix` of the globals, and unbound reads that and the names of the interface sections. No curated resource writes the globals, none of the three daemons reads `/etc/config/wireless`, and dnsmasq and unbound already reload on the netifd events of the interfaces that they serve: dnsmasq for the interface of each `dhcp` section that it serves, unbound for the interfaces of its `iface_trig` list. Reloading them on every network or wireless write would hold its locks for two more init scripts and, while unbound runs, a 2 s watch, would take the lock of `unbound`, which `dhcp`, `system` and unbound writes share, and would fail the write with a restore when unbound stops for a reason of its own. A raw write of `ula_prefix` reaches dnsmasq and unbound at their next reload, such as the one of a `dhcp` write. A write to `dhcp` or `system` takes the lock of `unbound` while `/etc/init.d/unbound` exists, whether unbound runs or not, so it answers `423 locked` at the same moment as a write to unbound or another of them (`docs/architecture.md` § Lock layout). Each of them is reloaded when its init script exists and procd holds a `config.change` trigger for it, which is when a LuCI save reloads it, or when the `service list` call fails, since uapi then cannot tell. procd holds the triggers from the start of the service to its stop, whatever its instances show, so a write starts again a daemon that crashed too often, and starts dnsmasq when it enables a `dnsmasq` section while every other one is disabled. A router without the daemon, or with the daemon stopped, skips it: the write does not answer `503 init_script_missing` for it, and the reload does not start it, as the reload of dnsmasq.init and unbound.init would. At boot, unbound registers only a trigger on interface events, which starts it 3 s after the last of them, so a write before that skips it too.

## Examples

See `examples/curl/raw.sh` for end-to-end usage.

## When not to use `/raw/`

If a curated endpoint exists for the section type, prefer it. The curated layer:

- Normalizes `"1"`/`"0"`/`"on"`/`"off"` to real JSON booleans.
- Lifts single-value uci list options to JSON arrays consistently.
- Validates per-field (formats, enums, cross-references) before staging.
- Returns a stable schema that survives uci-side renames.
- Generates ULID IDs that survive `/etc/config` rewrites.

`/raw/` skips all of that. It is the escape hatch, not the front door.
