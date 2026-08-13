# Migrating from uapi v2 to v3

v3 removes what 2.5.0 announced and nothing else. Every change below appeared in the 2.5.0
spec's own "Upcoming in v3" block and in `docs/deprecations.md`, so a client generated against
2.5.0 has already been warned by its codegen about the flagged fields.

A given uapi installation serves exactly one API major. There is no parallel `/api/v2/` and
`/api/v3/` mount in the same binary. Operators who need to keep a v2 client working keep the
`2.5.x` package installed; the 2.5.0 APK stays on its GitHub Release and the signed `v2.5.0`
tag is the canonical v2 contract document.

**The URL prefix changes from `/api/v2/` to `/api/v3/`.** Update every client-side base URL.
Upgrading the package removes the v2 prefix from uhttpd's `ucode_prefix` list and adds the v3
one, so no manual uci edit is needed.

## Upgrade path

1. `apk update && apk upgrade uapi`
2. Change your base URL from `/api/v2` to `/api/v3`
3. Regenerate any typed client. Model names change: every resource now has a separate
   `<Name>Request` and `<Name>Response` schema
4. Verify: `GET /api/v3/healthz` returns `{"status":"ok","version":"3.0.0",...}`

## Removed request fields are rejected (Breaking)

A request naming a field the resource does not declare answers `422` with field code
`unknown_field`, naming the path. In v2 such a key was dropped in silence, so a stale write
answered `200` and changed nothing:

```
# on a host whose reservation lists two MACs
PATCH /api/v3/dhcp/hosts/printer {"mac": "aa:bb:cc:dd:ee:01"}
-> 422 validation_failed, errors[0] = { field: "mac", code: "unknown_field" }
```

This is the one breaking change in v3 that makes migration easier rather than harder. A client
that still sends `mac`, `mac_aliases` or any removed field below now fails loudly on the first
apply, instead of reporting success while the value went nowhere. Regenerating the client is
still the right fix, and codegen against the v3 spec turns each of these into a compile error
before a request is ever sent.

**`network/interfaces.name` on create fails now too.** In v2 it was the sharpest silent case:
uapi generated a section name, so the interface came back under a name the caller never chose,
which an IaC client keying on its requested name read as drift and duplicated on the next apply.
That cannot happen in v3:

```
POST /api/v3/network/interfaces {"name": "lan2", "proto": "static", "ipaddrs": ["192.0.2.77"]}
-> 422 validation_failed, errors[0] = { field: "name", code: "unknown_field" }
```

Rename the field to `id` and the create succeeds.

**Three names stay accepted and ignored, on purpose.** `id`, `managed` and `runtime` appear in
every response and in no request schema, and every IaC apply is a read-modify-write, so refusing
them would break sending a read straight back. The same holds for a field that is `readOnly`
rather than removed: `network/interfaces.ipaddr` still exists in the model as a read, so a body
carrying it answers `200` and the value is ignored. Only names the resource does not model at
all are refused.

## Field removals (Breaking)

### `dhcp/hosts`

`mac` and `mac_aliases` are gone. `macs` is the only name, and it is the whole uci `list mac`
as one array.

```
# v2
{"mac": "aa:bb:cc:dd:ee:01", "mac_aliases": ["aa:bb:cc:dd:ee:02"]}

# v3
{"macs": ["aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"]}
```

Neither removed name was ever a uci option: `mac` was the first entry of the list and
`mac_aliases` the rest, so a client had to read two fields to learn what one reservation
matched. Validation errors that were reported against `mac` now report against `macs`.

### `network/interfaces`

`name` is gone as a create input. Send `id`, which is the universal section-name input across
every CRUD resource and has been since 2.2.0.

```
# v2
POST /network/interfaces {"name": "wg0", "proto": "wireguard", ...}

# v3
POST /network/interfaces {"id": "wg0", "proto": "wireguard", ...}
```

The `422 conflict` that fired when `id` and `name` disagreed is gone with the field.

`ipaddr` is now read-only. It still appears in responses carrying the first entry of the uci
`list ipaddr`; it is simply absent from the request schema. Send `ipaddrs`.

This is the one removed field that does **not** fail silently, and deliberately so. A static
interface needs an address, and counting a field no write can act on as one produced an
interface with no address and a `200`:

```
# v2: accepted, and the address landed
# v3: 422, ipaddrs required
POST /api/v3/network/interfaces {"id": "lan2", "proto": "static", "ipaddr": "192.0.2.99"}
```

A read-modify-write client is unaffected, because a `GET` returns `ipaddrs` alongside `ipaddr`
and echoing the body back carries the list.

### Fields that wrote a uci option nothing reads

Removed entirely, in both directions. Writes carrying them were already ignored, so nothing on
the write side needs migrating; what changes is that they no longer appear in responses, where
each used to carry a `default:` annotation an IaC client may have been keeping sticky.

| Resource | Removed |
|---|---|
| `mwan3/globals` | `local_source`, `rtmon_interval` |
| `vnstat/config` | `database_dir`, `interface_5min_hours`, `month_rotate` |
| `lldpd/config` | `enable_lldpmed` |
| `unbound/server` | `enabled`, `prefetch` |
| `usteer/config` | `max_assoc_sta` |
| `prometheus_node_exporter_lua/config` | `listen_ipv6` and all 17 collector toggles |

The per-field reasoning is in the 2.5.0 changelog entry. In short: each was modelled against an
option name the owning daemon does not consult, and none had a correctly-named counterpart to be
repointed at.

## Endpoint removals (Breaking)

### `vnstat/interfaces`

Gone. Use the `interfaces` array on the `vnstat/config` singleton.

**The values differ in kind, not just in place.** The removed endpoint took uci interface
section names; vnstat wants device names as the kernel shows them. Migrating is a translation,
not a copy:

```
# v2
POST /vnstat/interfaces {"interface": "lan"}

# v3
PATCH /vnstat/config {"interfaces": ["br-lan"]}
```

The endpoint never worked: uapi modelled `config interface` sections while vnstat only reads a
`list interface` inside `config vnstat`, so a `POST` returned 200 and changed nothing the daemon
looked at.

## Response-shape changes (Breaking)

### List-valued fields read back `null` when the uci key is absent

Previously `[]`. uci cannot store an empty list, so `[]` already meant "absent" and
distinguished nothing. A client generated against the v2 `{"type": "array"}` schema fails
response validation in v3 unless it accepts null.

This affects every uci-backed list on a curated resource. It does **not** affect the request
and response envelopes (`BatchResponse.results`, `ErrorEnvelope.errors`, and the rest), where
`[]` means empty rather than absent and is correct.

### `firewall/redirects` match fields are scalars

Six fields under `match` change from an array capped at one entry to a plain string:
`src_ip`, `src_dip`, `src_dport`, `dest_ip`, `dest_port`, `src_port`.

```
# v2
{"match": {"src_zone": "wan", "src_dport": ["443"], "dest_ip": ["192.168.1.10"]}}

# v3
{"match": {"src_zone": "wan", "src_dport": "443", "dest_ip": "192.168.1.10"}}
```

firewall4 marks only `proto`, `src_mac` and `reflection_zone` as list options on a
`config redirect`, and its parser refuses a list on the rest outright, discarding the whole
section. The cap existed to stop uapi writing one; 2.4.0 could not narrow the type because that
needs a major. `proto` is genuinely a list and does not change.

The reason to care is when the mistake is caught. A second value used to be accepted by the
schema and rejected at apply, after a declarative client had already committed to a plan and
possibly written other resources. A string makes it a type error before anything is written.

Validation errors on these fields lose their index: `match.src_dport` rather than
`match.src_dport[0]`.

### `dhcp/hosts.tag` is array-only

Responses have been arrays since 2.5.0. v3 drops the space-separated string on the request side
too. dnsmasq word-splits either form identically, so the value does not change, only its
spelling.

### `managed` leaves every request schema

It is derived from uci's `.anonymous` flag and no write path ever read it, so a `PUT` sending
`managed: false` always answered 200 with `managed: true`. It is present and read-only in
response schemas. Management state moves through `POST /<resource>/{id}/adopt`.

### Separate request and response schemas

Every resource now has `<Name>Request` and `<Name>Response` instead of one `<Name>`. This is
what makes the three items above expressible at all: a single schema serving both directions
could not say that `ipaddr` is readable but not writable, or that `tag` accepts one shape and
returns another.

Regenerated clients get new model names for every resource.
