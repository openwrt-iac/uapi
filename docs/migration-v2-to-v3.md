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

## Removed request fields are ignored, not rejected

Read this before assuming a green test run means a client has migrated.

uapi drops request keys it does not model, and a removed field is indistinguishable from a key
that never existed. So a v2 client that still sends `mac`, `mac_aliases`, `managed` or
any of the dead fields below gets `200`, and the value goes nowhere (`ipaddr` is the one
exception, below):

```
# against v3, on a host whose reservation lists two MACs
PATCH /api/v3/dhcp/hosts/printer {"mac": "aa:bb:cc:dd:ee:01"}
-> 200, and uci still holds both original entries
```

That is the same rule every unknown key has always followed, and changing it for these four
names alone would mean carrying the removed vocabulary into v3 just to refuse it. The cost is
that a stale write fails silently, which is why regenerating the client matters more here than
across a normal upgrade: codegen against the v3 spec turns each of these into a compile error
instead of a no-op.

**`network/interfaces.name` on create is the sharpest case.** It does not 422. A section name is
required to create anything, so when `id` is absent uapi emits one, exactly as it does for a
body that names no section at all:

```
POST /api/v3/network/interfaces {"name": "lan2", "proto": "static", "ipaddrs": ["192.0.2.77"]}
-> 200 {"id": "i_01kznhag1a6yg3qgmv85bgmhh7", ...}
```

The interface exists and carries the right addresses, under a name the caller never chose and
will not find again by the name it sent. An IaC client that keys resources by the name it
requested reads that back as drift and creates a second one on the next apply. Rename the field
to `id` before upgrading, not after the first apply.

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
