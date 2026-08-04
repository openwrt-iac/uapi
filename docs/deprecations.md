# uapi deprecations log

Canonical list of wire-surface fields that have been deprecated but are still accepted during a deprecation window. Each entry lives here from the release that deprecated it through the release that removes it.

A field is in the table below if and only if it is currently accepted-but-deprecated. Once removed (in a major release), the entry moves to the "Removed in past releases" section. Contract changes that are not field deprecations, and so cannot be expressed as a table row, are announced under "Announced response-shape changes".

Policy: a deprecation in a minor release means both forms (old and new) are accepted; the old form is marked `deprecated: true` in `build/openapi.json` so codegen tools surface a warning; the removal of the old form happens no sooner than the next major. One exception to the marker, explained under "How to migrate": a field that is not disappearing but losing only its write half cannot say so through that flag, because it has no read/write split.

## Active deprecations

| Field | Replaced by | Deprecated since | Removal target | Migration |
|---|---|---|---|---|
| `network/interfaces.name` (request input) | `network/interfaces.id` | 2.2.0 | v3 | Send `id` instead of `name` at create time. Both fields accept the same charset (uci section-name rules); on `proto=wireguard` both are IFNAMSIZ-tight (15 char cap). If both are supplied they must match or the request returns `422 conflict`. The `id` field is the universal "section name at create" input across every CRUD resource in 2.2.0; `name` was a 2.1.0-era shim that only worked on `network/interfaces`. |
| `network/interfaces.ipaddr` (request input) | `network/interfaces.ipaddrs` | 2.5.0 (targeted, not yet released) | v3 | Send `ipaddrs` instead. Both name the same uci `list ipaddr`, and the list already wins on write, so the migration is to stop sending the scalar rather than to change any value. `ipaddr` stays in responses after removal, carrying the first entry of the list; only the write is going away. See the note below on why this row carries no `deprecated: true` flag. |

## How to migrate

For each deprecated input field your client sends, switch to the replacement column. uapi accepts both during the window, so the migration can be staged: update writes first, observe nothing breaks, then drop the old field. Reads are unaffected (response shape unchanged during the window).

The OpenAPI spec at `/openapi.json` carries `deprecated: true` on every deprecated request field. Codegen tools that respect that flag (openapi-generator, oapi-codegen, etc.) will emit warnings in the generated client when you regenerate; that's the signal your client has surface area to migrate.

`network/interfaces.ipaddr` is the exception, and deliberately so. OpenAPI's
`deprecated` is a property-level flag with no read/write split, so setting it
would tell a generator the field is disappearing when in fact it survives as a
read field and only loses its write half. The v3 spec will say that precisely,
with `readOnly: true`. Until then the announcement lives in this table and in
the field's own `description`, which is the honest signal available. A client
that generates separate request and response models should drop `ipaddr` from
the request one.

## Announced response-shape changes

Not field deprecations, so they are not in the table above, but they change the
contract and are announced here for the same reason: so a client sees them
before the major that makes them.

- **List-valued fields will read back `null` when the uci key is absent, not
  `[]`** ([#39](https://github.com/openwrt-iac/uapi/issues/39)), targeted at v3.
  uci cannot store an empty list, so `[]` already means "absent" and
  distinguishes nothing; `null` is what that state should be. This is a
  convention change across every curated resource rather than a per-field one,
  and it breaks response validation for clients generated against the current
  `{"type": "array"}` schema. There is no way to stage it per field without
  leaving the surface inconsistent, which is why it waits for a major instead of
  arriving piecemeal.

- **`dhcp/hosts.tag` will read back as an array of strings, not a
  space-separated string**, targeted at v3. dnsmasq's tag construct is
  multi-valued: several tags may be set on one reservation, and a request has to
  match all of them. LuCI writes that form (`list tag`, from a `DynamicList`
  widget) and dnsmasq's host handler word-splits the option it reads, so
  `option tag 'a b'` and `list tag` are the same configuration to the daemon.
  uapi passes whichever shape uci holds straight through, so today the field
  reads back as `["a","b"]` for LuCI-authored config and `"a b"` for a
  hand-written scalar, while the published schema declares only
  `["string", "null"]`. A generated client therefore fails on configuration the
  stock OpenWrt UI produces, which makes this a correction rather than a
  preference. v3 settles the field on `["array", "null"]`, matching both the
  semantics and LuCI.

  Two halves of this do not need the major and should land in the minor that
  announces it: writes accept either shape and always persist `list tag`, so
  stored configuration converges early; and the schema stops promising a string
  it does not always return. Neither changes what an existing client receives for
  configuration it already round-trips.

## Removed in past releases

(none yet; uapi has not cut a v3.)
