# uapi deprecations log

Canonical list of wire-surface fields that have been deprecated but are still accepted during a deprecation window. Each entry lives here from the release that deprecated it through the release that removes it.

A field is in the table below if and only if it is currently accepted-but-deprecated. Once removed (in a major release), the entry moves to the "Removed in past releases" section. Contract changes that are not field deprecations, and so cannot be expressed as a table row, are announced under "Announced response-shape changes".

Policy: a deprecation in a minor release means both forms (old and new) are accepted; the old form is marked `deprecated: true` in `build/openapi.json` so codegen tools surface a warning; the removal of the old form happens no sooner than the next major. One exception to the marker, explained under "How to migrate": a field that is not disappearing but losing only its write half cannot say so through that flag, because it has no read/write split.

## Active deprecations

None. 3.0.0 removed everything 2.5.0 had announced, and nothing new is deprecated yet.

A field belongs in this section if and only if it is currently accepted-but-deprecated. Once
removed in a major it moves to `Removed in past releases` below.

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

None. See `Removed in past releases` for what 3.0.0 carried out.

## Removed in past releases

### 3.0.0

| Field | Replaced by | Deprecated since | Removed in |
|---|---|---|---|
| `network/interfaces.name` (request input) | `network/interfaces.id` | 2.2.0 | 3.0.0 |
| `dhcp/hosts.mac` (request and response) | `dhcp/hosts.macs` | 2.5.0 | 3.0.0 |
| `dhcp/hosts.mac_aliases` (request and response) | `dhcp/hosts.macs` | 2.5.0 | 3.0.0 |

Also removed in 3.0.0, announced as response-shape changes rather than as ledger rows because
neither survived as a read:

- **`vnstat/interfaces`, the whole endpoint.** It modelled `config interface` sections, which
  vnstat never reads. Use the `interfaces` array on `vnstat/config`, remembering that the values
  differ in kind: the dead endpoint took uci interface names (`lan`), vnstat wants device names
  (`br-lan`).
- **The 27 fields that wrote a uci option no OpenWrt component reads**, in `mwan3/globals`,
  `vnstat/config`, `lldpd/config`, `unbound/server`, `usteer/config` and
  `prometheus_node_exporter_lua/config`. Writes carrying them were already ignored; what changes
  is the read side, since each was returned with a `default:` annotation. The per-field reasons
  are in the 2.5.0 announcement, preserved in that release's changelog entry.

- **List-valued fields read back `null`, not `[]`, when the uci key is absent.** uci cannot
  store an empty list, so `[]` already meant "absent" and distinguished nothing. It also lets a
  list field carry `x-uapi-clear-on-omit`, which the old shape made impossible. The request and
  response envelopes keep `[]`, where it means empty rather than absent.

- **`network/interfaces.ipaddr` lost its write half.** It is `readOnly` in the response schema
  and absent from the request one. It still reads as the first entry of the uci `list ipaddr`;
  send `ipaddrs`.
- **`dhcp/hosts.tag` is array-only in both directions.** The string form existed only because
  the 2.4.1 spec declared one.
- **`managed` left the request half of every resource schema.** It is derived from uci's
  `.anonymous` flag and no write path ever read it.
- **Every resource is described by a separate request schema and response schema**, named
  `<Name>Request` and `<Name>Response`. This is what makes the three above expressible: one
  schema serving both directions could not say that a field is readable but not writable.

See `docs/migration-v2-to-v3.md` for the full upgrade path.
