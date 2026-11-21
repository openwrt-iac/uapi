# uapi deprecations log

Canonical list of wire-surface fields that have been deprecated but are still
accepted during a deprecation window. Each entry lives here from the release
that deprecated it through the release that removes it.

A field is in the table below if and only if it is currently
accepted-but-deprecated. Once removed (in a major release), the entry moves to
the "Removed in past releases" section. Contract changes that are not field
deprecations, and so cannot be expressed as a table row, are announced under
"Announced response-shape changes".

Policy: a deprecation in a minor release means both forms (old and new) are
accepted; the old form is marked `deprecated: true` in `build/openapi.json` so
codegen tools surface a warning; the removal of the old form happens no sooner
than the next major. One exception to the marker, explained under "How to
migrate": a field that is not disappearing but losing only its write half cannot
say so through that flag, because it has no read/write split.

## Active deprecations

| Field | Replaced by | Deprecated since | Removal target | Migration |
|---|---|---|---|---|
| `network/interfaces.ip6prefix` (a string on write) | an array of prefixes | 3.2.0 | v4 | Send an array. A space-separated string is split into words as netifd splits a stored one, so the prefixes it meant do not change. The read is not part of this deprecation but changed in 3.2.0 itself, as a fix: it is always an array, including for a section that stores one prefix as a scalar, which netifd reads the same way. So a client that reads `ip6prefix` has to accept an array from 3.2.0 on. No `deprecated: true` flag, for the reason given under "How to migrate". |

Every entry above must also appear in the published spec's own description,
under
"Upcoming in v4". That is checked by `make lint-doc-refs`.

A field belongs in this section if and only if it is currently
accepted-but-deprecated. Once
removed in a major it moves to `Removed in past releases` below.

## How to migrate

For each deprecated input field your client sends, switch to the replacement
column. uapi accepts both during the window, so the migration can be staged:
update writes first, observe nothing breaks, then drop the old field. Reads do
not change during the window. When the release that opens a window also changes
a read, its row says so.

The OpenAPI spec at `/openapi.json` carries `deprecated: true` on every
deprecated request field that disappears as a whole. Codegen tools that respect
that flag (openapi-generator, oapi-codegen, etc.) will emit warnings in the
generated client when you regenerate; that's the signal your client has surface
area to migrate.

A field that stays and loses only a write form carries no flag, and deliberately
so.
OpenAPI's `deprecated` is a property-level flag with no read/write split, so
setting it
would tell a generator the field was disappearing. `network/interfaces.ipaddr`
was the
first case: it survived as a read field and lost its write half, and the v3 spec
says it
precisely, with `readOnly: true` in the response schema and no `ipaddr` at all
in the
request one. `network/interfaces.ip6prefix` is the current case: it keeps its
array form
and loses only the string form on write. While a window is open, the
announcement lives
in this table and in the field's own `description`, which is the honest signal
available.

## Announced response-shape changes

These land in v4, not before. The list is mirrored in the published spec's own
"Upcoming in v4" block, which `make lint-doc-refs` keeps in sync with this
section by count.

- **`network/routes.table` and `network/rules.lookup` will accept a table name
  on write in v4.** netifd resolves both through `/etc/iproute2/rt_tables` and
  LuCI writes the name, so the request type becomes a union of integer and
  string, which is breaking under `docs/versioning.md`. (#240)
- **Curated string fields will refuse a newline and a carriage return by default
  in v4.** One check in `check_schema_types` replaces the per-field audits, with
  an opt-out annotation for `system.notes`, which holds several lines on
  purpose. (#276)
- **`mwan3/interfaces.family` will read as `ipv4` in v4 when it is unset or
  empty.** mwan3 reads both as ipv4, while a read today gives null for an unset
  family and `""` for an empty one, and a PATCH of null answers 200. The v4
  schema declares `family` as a string that every response holds. The request
  schema does not require it and does not declare null: a PUT that leaves out
  `family` removes the option, and so does a null in a merge patch. The read
  then gives `ipv4`. (#306)
- **A `wireless/interfaces` section with no `mode` will read as null in v4
  instead of `ap`.** wifi-scripts sets up nothing for such a section, so the
  current read reports an access point that does not exist. A write that sends
  no `mode` will store none, where this major stores `ap`, so a client that
  creates an access point must send `mode: "ap"`. (#307)
- **A write will be refused for any stored error the section holds in v4, as
  LuCI does.** Today a write refuses only the errors it adds. A write that only
  disables the section is refused too, so a broken section is fixed or deleted,
  not disabled. This covers the schema checks too: a stored value outside its
  type, enum, bound or pattern, and a newline that the v4 newline rule refuses,
  block every write of the section. The v4 schemas declare what LuCI and the
  daemons take, so a value that the platform takes is no error. (#308)
- **Boolean fields will read each option as the daemon that consumes it reads it
  in v4.** Where netifd reads an option through the uci blob converter, only
  `1`/`true` and `0`/`false` count, and the option is dropped otherwise (libuci
  `66127cd`). Where an init script reads it with libvalidate's `:bool:` or
  `config_get_bool`, the ten spellings count (ubox `6f78fa4`). Three defaults
  change with the reader: an absent `system.log_remote` will read true, as
  `log.init` reads it (`log_remote:bool:1`), an absent `usteer/config.syslog`
  will read false, as usteer starts from a zeroed config, and
  `sqm/queues.enabled` will read true only for a value that sqm-scripts takes as
  1 (`src/run-openwrt.sh:47` at `77cf89e` tests `-eq 1`), so an absent
  `enabled`, or `yes`, `on` or `true`, reads false, as sqm leaves that queue
  off. A client that compares a read of either field across the upgrade sees it
  change, while the router does the same as before. (#310, evidence #312)
- **The special endpoints move under `/uapi/...` in v4.** `/tokens`, `/metrics`,
  `/diagnostics`, `/batch` and `/auth/whoami` become `/uapi/tokens`,
  `/uapi/metrics`, `/uapi/diagnostics`, `/uapi/batch` and `/uapi/whoami`,
  matching the scopes that already exist (`uapi:tokens`, `uapi:metrics`,
  `uapi:diagnostics`). The unauthenticated trio stays at the top level:
  `/healthz`, `/openapi.json`, `/schema/*`. The `path` label of the metrics
  follows the new paths, so a dashboard keyed on the old label must follow too.
  (#319)
- **`dhcp/leases6` merges into `dhcp/leases` in v4.** `GET
  /dhcp/leases?family=v6` returns the v6 entries, and the `/dhcp/leases6`
  endpoint is removed. The `dhcp:leases6` scope goes with it: a token that holds
  only that scope gets 403 on `?family=v6`, so mint one with `dhcp:leases`. A v6
  entry is addressed by its `ip`, as `GET /dhcp/leases/<ip>?family=v6`. 3.x
  ignores `family`, so any value lists the IPv4 entries. v4 refuses a value
  other than `v4` or `v6` with 400 `bad_request`. A token that holds
  `dhcp:leases` will also read the IPv6 leases in v4, with their DUIDs, host
  names and addresses. v4 has no scope for the IPv4 leases alone, so a client
  that must not see the IPv6 leases cannot keep `dhcp:leases`. (#320)
- **`runtime` is always present on every resource in v4, an object that the
  schema requires.** Its fields stay documented on the resources that document
  them today, 4 of 45, and the others keep an opaque object. (#322)
- **Dead error codes leave the ErrorEnvelope enum in v4.**
  `unsupported_media_type` is declared but never returned; the emitted set is
  audited against the declared one. (#323)
- **A query parameter value outside its declared set answers 400 in v4.** 3.x
  ignores such a value. A `managed` other than `true` or `false` on a curated
  list lists every section. A `validate` other than `1` on `/diagnostics` skips
  the sweep. An empty `cursor` reads the first page. v4 answers 400
  `bad_request` for `managed` and `validate`, and 400 `invalid_cursor` for the
  empty cursor. Send only the values that the spec declares, and leave out a
  parameter instead of sending it empty. (#403)
- **Two firewall reads will say what fw4 uses in v4.** A
  `firewall/defaults.synflood_rate` with a unit, such as `25/second`, reads null
  today, where fw4 takes the unit. A `firewall/zones` section without `input`,
  `output` or `forward` reads `REJECT` for it, where fw4 applies the policy of
  `firewall/defaults`. v4 reads what fw4 applies, so such a section reads
  another value and gets another ETag. (#408)
- **A `dhcp/leases` entry without a client id will read `duid` null in v4.**
  dnsmasq writes `*` for a missing client id, as for a missing host name, and
  this major reads it as the string `"*"`. (#392)
- **Two mwan3 values that mwan3 does not run will answer 422 in v4.** A
  `mwan3/globals.loglevel` of `err` or `warn`, which iptables refuses as a log
  level, and a `mwan3/members.metric` above 256, a member that mwan3 leaves out
  of its policy. Send `error` or `warning`, and a metric from 1 to 256. (#407)
- **The HTTP token mint will refuse a scope that the server does not know in
  v4.** It answers 422 `validation_failed` on that entry of `scopes`, as
  `uapi-token create` already refuses it. This major mints such a token, and it
  grants nothing. (#415)
- **`network/rules.ipproto` will take only an integer in the request schema of
  v4.** This major declares an integer or a string, and its server already
  refuses a string unless it is the value that the section holds. v4 declares
  an integer from 1 to 255, as LuCI writes it, so a client generated from the v4
  spec types the field as an integer. A read still gives a stored name or
  spelling, such as `tcp` or `06`, as uci holds it, and a write may send it back
  unchanged. (#405)
- **`dhcp/servers.leasetime` will refuse a year suffix in v4.** dnsmasq does
  not know the `Y` suffix and does not start with such a lease time. This major
  takes it. v4 answers 422 `invalid_format` for a write that sends one, and a
  stored one blocks every write of the section, under the stored-error rule
  above. Send the time in weeks or days. (#405)
- **A `network/bridge_vlans` port name longer than 15 characters will answer
  422 in v4.** No Linux interface has such a name, so the bridge never gets that
  port. This major takes the name. v4 answers 422 `invalid_format` for a write
  that sends one, and a stored one blocks every write of the section. (#405)
- **Some reads will give the value as the daemon parses it in v4.** A firewall
  policy, target, `reflection_src` or `family` reads as fw4 parses it, so a
  lower-case `accept` reads `ACCEPT`, and a nat or redirect target that fw4
  replaces with its default reads as that default. A firewall `src_port`,
  `dest_port` or `proto` stored as one option of several words, as LuCI writes
  it, reads as its words, and so does a `uhttpd/instances.listen_http` or
  `listen_https`. A numeric `network/routes.type` reads as its name, as netifd
  reads it, so `010` reads `prohibit`. Such a section gets another ETag at the
  upgrade, and an `If-Match` from before it answers 412. (#405)

## Removed in past releases

### 3.0.0

| Field | Replaced by | Deprecated since | Removed in |
|---|---|---|---|
| `network/interfaces.name` (request input) | `network/interfaces.id` | 2.2.0 | 3.0.0 |
| `dhcp/hosts.mac` (request and response) | `dhcp/hosts.macs` | 2.5.0 | 3.0.0 |
| `dhcp/hosts.mac_aliases` (request and response) | `dhcp/hosts.macs` | 2.5.0 | 3.0.0 |

Also removed in 3.0.0, announced as response-shape changes rather than as ledger
rows because
neither survived as a read:

- **`vnstat/interfaces`, the whole endpoint.** It modelled `config interface`
  sections, which
  vnstat never reads. Use the `interfaces` array on `vnstat/config`, remembering
  that the values
  differ in kind: the dead endpoint took uci interface names (`lan`), vnstat
  wants device names
  (`br-lan`).
- **The 27 fields that wrote a uci option no OpenWrt component reads**, in
  `mwan3/globals`,
  `vnstat/config`, `lldpd/config`, `unbound/server`, `usteer/config` and
  `prometheus_node_exporter_lua/config`. Writes carrying them were already
  ignored; what changes
  is the read side, since each was returned with a `default:` annotation. The
  per-field reasons
  are in the 2.5.0 announcement, preserved in that release's changelog entry.

- **List-valued fields read back `null`, not `[]`, when the uci key is absent.**
  uci cannot
  store an empty list, so `[]` already meant "absent" and distinguished nothing.
  It also lets a
  list field carry `x-uapi-clear-on-omit`, which the old shape made impossible.
  The request and
  response envelopes keep `[]`, where it means empty rather than absent.

- **`network/interfaces.ipaddr` lost its write half.** It is `readOnly` in the
  response schema
  and absent from the request one. It still reads as the first entry of the uci
  `list ipaddr`;
  send `ipaddrs`.
- **`dhcp/hosts.tag` is array-only in both directions.** The string form existed
  only because
  the 2.4.1 spec declared one.
- **`managed` left the request half of every resource schema.** It is derived
  from uci's
  `.anonymous` flag and no write path ever read it.
- **Every resource is described by a separate request schema and response
  schema**, named
  `<Name>Request` and `<Name>Response`. This is what makes the three above
  expressible: one
  schema serving both directions could not say that a field is readable but not
  writable.

See `docs/migration-v2-to-v3.md` for the full upgrade path.
