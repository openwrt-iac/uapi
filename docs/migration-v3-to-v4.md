# Migration v3 to v4

What changes between the v3 and v4 majors of the API, and what a client must do.
The deprecation window of each change ran from the 3.x release that announced
it, not from v4. Each section names that release, and the `docs/deprecations.md`
of that release holds the announcement. The last section lists the reads that
change at the upgrade, and what that does to ETags and to a plan made on 3.x.

## The mount moves to `/api/v4`

One installation serves exactly one API major. The package upgrade flips the
prefix from `/api/v3` to `/api/v4` and strips every older prefix, and a
generated client takes the new base URL from the v4 spec's `servers` block.

## The special endpoints move under `/uapi/...`

The authenticated special endpoints now live under the domain their scopes
already named (announced in 3.5.0, #319): `/tokens` becomes `/uapi/tokens` (and
`/tokens/<id>` becomes `/uapi/tokens/<id>`), `/metrics` becomes `/uapi/metrics`,
`/diagnostics` becomes `/uapi/diagnostics`, `/batch` becomes `/uapi/batch`, and
`/auth/whoami` becomes `/uapi/whoami`. The scopes are unchanged (`uapi:tokens`,
`uapi:metrics`, `uapi:diagnostics`). The unauthenticated trio stays at the top
level: `/healthz`, `/openapi.json`, `/schema/*`. The old top-level paths answer
404. The Prometheus `path` label of the moved endpoints changes with them (e.g.
`path="/uapi/tokens"`). A 422 from the token mint counts in
`uapi_validate_errors_total` with `resource="uapi.tokens"`, where 3.x used
`resource="tokens"`. The path in the syslog audit and access lines moves too, so
a token mint logs `POST /uapi/tokens`. A dashboard, alert or log filter on an
old path or label stops matching.

## `dhcp/leases6` merges into `dhcp/leases`

The `/dhcp/leases6` endpoint is removed (announced in 3.5.0, #320). `GET
/dhcp/leases` still returns the IPv4 leases, and `GET /dhcp/leases?family=v6`
returns the IPv6 ones from odhcpd's statefile. The entry id is the MAC for v4
entries and the IP for v6 ones, so `GET /dhcp/leases/<ip>?family=v6` looks a v6
entry up. The `Link` to the next page keeps `family`. 3.x ignored `family`, so
any value listed the IPv4 leases. Now a value other than `v4` or `v6` answers
400 `bad_request` (announced in 3.5.0, #391).

An IPv4 entry whose client sent no client id now reads `duid` null (announced
in 3.5.0, #392). dnsmasq writes `*` there, and 3.x read it as the string `"*"`.

The items do not change otherwise, and one schema now describes both families.
A v4 entry has `mac`, and a v6 entry has `iaid`, `interface`, `ia_type` and
`prefix_length` instead. For a client generated from the v3 `dhcp/leases`
schema, `expires_at` can now be `null`: a v6 lease that does not expire reads
`null`, and a v4 one still reads `0`. For a client of the v3 `dhcp/leases6`
schema, `duid` can now be `null`, but a v6 entry always has one, and `ia_type`
no longer lists `IA_TA`, which uapi never returned.

The upgrade keeps each stored token and its scopes. A token that holds
`dhcp:leases` now also reads the IPv6 leases, with their DUIDs, host names and
addresses. 3.x kept those behind `dhcp:leases6`. A token that holds only
`dhcp:leases6` still authenticates, but that scope grants nothing now, so
`?family=v6` answers 403 `insufficient_scope`. `uapi-token create` refuses
`dhcp:leases6` as an unknown path, and `POST /uapi/tokens` answers 422 for it,
as the next section says. A scope on all of `dhcp`, such as `dhcp:ro`, reads
both families before and after the upgrade.

Before the upgrade, run `uapi-token list` to find the tokens that hold either
scope. For a client that reads the IPv6 leases, mint a token on 3.x with both
`dhcp:leases` and `dhcp:leases6`, and revoke the old one. The new token reads
both families before and after the upgrade. v4 has no scope for the IPv4 leases
alone, so a client that must not see the IPv6 leases cannot keep `dhcp:leases`.

## The token mint refuses a scope that the server does not know

`POST /uapi/tokens` now checks each scope as `uapi-token create` does
(announced in 3.5.0, #415). A scope passes when its path is in the scope tree,
is `raw:<package>`, or names all of a uci package that exists in `/etc/config`,
such as `ddns:rw` where ddns is installed. Any other scope answers 422
`validation_failed`, with code `not_in_enum` on its entry of `scopes`, such as
`scopes[1]`:

- a typo, such as `firewall:rulez:rw` or `firewal:rw`,
- a scope that v4 removed, such as `dhcp:leases6:ro`,
- a path below a package outside the tree, such as `ddns:service:rw`,
- a scope on a package that is not installed,
- a malformed scope, such as one without a verb.

No request of v4 checks such a path, so none of these scopes grants access. A
scope on a package that is not installed starts to grant access when the
package is installed, so mint it after the install. 3.x minted each of them,
and answered 500 `internal_error` for a malformed one. The check runs before
the escalation check, so such a scope answers 422 and not 403
`scope_escalation_blocked`. A stored token that holds such a scope keeps it and
still authenticates. `docs/tokens.md` lists the scope tree.

`vnstat:interfaces` left the scope tree in 3.0.0 with the `vnstat/interfaces`
endpoint, but a raw request on a vnstat `interface` section still checked it.
Such a section now needs `vnstat:ro` or `vnstat:rw`, as any section that no
resource models.

## `id` and `runtime` are required in every resource response

The response body does not change: v3 already returned `id` and `runtime` on
every CRUD and singleton resource. The v4 spec now puts both in the `required`
list of each of these response schemas (announced in 3.5.0, #322). The four
resources that document their `runtime` fields keep that shape. The others
declare `runtime` as an object with a common description, and it holds `{}`
when the resource reads no live state. A generated client can now type both
fields as always present. Read-only collections such as `dhcp/leases` have no
envelope and do not change.

## `unsupported_media_type` leaves the error enum

The `ErrorEnvelope.code` enum no longer lists `unsupported_media_type` (415),
which was reserved and never emitted: uapi never rejects a body on
`Content-Type` (announced in 3.5.0, #323). Clients branching on it must drop
that branch.

## A write is refused for any stored error the section holds

Like LuCI, which validates every visible field of a form at save, a write now
answers 422 for any error that the section it leaves holds, not only the ones
that the write adds (announced in 3.4.0, #308). Each check judges that whole
section, for a PATCH of either kind as for a PUT:

- the schema check: a type, an enum, a bound, a pattern, and the newline rule
  of #276 below. The schema declares what LuCI and the daemon take, so a value
  that the platform takes is no error,
- the rules on what a daemon reads, whose errors carry `live` in the sweep,
- the other rules of each resource, also the ones that 3.x applied only to the
  fields that a request named: the `allowed_ips` of a disabled
  `network/wireguard_peers`, and a `network/interfaces.listen_port` that reads
  -1.

Before v4 a write that left a stored value alone answered 200, so a broken
section could still be disabled. Now the fix comes first, or goes through
`/raw`. A DELETE does not validate. `GET /diagnostics?validate=1` runs the same
checks over each stored section and lists each error that it finds, so each
error that it lists now blocks every write of its section. In v4 the same sweep
is `GET /uapi/diagnostics?validate=1`. A PATCH that sends a valid value for each
listed field fixes the section in one write.

A value that LuCI or the daemon takes is no error, so it blocks no write and the
v4 sweep does not list it. Examples are the `proto` of an interface that uapi
does not model, such as the `6in4` that LuCI writes or the `qmi` that an LTE
router ships, a list that uci holds for a `wireless/interfaces` text option, and
the values that the section on schemas below names. Only a write that changes a
field to such a value where the request schema refuses it answers 422. A write
that sends back the value that the section holds passes, so a PUT of a read
takes it, but a client that checks a body against the `*Request` schema before
it sends it must leave such a field out. On 3.x the sweep
is the pre-flight check before the upgrade, with two gaps: it does not list
what a rule new in v4 refuses, such as a newline in a string that 3.x took
(#276), and it lists values that v4 takes.

## `wireless/interfaces` declares the lists that a read gives

`device`, `network`, `ssid`, `nasid`, `mobility_domain` and `r1_key_holder`
read a list that uci holds as an array, which the v3 response schema did not
declare. The response schema now declares a string or an array for each. A
request may send `device` and `network` as a string or a list, since netifd
takes either, and the other four only as a string. A client generated from the
schema must take an array where the field held a string.

## The schemas follow what LuCI and the daemons take

The response schema of many fields is wider than in v3, because a stored value
that LuCI or the daemon takes must not block a write: for example
`network/rules.priority` up to 2147483647, `dhcp/servers.leasetime` with
`infinite` and `deprecated`, `mwan3/rules.proto` as any protocol name, the
bounds of the `mwan3/interfaces` timers, an `unbound/server.ttl_min` above
86400, or a `wireless/interfaces.encryption` of `psk3`, `psk3-mixed` or
`wpa-mixed`, which wifi-scripts sets up as `sae`, `sae-mixed` and WPA and WPA2
with EAP. `build/openapi.json` lists each one. A request can stay narrower,
through the `*Request` schema, and the server now checks it against the fields
that a request names, other than a value that the section holds. A
`dhcp/servers.leasetime` with a year suffix, which stops dnsmasq, is refused on
write, and so are a `mwan3/rules.proto` that iptables refuses, a
`uhttpd/certs.days` of 0 and a `network/bridge_vlans` port name longer than 15
characters, which no Linux interface has. The request schema of
`network/rules.ipproto` takes only an integer from 1 to 255, as LuCI writes
it, where 3.x declared an integer or a string: a read still gives a stored
name such as `tcp`, and a write may send it back unchanged.

The rules on what netifd and wifi-scripts read judge only what they refuse or
read as another value. A `network/rules` form that netifd installs as it reads,
such as an `ipproto` of `tcp` or `06`, a `uidrange` of `1000-1005x` or a
`suppress_prefixlength` above 32, and a `wireless/devices.txpower` above 30, a
`channel` above 233 or a `radio` below 0, with which the radio comes up, block
no write. Nor does a `wireless/interfaces.mode` of `wds`, which blocked enabling
the SSID or its radio in 3.x: mac80211.sh skips it as it skips `ahdemo` and a
section without a mode, and a write that sends it is still refused. An `ipproto`
above 255, or a port or uid that netifd wraps, is an error: the kernel gets
another value. A `mwan3/globals.mmx_mask` that is not a 32-bit number in hex,
decimal or octal, such as `08`, blocks every write, since mwan3, iptables and
`ip` cannot use it. A write that changes the encryption of an SSID to an EAP
mode needs a key, and one that sends back the stored mode does not.

Some reads now give the value as the daemon parses it: a firewall policy,
target, `reflection_src` or family as fw4 reads it, an option of several words
as its words, and a numeric route type as its name. The table in "Reads that
change at the upgrade" lists them.

## Boolean reads follow the reader of their daemon

The readers whose daemon goes through libvalidate's `:bool:` or
`config_get_bool` now read the ten spellings of that reader (announced in
3.4.0, #310): `system.log_remote`, `system/timeservers` (`enabled`,
`enable_server`, `use_dhcp`), the `usteer/config` booleans (`syslog`, `ipv6`,
`assoc_steering`) and the `dropbear/instances` flags (`password_auth`,
`root_password_auth`, `root_login`, `gateway_ports`). `enabled` now reads
`true` and `disabled` reads `false` there, where v3 answered the default.
fw4's `parse_bool` keeps its eight spellings. Evidence: ubox `6f78fa4`, pinned
in `docs/ucode-quirks.md` (#312).

Two defaults follow the daemon too. The 3.4.0 announcement named only the
spellings, and 3.5.0 announced these defaults (#369). An absent `log_remote`
reads `true`, as log.init takes it (`log_remote:bool:1`). A stock
`/etc/config/system` holds no `log_remote`, so this read changes on a stock
router. An absent usteer `syslog` reads `false`, as usteer's `set_config` resets
it.

Where one of these reads changed, a plan that holds the 3.x read now writes it,
and the daemon then does what that read said. With `log_ip` set and no
`log_remote`, log.init sends the log to `log_ip`, so a plan that holds
`log_remote = false` stops it. A dropbear flag stored as `disabled` read `true`
in 3.x, so a plan that holds `true` turns password or root login back on.

`sqm/queues.enabled` reads `true` only for a value that sqm-scripts takes as on:
its `run-openwrt.sh` starts a queue only when `[ "$(config_get "$section"
enabled)" -eq 1 ]` holds. An absent `enabled`, or `yes`, `on` or `true` written
by hand, read `true` in v3 for a queue that sqm left off, and now reads `false`
(announced in 3.5.0, #372). A queue that LuCI made holds `1` or `0` and reads
the same. A plan that sets `enabled = true` on such a queue now writes `1`,
which starts SQM there. A value such as `01`, `+1` or ` 1` reads `true`, because
the shell test takes it as 1.

## A `wireless/interfaces` section with no `mode` reads `null`

wifi-scripts sets up nothing for a section without a `mode` (mac80211.sh skips
an absent mode as it skips an unknown one), so the read now answers `null`
instead of `"ap"` (announced in 3.4.0, #307). The write side changes the same
way (announced in 3.5.0, #376): a `null` mode is accepted and removes the
option, leaving a section that sets up nothing. A create or PUT that sends no
mode stores none, so a client that creates an access point must send
`mode: "ap"`.

A plan that holds `mode = "ap"` from a 3.x read of such a section now writes
`ap`, and wifi-scripts then sets up an access point that did not run before.
With no `encryption` stored, that access point is open. Before you apply, set
`mode` to `null` to keep the SSID down, or set its `encryption` and `key`.

A section without a mode no longer blocks a write that turns its radio on, and
the validation sweep marks its errors `live: false`. A write to it is still
checked as mode `ap`.

## `mwan3/interfaces.family` reads `ipv4` when unset

`mwan3.sh` and `mwan3track` both default an unset `family` to `ipv4`, so the
read now answers `"ipv4"` instead of `null` for a section that stores none
(announced in 3.4.0, #306). `family` is no longer in the request schema's
`required`: a write may omit it, and a `null` removes the option, after which
the read answers `ipv4` again. A plan that holds `null` there sees `ipv4` at
each read, so make it hold `ipv4`. mwan3 does the same either way. An empty
`family` reads `ipv4` too, and a list reads as the string that `config_get`
makes of it. The response declares `family` as a string that every read holds,
and the request no longer declares null: to remove the option, leave `family`
out of a PUT or send null in a merge patch.

## Curated string fields refuse newlines and carriage returns

One check in the type gate now refuses `\n` and `\r` in every curated string on
write (announced in 3.4.0, #276), so the refusal no longer depends on the
per-field `LINE_RE`/`ONE_LINE_RE` patterns, which had disagreed about `\r`. The
only opt-out is `system.notes`, marked `x-uapi-multiline`, which holds several
lines on purpose. Free-text fields such as descriptions that no daemon reads as
one line are refused too. That is the announced breaking part. A stored one
blocks every write of its section, as the #308 section above says. Per-field
`pattern`s keep their word, quote and glob rules.

## `network/routes.table` and `network/rules.lookup` accept a table name on write

The request type of both fields is now a union of integer and string (announced
in 3.4.0, #240). A name is resolved exactly as netifd resolves it (number, then
`default`/`main`/`local`, then `/etc/iproute2/rt_tables`) and stored as its id.
A name that does not resolve answers 422 `invalid_format`, and an id of 0
answers 422 `out_of_range`. The read still answers the id, so a plan stays
stable when `rt_tables` changes, and a name stored by hand or by LuCI still
reads as its id.

## `network/interfaces.ip6prefix` is array-only on write

A space-separated string on write is refused with 422 `invalid_type` (announced
since 3.2.0, removed in v4, #241). Send an array, which is also what the read
has returned since 3.2.0. A one-element array is still stored as a scalar, which
netifd, 6rd, map and 464xlat read the same way, so the stored form does not
change.

## Reads that change at the upgrade

The upgrade keeps `/etc/config`, the token store and every id as they are. Of
the stored scopes, only `dhcp:leases`, `dhcp:leases6` and `vnstat:interfaces`
change what they grant, as the `dhcp/leases` and token mint sections say. Some
reads now answer another value for the same stored option, to follow what the
daemon does:

| Resource | Field | The read changes when the option is |
|---|---|---|
| `system` | `log_remote` | absent, `enabled` or an unknown word |
| `system/timeservers` | `enabled`, `use_dhcp` | `disabled` |
| `system/timeservers` | `enable_server` | `enabled` |
| `usteer/config` | `syslog` | absent, `disabled` or an unknown word |
| `usteer/config` | `ipv6`, `assoc_steering` | `enabled` |
| `dropbear/instances` | `password_auth`, `root_password_auth`, `root_login` | `disabled` |
| `dropbear/instances` | `gateway_ports` | `enabled` |
| `sqm/queues` | `enabled` | absent, or not `1`, `0`, `off`, `false` or `no` |
| `wireless/interfaces` | `mode` | absent |
| `mwan3/interfaces` | `family` | absent |
| `firewall/defaults`, `firewall/zones` | `input`, `output_policy`, `forward` | a policy in another case or a prefix of one, such as `accept` |
| `firewall/rules`, `firewall/nat`, `firewall/redirects` | `target` | a target in another case or a prefix of one, or for nat and redirects a target that fw4 replaces with its default |
| `firewall/redirects` | `reflection_src` | a choice in another case or a prefix of one |
| `firewall/zones`, `firewall/forwardings` | `family` | `all`, `*`, `inet`, or a word with 4 or 6 |
| `firewall/rules`, `firewall/nat`, `firewall/redirects` | `match.family` | `all`, `*`, `inet`, or a word with 4 or 6 |
| `firewall/rules` | `match.src_port`, `match.dest_port` | one option of several words, as LuCI writes it |
| `firewall/rules`, `firewall/nat`, `firewall/redirects` | `match.proto` | one option of several words |
| `uhttpd/instances` | `listen_http`, `listen_https` | an option or an entry of several words |
| `network/routes` | `type` | a number from 1 to 9, in decimal, hex or octal as strtoul reads it, such as `6` or `010` |

A section whose read changes gets a new ETag once, at the upgrade. A write that
sends an `If-Match` from before the upgrade answers 412 `precondition_failed`.
Read the section again and send its new ETag.

A plan that sets one of these fields to its 3.x read shows a diff after the
upgrade. Its apply writes that value, and the daemon then does what the 3.x read
said, which it did not do before. Refresh the state and check each such diff
before you apply. The sections above name the cases that matter most.

The spec `default` of five fields changes with the read: `system.log_remote` is
`true`, `usteer/config.syslog` and `sqm/queues.enabled` are `false`,
`mwan3/interfaces.family` is `ipv4`, and `wireless/interfaces.mode` has none. A
client that sends the spec default for a field that its user left out now sends
the new one.

## A query parameter value outside its declared set answers 400

3.x ignored a value that a query parameter does not declare. A `managed` other
than `true` or `false` on a curated list listed every section, a `validate`
other than `1` on `/uapi/diagnostics` skipped the sweep, and an empty `cursor`
read the first page. v4 answers 400 `bad_request` for `managed` and `validate`,
and 400 `invalid_cursor` for the empty cursor. Send only the values that the
spec declares, and leave out a parameter instead of sending it empty.
