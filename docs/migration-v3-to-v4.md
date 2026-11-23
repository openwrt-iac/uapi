# Migration v3 to v4

What changes between the v3 and v4 majors of the API, and what a client must do.
The removals and renames were announced in 3.x, apart from `openvpn/instances`,
whose section says why. The other changes are listed here, and a section names
the 3.x release that announced its change when one did. The section "Reads
that change at the upgrade" lists those reads, and what that does to ETags and
to a plan made on 3.x.

## 4.x needs OpenWrt main or the next release

4.x runs on OpenWrt main and on the next OpenWrt release cut from it. It needs
a netifd that carries `e97e36f` (2026-07-16), which takes `disabled 'true'` on
an interface. OpenWrt 25.12 does not carry it, and 4.x does not support 25.12.
The 4.x package depends on a netifd that 25.12 does not have, so apk does not
install 4.x on a 25.12 router, and such a router stays on 3.5.0. To move to
4.x, move the router to OpenWrt main or to that release first, then install
4.x.

Some sections below say what uapi does on 25.12, where netifd sets up a
wireguard interface with `wireguard.sh`. They compare with 3.x on 25.12, or
describe code that 4.x still holds. They do not mean that 4.x supports 25.12.

## The mount moves to `/api/v4`

One installation serves exactly one API major. The package upgrade flips the
prefix from `/api/v3` to `/api/v4` and strips every older prefix, and a
generated client takes the new base URL from the v4 spec's `servers` block.
Change the base URL of every other client, a Prometheus `metrics_path` and
each curl script. uapi no longer answers at `/api/v3` after the upgrade.

The upgrade writes this change to `ucode_prefix` of `uhttpd.main`. So `GET
/uhttpd/instances/main` reads `/api/v4=/usr/share/uapi/main.uc`, and the section
gets a new ETag. A plan that sets the 3.x entry shows a diff. A write to `main`
that keeps the 3.x entry and not the v4 one answers 422 `conflict` on
`ucode_prefix`, because it removes the mount of uapi. Tokens, their scopes and
every id stay as they are.

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
`dhcp:leases` or `*:leases`, with either verb, now also reads the IPv6 leases,
with their DUIDs, host names and addresses. 3.x kept those behind
`dhcp:leases6` or `*:leases6`. A token that holds only `dhcp:leases6` or
`*:leases6` still authenticates, but that scope grants nothing on
`/dhcp/leases` now, so `?family=v6` answers 403 `insufficient_scope`.
`uapi-token create` refuses `dhcp:leases6` as an unknown path, and `POST
/uapi/tokens` answers 422 for it, as the next section says, but both still mint
`*:leases6`. A scope on all of `dhcp`, such as `dhcp:ro`, reads both families
before and after the upgrade.

Before the upgrade, run `uapi-token list` to find the tokens that hold one of
these four scopes, `dhcp:leases`, `dhcp:leases6`, `*:leases` or `*:leases6`,
with either verb. For a client that reads the IPv6 leases, mint a token on 3.x
with both `dhcp:leases` and `dhcp:leases6`, and revoke the old one. The new
token reads both families before and after the upgrade. v4 has no scope for the
IPv4 leases alone, so a client that must not see the IPv6 leases cannot keep
`dhcp:leases` or `*:leases`.

## openvpn becomes a proto of `network/interfaces`

`openvpn/instances` is removed (#466). On OpenWrt main, the platform of 4.x,
the openvpn package runs a tunnel as a netifd protocol. A tunnel is a `config
interface` section with `option proto 'openvpn'` in `/etc/config/network`,
which `/lib/netifd/proto/openvpn.sh` runs. The package has no init script and
no `/etc/config/openvpn` there, so `openvpn/instances` read sections that
nothing runs, and each write answered 503 `init_script_missing`. LuCI made the
same move: luci-proto-openvpn shows a tunnel under Network, Interfaces. No 3.x
release announced this removal. v3 takes no more releases, and the path cannot
work on the platform of 4.x.

A tunnel is now a `network/interfaces` resource with `proto: "openvpn"`. It
needs the `openvpn-openssl` package, or its `openvpn-mbedtls` or
`openvpn-wolfssl` variant. netifd loads its proto handlers when it starts. After
an `apk add` of the package on a running router, netifd does not know proto
openvpn: `ubus call network get_proto_handlers` does not list it, `ifstatus`
says `NO_DEVICE`, and uapi reads `runtime.effective_proto: "none"`. A reboot or
`/etc/init.d/network restart` loads the handler.

### What an upgraded router holds

At the first boot on OpenWrt main, the uci-defaults script
`60_openvpn_migrate.sh` of the openvpn package copies each `config openvpn`
section of `/etc/config/openvpn` into `/etc/config/network`, once. Each copy is
a `config interface` of the same name with `option proto 'openvpn'`. The script
renames the option `proto` to `ovpnproto`, copies every other option as it is,
and skips a section whose name `/etc/config/network` already holds. It leaves
`/etc/config/openvpn` in place, and nothing reads that file after the upgrade.

So each 3.x instance reads as `GET /network/interfaces/<id>` under the same id,
with a new ETag. Do not create the tunnels again: a POST with an id that
`/etc/config/network` holds answers 422 `conflict`. A client that managed an
instance takes over the interface of the same id, by an import for Terraform. A
router that had no `/etc/config/openvpn` gets no copy.

**Warning: an instance that was off on 3.x runs after the upgrade.** The
openvpn init script of 25.12 runs a section only when its `enable` or `enabled`
option reads true. Every other section is off, a section with neither option
too. netifd and the openvpn handler read neither option, and the copy adds no
`disabled`. So at the first boot on OpenWrt main, netifd starts every copied
tunnel, and uapi reads it with `disabled: false`, `auto: true` and a `runtime`
that is up. Before the upgrade, add `option disabled '1'` to each instance that
is off in `/etc/config/openvpn`: the copy carries it, and the init script of
25.12 does not read it. Or right after the upgrade, send `{"disabled": true}`
to `network/interfaces` for each such tunnel.

**Warning: an openvpn client can take the default route.** On OpenWrt main,
openvpn-hotplug adds a default route through the tunnel each time openvpn knows
a route gateway, also without `redirect-gateway`, and a server with `topology
subnet` always pushes one. With `defaultroute` unset, which means true, netifd
then replaces the default route of wan in the main table. When the tunnel goes
down, netifd removes its route, and the main table has no IPv4 default route
until wan restarts. A copied 3.x client gets `defaultroute` unset. Before the
upgrade, add `option defaultroute '0'` to each client in `/etc/config/openvpn`
that must not carry the default route, or right after the upgrade, send
`{"defaultroute": false}` for it. The pushed routes of the server still apply.

### Field map

Each field of `openvpn/instances` that is not in this table keeps its name, its
type and its meaning on `network/interfaces`, and applies to proto openvpn
only.

| 3.x `openvpn/instances` | 4.x `network/interfaces` |
|---|---|
| `proto` | `ovpnproto`, the uci option that the copy renames it to |
| `enabled` | `disabled`, inverted, and `auto`. The copy keeps `enabled` in uci, which nothing reads. A PATCH keeps it, and a PUT removes it |
| `status` | gone: the handler gives openvpn `--status /var/run/openvpn.<id>.status` itself |
| `comp_lzo`, `compress` | gone: the handler passes them only with `allow_deprecated '1'`, which uapi does not model |
| `ncp_ciphers`, `ncp_disable` | gone: the handler does not read them. Send the ciphers in `data_ciphers` |
| (none) | `config`, `data_ciphers`, `username`, and the write-only `password` and `cert_password` with `has_password` and `has_cert_password` |

`key`, `tls_auth` and `pkcs12` stay write-only, with `has_key`, `has_tls_auth`
and `has_pkcs12`. `data_ciphers` takes one entry, the cipher names joined by
colons: the handler gives openvpn each entry as a `--data-ciphers` of its own,
and openvpn keeps only the last. Several entries answer 422 `conflict`, on a
write and while uci holds them. `peerdns` and `nohostroute` of the interface
apply to openvpn too, and so do the options that netifd reads for every proto,
such as `metric` and `defaultroute`.

Some reads of the same option differ from 3.x, because netifd hands each option
to the handler through uci's converter. A boolean reads true for `1` or `true`
only, where 3.x also took `yes`, `on` and `enabled`. An integer such as `port`
also reads in hex or octal, so `010` is 8. An option of `remote`, `push`,
`route` or `data_ciphers` that is not a uci list reads as its words, each a
flag of its own for openvpn. `local` also takes a host name, as LuCI's form
does. The booleans carry no `default` in the spec, because they apply to one
proto only, as `nohostroute` of a wireguard interface. A PUT removes each
option that uapi does not model, such as `mode` or `script_security`, and a
PATCH keeps it.

### Tokens and scopes

The upgrade keeps each stored token and its scopes, and such a token still
authenticates. `/openvpn/instances` answers 404 `not_found` for every token. A
scope `openvpn`, `openvpn:instances` or `*:instances` grants nothing on the
tunnels: they need `network:interfaces` or `network`, which also cover every
other interface, the management one included. With `raw:openvpn`, a scope on
`openvpn` still grants `/raw/openvpn` on the sections that stay in
`/etc/config/openvpn`.

`uapi-token create` refuses `openvpn:instances` as an unknown path, and `POST
/uapi/tokens` answers 422 for it. Both take `openvpn` only while
`/etc/config/openvpn` exists, as a scope on a package outside the tree, and
`*:instances`, which now covers `dropbear/instances` and `uhttpd/instances`.
Mint a token with `network:interfaces` for a client that manages tunnels, and
revoke its old one.

## The token mint refuses a scope that the server does not know

`POST /uapi/tokens` now checks each scope as `uapi-token create` does
(announced in 3.5.0, #415). A scope passes when its path is in the scope tree,
is `raw:<package>` or `*:<package>`, or names all of a uci package that exists
in `/etc/config`, such as `ddns:rw` where ddns is installed. Any other scope
answers 422 `validation_failed`, with code `not_in_enum` on its entry of
`scopes`, such as `scopes[1]`:

- a typo, such as `firewall:rulez:rw` or `firewal:rw`,
- a scope that v4 removed, such as `dhcp:leases6:ro` or `openvpn:instances:rw`,
  but not `*:leases6:ro`, which passes as `*:<package>` and grants nothing on
  `/dhcp/leases`,
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

## `runtime` is required in every resource response

Every resource now answers `runtime`, an object that its response schema
requires (announced in 3.5.0, #322). The four resources that document their
`runtime` fields keep that shape: `network/interfaces`,
`network/wireguard_peers`, `wireless/interfaces` and `dhcp/servers`. The others
declare `runtime` as an object with a common description, and it holds `{}`
when the resource reads no live state. The schemas of the 42 curated CRUD and
singleton resources also require `id`. A generated client can now type both
fields as always present.

The body of the curated resources and of `system/cron_jobs` does not change,
because v3 already returned `runtime` there. These responses change:

- Each key of `system/authorized_keys` now holds `runtime: {}`, in the response
  of every GET, POST and PUT.
- Each item of the read-only collections `dhcp/leases` and
  `network/wireguard_kernel_peers` now holds `runtime: {}`. The item is itself
  the live state, so its `runtime` stays empty.
- `packages/installed` and `packages/feeds` already returned `runtime: {}`, and
  their schemas now require it.

A client that refuses an unknown key sees a new one in the first two. `/raw`
answers the uci section and no `runtime`, and the special endpoints under
`/uapi/` are not resources.

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
  fields that a request named, or only in the sweep: the `allowed_ips` of a
  disabled `network/wireguard_peers`, a `network/interfaces.listen_port` that
  reads -1, and the one-value rule of `network/interfaces`. On a proto whose
  handler reads `ipaddr`, `ip6addr` or `ip6prefix` as one value, such as 6in4,
  that rule refuses several values of `ipaddrs`, `ip6addrs` or `ip6prefix`, or
  one value that uci holds as a list. A PATCH that sends one value for the
  field stores it as an option and fixes the section.

Before v4 a write that left a stored value alone answered 200, so a broken
section could still be disabled. Now the fix comes first, or goes through
`/raw`. A DELETE does not validate. `GET /uapi/diagnostics?validate=1`, which
3.x serves at `GET /diagnostics?validate=1`, runs the same checks over each
stored section and lists each error that it finds, so each error that it lists
now blocks every write of its section. A PATCH that sends a valid value for
each listed field fixes the section in one write.

A value that the read cannot show is judged too. fw4 stops while it reads a
`firewall/defaults` section with an option that its parser refuses, such as a
`synflood_rate` of `abc`, a `drop_invalid` of `YES` or a list, and applies no
ruleset. A `synflood_burst` that is a number but no integer, such as `16.5`,
is an error too: nft refuses it, so fw4 applies no ruleset while `syn_flood` is
on. Such an option reads `null`, and the sweep names the option and says why.
A write that sends the field replaces the value, and a null removes it.

fw4 skips a `firewall/zones`, `firewall/forwardings`, `firewall/rules`,
`firewall/redirects` or `firewall/nat` section with a bool that its parser
refuses, such as an `enabled` of `YES` or a list. Such a bool reads `null` too,
and the sweep names it. A PATCH that sends the field replaces the value, and a
PUT that leaves the field out removes it.

A value that LuCI or the daemon takes is no error, so it blocks no write and the
v4 sweep does not list it. Examples are the `proto` of an interface that uapi
does not model, such as the `6in4` that LuCI writes or the `qmi` that an LTE
router ships, a list that uci holds for a `wireless/interfaces` text option, and
the values that the section on schemas below names. Only a write that changes a
field to such a value where the request schema refuses it answers 422. A write
that sends back the value that the section holds passes, so a PUT of a read
takes it, but a client that checks a body against the `*Request` schema before
it sends it must leave such a field out. Two exceptions remain. A request that
names a proto that uapi does not model answers 422 `not_in_enum`, also when it
sends the stored proto, because a PUT would delete the options that the handler
of that proto reads. So a PUT of the read of such an interface fails, and only a
PATCH that leaves `proto` out can change it and keep its proto. As in 3.5.0, a
PUT of the `HELPER` target that LuCI writes on a firewall rule answers 422 too,
because uapi does not model its `set_helper` option, and a PUT removes it. On
3.x the sweep is the pre-flight check before the upgrade, with two gaps: it does
not list what a rule new in v4 refuses, such as a newline in a string that 3.x
took (#276), and it lists values that v4 takes.

## `wireless/interfaces` gives one type for each list option

`device` and `network` read as an array, or null when unset. netifd sets the
SSID up on each radio, and attaches it to each network, that the option names
as a list or as words split at any whitespace, and the read gives those words.
So a stored `radio0` reads `["radio0"]`, where 3.x read `"radio0"`. A request
may still send a string or a list. A write stores one radio or one network as a
string, as LuCI and `wifi config` write it, so a PUT of the read keeps such an
option as it is.

`ssid`, `nasid`, `mobility_domain` and `r1_key_holder` read as a string, or
null when unset, as the 3.x response schema declared. For a list that uci holds,
3.x read an array that its schema did not declare. v4 reads the text that
wifi-scripts gives the daemon: the JSON text of the list for `ssid`, such as
`[ "home", "net" ]`, which hostapd broadcasts, and the entries joined by spaces
for the other three. A request sends only a string, and a PUT of the read stores
that text as one option. With 802.11r and without both key holder lists,
wifi-scripts derives their key from the JSON text of a `mobility_domain` list,
so such a PUT gives the access point another key. Store `mobility_domain` in the
same form on each access point of the domain.

A client generated from the v3 schema must take an array for `device` and
`network`.

## The schemas follow what LuCI and the daemons take

A stored value that LuCI or the daemon takes must not block a write, so the
response schema of each field declares what the platform takes. 3.5.0 already
widened most of these schemas (#410), for example `network/rules.priority` up
to 2147483647, `dhcp/servers.leasetime` with `infinite` and `deprecated`,
`mwan3/rules.proto` as any protocol name, the bounds of the `mwan3/interfaces`
timers, an `unbound/server.ttl_min` above 86400, and a
`wireless/interfaces.encryption` of `psk3`, `psk3-mixed` or `wpa-mixed`. Over
3.5.0, v4 widens the response schema of the `dhcp/leases` items and of
`wireless/interfaces.mode`, which can read null, and declares an array for
`wireless/interfaces.device` and `network`. Their sections say more, and
`build/openapi.json` lists each field. A
request can stay narrower, through the `*Request` schema. As in 3.5.0, the
server checks it against the fields that a request names, other than a value
that the section holds. In v4, a `dhcp/servers.leasetime` with a year suffix,
which stops dnsmasq, is refused on write, and so is a `network/bridge_vlans`
port name longer than 15 characters, which no Linux interface has. The request
schema of `network/rules.ipproto` takes only an integer from 1 to 255, as LuCI
writes it, where 3.x declared an integer or a string: a read still gives a
stored name such as `tcp`, and a write may send it back unchanged.

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

v4 adds three more refusals. A `mwan3/rules` section with
`src_port` or `dest_port` and a `proto` of `tcp` or `udp` in another case, such
as `TCP`, answers 422 `conflict` on `proto`, because mwan3 then drops the ports
and the rule matches every port. A `firewall/zones.name` that starts with a
digit or a dash, such as `1wan`, answers 422 `invalid_format`, because fw4 skips
such a zone. A stored one of these two blocks every write of its section. A
`mwan3/rules.proto` of `dccp` or `ipcomp` answers 422 `invalid_format`, because
iptables 1.8.10 and musl do not know them, and mwan3 then loads none of the
rules of the family. A stored one reads as it is. 3.x took all three. A
`mwan3/rules.proto` name in any case, `mobility-header` and an octal number
with more leading zeros, such as `000017`, pass as in 3.x.

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

For Terraform, a plan refreshes first, so a `mode` that the configuration does
not set reads null, and the apply writes nothing for it. Only a configuration
that sets `mode = "ap"` writes it. Remove `mode` from such a configuration to
keep the SSID down.

A section without a mode no longer blocks a write that turns its radio on, and
the validation sweep marks its errors `live: false`. A write to it is still
checked as mode `ap`.

## `mwan3/interfaces.family` reads `ipv4` when unset

`mwan3.sh` and `mwan3track` both default an unset `family` to `ipv4`, so the
read now answers `"ipv4"` instead of `null` for a section that stores none
(announced in 3.4.0, #306). An empty `family` reads `ipv4` too, and a list
reads as the string that `config_get` makes of it. The response declares
`family` as a string that every read holds. A plan that holds `null` there sees
`ipv4` at each read, so make it hold `ipv4`. mwan3 does the same either way.

`family` is no longer in the `required` list of the request schema, and that
schema no longer declares null. Only the merge-patch body declares null. To
remove the option, leave `family` out of a POST or a PUT, or send null in a
merge patch. The server also takes a null in a POST or a PUT, the same as a
field that the request leaves out. After the option is removed, the read
answers `ipv4` again.

## Two mwan3 values that mwan3 does not run answer 422

mwan3 passes `mwan3/globals.loglevel` to iptables as the level of its LOG
rules, and iptables refuses `err` and `warn`. mwan3 then loads none of its rules
once one of them logs. mwan3 also leaves a `mwan3/members` section with a
`metric` above 256 out of its policy. A write of such a value now answers 422,
`not_in_enum` for the log level and `out_of_range` for the metric (announced in
3.5.0, #407). Send `error` or `warning`, and a metric from 1 to 256, as LuCI
does. A stored one blocks every write of its section until a write replaces
it, and the read still gives it. `GET /uapi/diagnostics?validate=1` lists it,
and marks the log level `live` only while `logging` is on. The same holds for
any other level that iptables refuses, such as `8` or `3 x`. A stored level that
iptables takes is no error, such as `panic`, or a number from 0 to 7 in the
base that strtoul reads, such as `3` or `0x3`. The read gives it and a write can
send it back, but a write that sends it anew answers 422, since a request takes
the names that LuCI offers. The response schema of `loglevel` declares a string
with no enum.

## Two firewall reads say what fw4 applies

fw4 gives a `firewall/zones` section without `input`, `output_policy` or
`forward` the policy of `firewall/defaults`, and DROP when that section has
none. 3.x read `REJECT` for it. v4 reads `null` (announced in 3.5.0, #408), and
the schemas declare null and no `default` for the three fields.
`firewall/defaults` gives the policy that fw4 applies. A write of the read, or a
null, stores no policy, so the zone keeps the policy of `firewall/defaults`. A
plan that holds `REJECT` from a 3.x read now writes it, and the zone then
rejects where it took the policy of `firewall/defaults` before. Set the field to
null in the plan to keep that policy. This differs from the 3.5.0 notice, which
said that v4 reads what fw4 applies: fw4 applies the policy that
`firewall/defaults` holds, so the zone reads null, and `firewall/defaults` reads
the policy.

The three fields carry `x-uapi-clear-on-omit`. A PUT that leaves one out removes
the option, as in 3.x, and the zone takes the policy of `firewall/defaults`
again. A PATCH that leaves one out keeps it.

For Terraform, a plan refreshes first, so a policy that the zone does not set
reads null, and the apply writes nothing for it. Only a policy that the
configuration sets writes its value, so a Terraform user edits nothing for this
change of the read. To put a zone back on the policy of `firewall/defaults`,
remove the attribute from the configuration. A provider that reads the flag
also removes a policy that the zone stores and the configuration does not set,
so set each policy that the zone must keep.

fw4 takes a `firewall/defaults.synflood_rate` with a unit, such as
`25/minute`, or a prefix of the unit, such as `25/m`. 3.x read null for it. v4
reads the rate as fw4 applies it, always with the whole unit, so `25/m` reads
`25/minute` (announced in 3.5.0, #408).

A stored rate without a unit, such as `25`, read as the integer 25 in 3.x. v4
reads it as the string `25/second`, and the response declares a string. Every
rate reads as a string so that a Terraform client can type the field, because
Terraform has no type that is an integer or a string. A client generated from
the schema must take a string there.

A write takes a string with a rate of 1 or more and the whole unit, `second`,
`minute`, `hour` or `day`, such as `25/minute`. It refuses a prefix of the unit,
such as `25/m`, and the string `"25"`, with 422 `invalid_format`. A write also
takes an integer of 1 or more, which is a rate per second.

The kernel refuses a limit whose rate plus burst overflows 64 bits, such as a
rate of `18446744073709551615`. It also refuses a slow rate with a large burst,
such as `1/minute` with a burst of 4294967295, when the nanoseconds per packet
times the burst overflow 64 bits. fw4 then applies no ruleset while `syn_flood`
is on. v4 refuses such a write with 422 `out_of_range` on `synflood_rate`. A
stored one is an error of the section that blocks every write that does not
fix it, and the sweep marks it live while `syn_flood` is on. 3.x took such a
write.

A `firewall/defaults.synflood_burst` reads as fw4 parses it, so `0x10` reads 16
and `1e3` reads 1000, where 3.x read null.

LuCI's zones form writes `synflood_protect` and removes `syn_flood`. fw4 applies
`synflood_protect`, and reads `syn_flood` only when uci holds no
`synflood_protect`. 3.x read only `syn_flood`, so after LuCI turned the
protection on, `firewall/defaults.syn_flood` read `false` while fw4 protected.
v4 reads the value that fw4 applies. A plan that holds `false` from a 3.x read
of such a section shows a diff, and its apply turns the protection off. Set it
to `true` in the plan to keep the protection.

A write of true now stores `synflood_protect '1'` and removes `syn_flood`, as
LuCI does. A write of false removes `synflood_protect` and stores `syn_flood
'0'`, where LuCI removes both. A null removes both. In 3.x, a write over a
stored `synflood_protect` changed only `syn_flood`, so it answered 200 and fw4
kept the value of `synflood_protect`. A `synflood_protect` that fw4 refuses,
such as `maybe` or a list, is an error of `syn_flood` that blocks every write
of the section that does not replace it.

fw4's parser refuses a bool of `firewall/defaults` that holds a list or a
value other than `1`, `on`, `true`, `yes`, `0`, `off`, `false` or `no`, such
as a `drop_invalid` of `YES`. fw4 then applies no ruleset, and the value is an
error of the section that blocks every write that does not replace it. 3.x
read such a bool as `false`. v4 reads `null`, and the schemas of `syn_flood`,
`drop_invalid`, `tcp_syncookies`, `flow_offloading` and `flow_offloading_hw`
admit null. So a plan that holds `true` or `false` shows a diff, and its apply
sends the field and fixes the section. With a read of `false`, a plan that
holds `false` would never send the field, and each other write would answer
422. fw4 parses both `synflood_protect` and `syn_flood`, so `syn_flood` reads
`null` when either holds such a value, and a write of `syn_flood` then replaces
both. An unset bool reads `false`, as in 3.x.

fw4 refuses the same values in a bool of a zone, a forwarding, a rule, a
redirect or a nat rule, and skips that section with the warning "skipped due
to invalid options". 3.x read such a bool as its default, so a rule with
`enabled 'YES'` read `true` while fw4 skipped it, and the 3.x sweep did not
list it. v4 reads `null` for `masq` and `mtu_fix` of `firewall/zones`, for
`enabled` of `firewall/forwardings`, `firewall/rules`, `firewall/redirects` and
`firewall/nat`, and for `reflection` of `firewall/redirects`, and their schemas
admit null. The value is an error of the section, so the sweep lists it and a
PATCH that does not send the field answers 422. A write that sends `true` or
`false` fixes the section, and a null removes the option. A PUT that leaves
the field out removes it too. A plan that holds `true` or `false` shows a
diff, and its apply sends the field and fixes the section. An unset bool reads
as in 3.x: `false` for `masq` and `mtu_fix`, `true` for `enabled`, and `null`
for `reflection`.

## Curated string fields refuse newlines and carriage returns

One check in the type gate now refuses `\n` and `\r` in every curated string on
write (announced in 3.4.0, #276), so the refusal no longer depends on the
per-field `LINE_RE`/`ONE_LINE_RE` patterns, which had disagreed about `\r`. The
only opt-out is `system.notes`, which holds several lines on purpose, as its
description in the spec says. Free-text fields such as descriptions that no
daemon reads as one line are refused too. That is the announced breaking part. A
stored one blocks every write of its section, as the #308 section above says.
Per-field `pattern`s keep their word, quote and glob rules.

## `network/routes.table` and `network/rules.lookup` accept a table name on write

The request type of both fields is now a union of integer and string (announced
in 3.4.0, #240). A name is resolved exactly as netifd resolves it (number, then
`default`/`main`/`local`, then `/etc/iproute2/rt_tables`) and stored as its id.
A name that does not resolve answers 422 `invalid_format`, and an id of 0
answers 422 `out_of_range`. The read still answers the id, so a plan stays
stable when `rt_tables` changes, and a name stored by hand or by LuCI still
reads as its id. The response schema keeps the integer type of 3.x.

## `network/interfaces.ip6prefix` is array-only on write

A space-separated string on write is refused with 422 `invalid_type` (announced
since 3.2.0, removed in v4, #241). Send an array, which is also what the read
has returned since 3.2.0. A one-element array is still stored as a scalar, which
netifd, 6rd, map and 464xlat read the same way, so the stored form does not
change.

## WireGuard peer writes on OpenWrt main

3.x runs on OpenWrt 25.12, and 4.x on OpenWrt main and the next release. On
main, netifd sets up a wireguard interface with a ucode proto handler,
`/lib/netifd/proto/wireguard.uc`, in place of `wireguard.sh`. That changes what
a write to `network/wireguard_peers` does there:

- netifd restarts the interface on every peer change. So each peer write
  interrupts the tunnel for every peer of the interface, not only for the peer
  that it changes.
- The restart sets the peers from uci with one `wg syncconf`, all of them or
  none. So the kernel state of a peer write lands with the restart, after the
  commit. uapi waits up to 8 s for the restart to end, then applies the peer and
  answers, so `X-Kernel-Status: ok` reports the interface after the restart.
- A restart that does not end in 8 s fails a write that sets a peer with a
  restore: 500 `reload_failed_restored`, or `reload_failed_unrecovered` when
  the restore fails too. A write whose operations on the interface only remove
  peers, a DELETE or a write that disables them, keeps its commit and skips the
  interface instead, because the next setup reads uci, which no longer holds
  them. Since openwrt ecd9120f04, the handler leaves out a key, a preshared
  key, an endpoint or a keepalive that wg would refuse. An allowed IP that wg
  refuses still keeps the interface down, and so does an endpoint host of
  digits and dots that inet_aton does not read, which a write refuses, as the
  next section says. A write to an interface that another stored peer keeps
  down answers `X-Kernel-Status: blocked`, as the section after it says.

On 25.12, `wireguard.sh` restarts nothing on a peer change, and uapi applies
the peer with `wg set`, which leaves the other peers up. On main, the peer
changes of one interface can go in one `POST /uapi/batch`. A batch commits its
writes once and reloads netifd once, so netifd gets one change of the interface
to restart it for, not one for each peer.
`docs/errors.md` (`X-Kernel-Status`) and the kernel apply in
`docs/architecture.md` give the details.

## A WireGuard endpoint that does not resolve follows the platform

3.x committed a peer whose `endpoint_host` does not resolve. On an up interface
`wg set` refused it, and the restore answered 500 `reload_failed_restored`. On
an interface that was down, or that netifd did not know, 3.x answered 200
`X-Kernel-Status: skipped` and stored the host. v4 answers as the platform
treats such a host.

On 25.12, wireguard.sh gives the endpoint to wg, which refuses the config of the
whole interface at its next start for a name that does not exist. A write that
sends such a name for an enabled peer with a key answers 422 `conflict` on
`endpoint_host`, before its commit: a name for which busybox's nslookup gets
NXDOMAIN, or a reply with no address, such as one that holds only a CNAME. This
refuses a payload that 3.x stored on a down interface, which then did not come
up again. A lookup that fails for a time, as on a timeout or a SERVFAIL, is not
refused, because wg retries the name and the interface comes up once it
resolves. A host that inet_aton reads as an IPv4 address, such as
`192.168.1.01`, `10.1` or `0x0a000001`, asks no resolver, because wg reads it
as an address too.

On both platforms, the proto handler gives wg an IPv6 address as it stands, and
musl's getaddrinfo reads its %zone. It takes digits up to 4294967295 on any
address, and the name of an interface only on a link-local or multicast
link-local address. wg refuses the config of the whole interface for any other
zone. A write now refuses a zone that musl refuses on every router, such as
`2001:db8::1%x`, with 422 `invalid_format` on `endpoint_host`, on a disabled
peer too, and a stored one blocks every write of its peer. A write that sends a
zone that names no interface of the router, such as `fe80::1%nosuchdev`, for an
enabled peer with a key, answers 422 `conflict`. 3.x took both. On an up
interface, the write answered 500 after the restore. A down interface did not
come up at its next start.

On OpenWrt main, the ucode proto handler gives wg a host of only digits and dots
as it stands. wg refuses the config of the whole interface for one that
inet_aton does not read, such as `10.0.0.256` or `1.2.3.4.5`. A write refuses
such a host with 422 `invalid_format` on `endpoint_host`, on a disabled peer
too, and a stored one blocks every write of its peer until a write replaces it.
This refuses a payload that 3.x stored on a down interface.

The handler leaves out the endpoint of any other host for which busybox's
nslookup prints no address, and keeps the peer. The write answers 200, sets the
peer without the endpoint, and says so with the new `X-Kernel-Status: omitted`.
A read then shows `runtime.endpoint` null beside the stored `endpoint_host`. A
client that branches on the values of `X-Kernel-Status` sees `omitted` there, as
it can see a new error code.

The handler also matches a key as uci holds it. It skips a peer whose stored
`public_key` holds whitespace or a `#` comment, with its routes, and leaves out
such a `preshared_key`, or one that uci holds as a list, where wg reads both
under wireguard.sh. On OpenWrt main, such a key is now an error, so it blocks
every write of its peer, as the stored errors above do. So no write installs
the routes of such a peer, where 3.x did. LuCI refuses such a key too.

## A write to a WireGuard interface that a stored peer keeps down answers `blocked`

Both proto handlers give wg every enabled peer of an interface at once, and wg
refuses the config of the whole interface for one value that it cannot use,
such as an allowed IP that it cannot parse. A write refuses such a value when
it sends it, but LuCI or a shell can store one, and an IPv6 link-local
endpoint whose %zone names an interface keeps the interface down once that
interface goes away. The interface then does not come up.

3.x answered a write that switched an enabled interface to wireguard, enabled
a wireguard interface, or created one under the name of stored peers with 422
`conflict` on `proto` or `disabled` for such a peer. v4 keeps the commit of
such a write, as LuCI saves it, and answers 200 with the new value
`X-Kernel-Status: blocked` and the new header `X-Kernel-Blocked`, which names
each such peer as `<interface>/<id>`. Any other write of `network/interfaces`
that leaves a wireguard interface enabled answers the same, because netifd
restarts the interface, where 3.x answered `no_kernel`. A client that relied
on the 422 to keep the interface off now finds it enabled and down. To get it
up, fix, disable or delete each peer that `X-Kernel-Blocked` names.

A write of a peer of such an interface keeps its commit too, with no restore,
and answers `blocked` with the header. On 25.12, 3.x answered
`X-Kernel-Status: skipped` for it when the interface was down, and v4 names the
peer. wireguard.sh restarts nothing on a peer change, so an interface that is
still up takes the write there, `X-Kernel-Applied` names it beside `blocked`,
and the interface does not come up at its next start. On OpenWrt main, such a
write answered 500 `reload_failed_restored` when netifd read the restart as
pending after 8 s, and undid the write, a DELETE included. It now answers
`blocked` with no wait. A write that fixes, disables or deletes the peer finds
none and takes the usual path. A batch that also applies another interface
answers `partial`, with `X-Kernel-Blocked` beside it.

`GET /uapi/diagnostics?validate=1` lists each such peer with code `conflict`
on the field `""`, and a message that says that it keeps the interface down.
A client that branches on the values of `X-Kernel-Status` sees `blocked` as it
can see a new error code. No ETag, token or default changes at the upgrade.

## Four request headers take effect

3.x read `If-Match`, `If-None-Match`, `Idempotency-Key` and `X-Request-Id` only
from their query forms, `?if_match=`, `?if_none_match=`, `?idempotency_key=` and
`?request_id=`, and ignored the headers. v4 reads the headers too. A header
that is not empty wins over its query form, and an `X-Request-Id` header only
when it matches `^[A-Za-z0-9_-]{8,128}$`. A request that sends one of the
headers now gets what it asks for, where 3.x answered as if it had no header:

- A PUT, PATCH or DELETE with a stale `If-Match`, or with an `If-None-Match`
  that matches, such as `If-None-Match: *` on a section that exists, answers
  412 and writes nothing.
- A GET of one item or of a singleton with an `If-None-Match` that matches its
  ETag answers 304 with no body.
- A POST that repeats an `Idempotency-Key` replays the first response, or
  answers 409 `idempotency_key_conflict` for another body, and creates no
  second section.
- A POST with an `Idempotency-Key` outside
  `^[A-Za-z0-9_-][A-Za-z0-9_.:-]{0,127}$` answers 400 `bad_request`, as
  `?idempotency_key=` does in 3.x. A key in base64 is the usual case, because
  `+`, `/` and `=` are outside the pattern.
- A valid `X-Request-Id` is echoed in the `X-Request-Id` response header, in
  the `request_id` of an error body and in the log lines of the request, in
  place of a new ULID.

A client that sends only the query forms sees no change.

## Reads that change at the upgrade

Apart from the mount in `uhttpd.main`, the upgrade keeps `/etc/config`, the
token store and every id as they are. Of the stored scopes, only `dhcp:leases`,
`dhcp:leases6`, `*:leases` and `*:leases6` change what they grant, as the
`dhcp/leases` section says, and the scopes on `openvpn` and `*:instances` no
longer reach a tunnel, as the openvpn section says. Some reads now answer
another value for the same stored option, to follow what the daemon does:

| Resource | Field | The read changes when the option is |
|---|---|---|
| `system` | `log_remote` | absent, `enabled` or an unknown word |
| `system/timeservers` | `enabled`, `use_dhcp` | `disabled` |
| `system/timeservers` | `enable_server` | `enabled` |
| `usteer/config` | `syslog` | absent, `disabled` or an unknown word |
| `usteer/config` | `ipv6`, `assoc_steering` | `enabled` |
| `dropbear/instances` | `password_auth`, `root_password_auth`, `root_login` | `disabled` |
| `dropbear/instances` | `gateway_ports` | `enabled` |
| `sqm/queues` | `enabled` | absent, or a value other than `0`, `off`, `false` or `no` that the shell test `-eq 1` does not read as 1 |
| `wireless/interfaces` | `mode` | absent |
| `wireless/interfaces` | `device`, `network` | not a list, which reads as an array of its words, such as `["radio0"]` for `radio0` |
| `wireless/interfaces` | `ssid` | a list, which reads as its JSON text, such as `[ "home", "net" ]` |
| `wireless/interfaces` | `nasid`, `mobility_domain`, `r1_key_holder` | a list, which reads as its entries joined by spaces |
| `mwan3/interfaces` | `family` | absent, empty, or a list |
| `mwan3/rules` | `family` | empty, which reads null, or a list, which reads as the string that `config_get` joins, such as `ipv4 ipv6` |
| `firewall/defaults`, `firewall/zones` | `input`, `output_policy`, `forward` | a policy in another case or a prefix of one, such as `accept` |
| `firewall/zones` | `input`, `output_policy`, `forward` | absent |
| `firewall/defaults` | `synflood_rate` | any rate: a number, such as `25`, reads as the string `25/second` instead of an integer, and a rate with a unit, such as `25/s`, or after spaces or a `!`, reads with the whole unit instead of null |
| `firewall/defaults` | `synflood_burst` | a number that fw4 reads in another form, such as `0x10`, ` 16` or `1e3` |
| `firewall/defaults` | `syn_flood` | `synflood_protect`, which LuCI writes, is set, and `syn_flood` does not read the same value |
| `firewall/defaults` | `drop_invalid`, `tcp_syncookies`, `flow_offloading`, `flow_offloading_hw`, and `syn_flood` for `synflood_protect` and `syn_flood` | a list, or a value other than `1`, `on`, `true`, `yes`, `0`, `off`, `false` or `no`, which reads null instead of `false` |
| `firewall/zones` | `masq`, `mtu_fix` | a list, or a value other than `1`, `on`, `true`, `yes`, `0`, `off`, `false` or `no`, which reads null instead of `false` |
| `firewall/forwardings`, `firewall/rules`, `firewall/redirects`, `firewall/nat` | `enabled` | a list, or a value other than `1`, `on`, `true`, `yes`, `0`, `off`, `false` or `no`, which reads null instead of `true` |
| `firewall/redirects` | `reflection` | a list, or a value other than `1`, `on`, `true`, `yes`, `0`, `off`, `false` or `no`, which reads null instead of `true` |
| `firewall/rules`, `firewall/nat`, `firewall/redirects` | `target` | a target in another case or a prefix of one, or for nat and redirects a target that fw4 replaces with its default |
| `firewall/redirects` | `reflection_src` | a choice in another case or a prefix of one |
| `firewall/zones`, `firewall/forwardings` | `family` | `all`, `*`, `inet`, or a word with 4 or 6 |
| `firewall/rules`, `firewall/nat`, `firewall/redirects` | `match.family` | `all`, `*`, `inet`, or a word with 4 or 6 |
| `firewall/rules` | `match.src_port`, `match.dest_port` | one option of several words, as LuCI writes it |
| `firewall/rules`, `firewall/nat`, `firewall/redirects` | `match.proto` | one option of several words |
| `uhttpd/instances` | `listen_http`, `listen_https` | an option or an entry of several words |
| `network/routes` | `type` | a number from 1 to 9, in decimal, hex or octal as strtoul reads it, such as `6` or `010` |
| `network/interfaces` | `disabled` | `true`, which reads true: netifd `e97e36f` disables the interface for it, and the netifd of 25.12 did not |

A section whose read changes gets a new ETag once, at the upgrade. A write that
sends an `If-Match` from before the upgrade answers 412 `precondition_failed`.
Read the section again and send its new ETag.

A plan that sets one of these fields to its 3.x read shows a diff after the
upgrade. Its apply writes that value, and the daemon then does what the 3.x read
said, which it did not do before. Refresh the state and check each such diff
before you apply. The sections above name the cases that matter most.

For Terraform, a plan refreshes first. A field that the configuration does not
set takes the new read, and the apply writes nothing for it. Only a field that
the configuration sets writes its value. So a Terraform user edits nothing for a
read that changed, unless the configuration sets that field. A field that
carries `x-uapi-clear-on-omit`, such as a policy of `firewall/zones`, is the
exception: when the configuration does not set it, the apply removes the
option that uci holds.

The spec `default` of eight fields changes with the read: `system.log_remote` is
`true`, `usteer/config.syslog` and `sqm/queues.enabled` are `false`,
`mwan3/interfaces.family` is `ipv4`, and `wireless/interfaces.mode` and the
`input`, `output_policy` and `forward` of `firewall/zones` have none. A client
that sends the spec default for a field that its user left out now sends the
new one.

## A query parameter value outside its declared set answers 400

3.x ignored a value that a query parameter does not declare. A `managed` other
than `true` or `false` on a curated list listed every section, a `validate`
other than `1` on `/uapi/diagnostics` skipped the sweep, and an empty `cursor`
read the first page. v4 answers 400 `bad_request` for `managed` and `validate`,
and 400 `invalid_cursor` for the empty cursor. Send only the values that the
spec declares, and leave out a parameter instead of sending it empty.

## A cursor that ends on an unmanaged section holds a hash

The id of an anonymous section is its libuci name, which holds the position of
the section in its package. After a delete of an earlier section, 3.x resumed
the next page from the section that now has that name, and skipped one item
without an error. v4 gives a page that ends on an unmanaged section the cursor
`c_<id>.<hash>` and answers 400 `invalid_cursor` when an item up to that section
changed. A cursor `c_<id>` of an unmanaged section, which 3.x gave or a client
builds, answers 400 `invalid_cursor` too. Follow `X-Next-Cursor` or the `Link`
as they come. After a 400 on a page after the first, read the list again from
the first page.

## A DELETE of `uhttpd/instances/main` answers 422

3.x refused a PUT or PATCH of `main` that removed uapi's own `ucode_prefix`
entry, but a DELETE of `main` removed the section with the entry and answered
204. The next request then got a 404 from uhttpd. v4 answers 422
`validation_failed` with code `conflict` on `ucode_prefix` for a DELETE of
`main` while it holds the entry, also in `/uapi/batch`, and deletes nothing. A
DELETE of another instance, or of a `main` without the entry, works as before.
A client that manages `main` and deletes it at teardown, as a Terraform destroy
does, gets the 422. Remove `main` from its state instead.
