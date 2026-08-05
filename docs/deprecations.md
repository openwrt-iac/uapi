# uapi deprecations log

Canonical list of wire-surface fields that have been deprecated but are still accepted during a deprecation window. Each entry lives here from the release that deprecated it through the release that removes it.

A field is in the table below if and only if it is currently accepted-but-deprecated. Once removed (in a major release), the entry moves to the "Removed in past releases" section. Contract changes that are not field deprecations, and so cannot be expressed as a table row, are announced under "Announced response-shape changes".

Policy: a deprecation in a minor release means both forms (old and new) are accepted; the old form is marked `deprecated: true` in `build/openapi.json` so codegen tools surface a warning; the removal of the old form happens no sooner than the next major. One exception to the marker, explained under "How to migrate": a field that is not disappearing but losing only its write half cannot say so through that flag, because it has no read/write split.

## Active deprecations

| Field | Replaced by | Deprecated since | Removal target | Migration |
|---|---|---|---|---|
| `network/interfaces.name` (request input) | `network/interfaces.id` | 2.2.0 | v3 | Send `id` instead of `name` at create time. Both fields accept the same charset (uci section-name rules); on `proto=wireguard` both are IFNAMSIZ-tight (15 char cap). If both are supplied they must match or the request returns `422 conflict`. The `id` field is the universal "section name at create" input across every CRUD resource in 2.2.0; `name` was a 2.1.0-era shim that only worked on `network/interfaces`. |
| `network/interfaces.ipaddr` (request input) | `network/interfaces.ipaddrs` | 2.5.0 (targeted, not yet released) | v3 | Send `ipaddrs` instead. Both name the same uci `list ipaddr`, and the list already wins on write, so the migration is to stop sending the scalar rather than to change any value. `ipaddr` stays in responses after removal, carrying the first entry of the list; only the write is going away. See the note below on why this row carries no `deprecated: true` flag. |
| `dhcp/hosts.mac` (request and response) | `dhcp/hosts.macs` | 2.5.0 (targeted, not yet released) | v3 | Send `macs` instead, and read it instead. All three names describe one uci `list mac`: `macs` is the whole list, `mac` its first entry and `mac_aliases` the rest. The list wins on write, so the migration is to stop sending the split rather than to change any value. Unlike `network/interfaces.ipaddr`, this one does not survive as a read field, which is why it carries the `deprecated: true` flag: uci has no scalar `option mac` for a host, so `mac` was never a uci field at all, only uapi's positional half of a list. There is nothing for it to keep meaning once `macs` exists. |
| `dhcp/hosts.mac_aliases` (request and response) | `dhcp/hosts.macs` | 2.5.0 (targeted, not yet released) | v3 | Send `macs` instead, and read it instead. Same single uci `list mac` as the row above: `mac_aliases` held every entry after the first, so a client had to concatenate two fields to learn what the reservation actually matched. Flagged `deprecated: true` for the same reason. |

Every entry above must also appear in the published spec's own description, under
"Upcoming in v3". That is checked by `make lint-doc-refs`: the ledger and the spec are
compared, and a change announced in one but not the other fails the build. The check exists
because the list-reads-`null` change was recorded here and in the changelog while appearing
nowhere in `build/openapi.json`, so a consumer generating a client got no notice at all of
the one change most likely to break its response validation. Announcing in a minor is only
worth doing if the notice reaches the artifact people consume.

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

  Two halves of this did not need the major and have landed ahead of it. The
  schema declares the union the resource actually returns,
  `["string", "array", "null"]`, so a generated client stops being wrong about
  the list case. And the field is type-checked for the first time, which is what
  stops an object or a number reaching uci as an option value; that half is a
  tightening under the `docs/versioning.md` carve-out, since the payloads it now
  rejects could only ever have produced configuration no caller could rely on.

  Writes deliberately persist the shape they were given instead of normalizing
  every write to `list tag`. Normalizing looks tidier and was the original plan,
  but it would convert a stored scalar the first time any client wrote the
  section back, so a body read and written back unchanged would come back
  changed, which is the one thing the read-honesty property forbids. Storage does
  not need to converge for the v3 read in any case: splitting a stored scalar on
  the read side arrives at the same place without rewriting configuration nobody
  asked us to touch.

## Removed in past releases

(none yet; uapi has not cut a v3.)
