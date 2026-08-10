# uapi deprecations log

Canonical list of wire-surface fields that have been deprecated but are still accepted during a deprecation window. Each entry lives here from the release that deprecated it through the release that removes it.

A field is in the table below if and only if it is currently accepted-but-deprecated. Once removed (in a major release), the entry moves to the "Removed in past releases" section. Contract changes that are not field deprecations, and so cannot be expressed as a table row, are announced under "Announced response-shape changes".

Policy: a deprecation in a minor release means both forms (old and new) are accepted; the old form is marked `deprecated: true` in `build/openapi.json` so codegen tools surface a warning; the removal of the old form happens no sooner than the next major. One exception to the marker, explained under "How to migrate": a field that is not disappearing but losing only its write half cannot say so through that flag, because it has no read/write split.

## Active deprecations

| Field | Replaced by | Deprecated since | Removal target | Migration |
|---|---|---|---|---|
| `network/interfaces.ipaddr` (request input) | `network/interfaces.ipaddrs` | 2.5.0 | v3 | Send `ipaddrs` instead. Both name the same uci `list ipaddr`, and the list already wins on write, so the migration is to stop sending the scalar rather than to change any value. `ipaddr` stays in responses after removal, carrying the first entry of the list; only the write is going away. See the note below on why this row carries no `deprecated: true` flag. |

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

- **`dhcp/hosts.tag` no longer accepts a space-separated string on write**, targeted at
  v3. The read half of this has already landed: responses are always an array, including
  for a section storing `option tag 'a b'`, which dnsmasq word-splits identically. What
  remains for v3 is the request side, where a string is still accepted because the 2.4.1
  spec declared one and clients generated against it send one. One schema serves both
  directions here, so the type stays `["string", "array", "null"]` until the major can
  split them.

  This was originally announced the other way round, as a v3 change to the read shape, on
  the reasoning that normalizing storage would rewrite `option tag` into `list tag` the
  first time a client touched a section. The observation was right and the conclusion did
  not follow: splitting a stored scalar on the way *out* settles the read immediately, and
  a read never touches storage. A write still converges it, measured on hardware:

  ```
  storage before PUT: dhcp.tgs.tag='guest iot'
  storage after PUT:  dhcp.tgs.tag='guest' 'iot'
  ```

  That is acceptable precisely because it is invisible on the wire. dnsmasq compiles both
  to `set:guest,set:iot`, and the view round-trips, which is the property that matters.
  Deferring the read shape cost every client a release of handling two shapes to learn one
  thing, and bought nothing.

- **`managed` leaves the request half of every resource schema**, targeted at v3. It is
  derived from uci's `.anonymous` flag and no `toUci` reads it, so a `PUT` sending
  `managed: false` has always answered 200 with `managed: true`; management state moves
  only through `POST /<resource>/{id}/adopt`. 2.5.0 annotates it `readOnly`, which is the
  notice: a regenerated client stops putting it in request models. v3 completes the split.

- **Each resource will be described by a separate request schema and response schema**,
  targeted at v3. One schema serves both directions today, which is why `dhcp/hosts.tag`
  keeps `string` in its type for writers while responses are always an array, why
  `network/interfaces.ipaddr` is described in prose rather than as `readOnly`, and why any
  read/write asymmetry is unstatable. Generated model names change for every resource.
  This is the change the `ipaddr` row above already promises the consequence of.

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

See `docs/migration-v2-to-v3.md` for the full upgrade path.
