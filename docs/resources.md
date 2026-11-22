# Curated resources

This document indexes the 44 curated resources shipped in v4.x. For the full
schema (every field, its type, enum values, ranges, patterns), read
`build/openapi.json` (also served at `/api/v4/openapi.json` on a live
router) or open it in Swagger UI. Per-resource sample curls live in
`examples/curl/`.

`GET /schema/<package>/<resource>` serves a module's declared properties as one
set, without the request and response split the OpenAPI document makes. It is
the module's own view: a property marked `readOnly` there is absent from that
resource's `*Request` schema, a property marked `x-uapi-read-nullable` has
`null` added to its type (and to its `enum`) in both halves, as the next
paragraph explains, the keywords under a property's `x-uapi-write` (such as
`minimum: 68` on `mtu`) apply only in the `*Request` schema, those under its
`x-uapi-read` (the integer type of a route `table`) only in the `*Response`
schema, a string marked `x-uapi-multiline` takes a newline on write, and `id`,
`managed` and `runtime` are stamped by the framework rather than declared by the
module. For the two halves, read `build/openapi.json`.

`x-uapi-read-nullable` marks a property a read can answer null for, and widens
its type (and
`enum`) with null in **both** halves. Both, because every IaC apply is a
read-modify-write: the
response view goes back out as the next request body, so a request schema that
refused those
nulls would describe the round trip as invalid while the server accepts it.
Widening does not
weaken a required field, since the type is not what guards one;
`resource.validate()` is, and it
answers 422 naming the field for a null `target` on a create.
`tests/lint_response_nullability.uc` calls each resource's real `fromUci` on a
bare section and
fails if anything it returns null for is not null-permitted in the response
schema.

Every resource answers `runtime`, an object that its response schema requires
(#322): the curated ones, the non-uci ones and each item of a read-only
collection. It is `{}` where the resource reads no live state, and on a
collection item, which is itself the live state. `/raw` answers the uci section
and no `runtime`: it reads no live state, and the key would hide an option of
that name. The special endpoints under `/uapi/` are not resources.

The authoritative inventory is the OpenAPI spec; if this document drifts,
the spec wins.

## The daemon must be installed first

Curated resources that drive a daemon shipped as a separate OpenWrt
package (`unbound/server`, `sqm/queues`, `snmpd/*`, `openvpn/instances`,
`mwan3/*`, `vnstat/config`, `usteer/config`, `lldpd/config`,
`prometheus_node_exporter_lua/config`,
`uhttpd/instances` beyond `main`) need the underlying package installed
before writes succeed. Writing to a resource whose daemon is absent
returns `503 init_script_missing` with the missing
`/etc/init.d/<service>` path in the response body, before any uci
write. The pre-flight check is part of the atomic transaction recipe;
no partial state is left behind.

The uci config file has to exist too. `wireless/devices` and
`wireless/interfaces` need `/etc/config/wireless`, which only
wifi-scripts creates, with `wifi config` when it finds a radio. LuCI
never creates a radio section. On a router or an image without it, a
write answers `503 config_missing` with the missing path, before any uci
write. That includes a PUT or PATCH of an id that a GET answers 404 for,
as with `init_script_missing`. A DELETE answers 404, because no section
can exist there, and a client reads that as already gone. A DELETE in a
`POST /uapi/batch` answers the 503, because the batch commits as one write. A
read answers an empty list. The same applies to any package whose file
was removed. An empty file is enough.

Install the daemon either out of band (`apk add unbound`, etc.) or
through uapi itself via `POST /api/v4/packages/installed`. The latter
is what a Terraform configuration would chain via `depends_on` on a
`uapi_package` resource. The base uapi package's `Depends:` only
covers what uapi *itself* needs to run (uhttpd, ucode mods); per-daemon
packages are deliberately not pulled in.

## Network

| Path | Wraps | Notes |
|---|---|---|
| `network/interfaces` | `config interface` | Protos static, dhcp, dhcpv6, pppoe, ppp, wwan, wireguard and none. Optional `id` picks the section name at create time (uci section-name charset, 32 chars, tightened to 15 for `proto=wireguard` because netifd uses it as the kernel netdev name); absent, the server emits a 14-char `wg_<rand>` for wireguard or a 28-char ULID otherwise. `runtime` block carries live ubus state (uptime, ipv4/ipv6 addresses, route table). Some fields apply only to some protos, as the `allOf` entries on `proto` in the spec say: a read omits the others, a write that names one with a value other than null, `""` or `[]` answers `422 conflict`, and a proto switch removes the old proto's options, `private_key` included, by PATCH as by PUT. The options that netifd reads for every proto (`metric`, `defaultroute`, `delegate`, `ip4table`, `ip6table`, `dns`, `mtu`, the `ip6assign` group) apply to all of them. netifd applies `mtu` to the interface's device only when that device has no `config device` section of its own, as `br-lan` has in the stock configuration, and to every device that joins the interface later, such as a Wi-Fi netdev. A device with its own section takes its MTU from `network/devices`. On ppp and pppoe, `mtu` goes to pppd, which takes 128 to 16384. `listen_port` reads a service name as the port that wg resolves, and -1 when the name does not resolve, which blocks every write of the interface. A write that switches an enabled interface to wireguard, or enables a wireguard interface, answers `422 conflict` while one of its enabled `network/wireguard_peers` holds a value that makes wg refuse the whole interface. A PATCH that switches an interface to wireguard and leaves `listen_port` out answers `422 conflict` on `listen_port` while uci holds a hand-written value that reads -1, which the read of the old proto does not show: `null` in the switch removes it, and a PUT removes it anyway. On a proto that uapi does not model, such as `6in4` or the `qmi` that an LTE router ships, a read shows the modelled options that uci stores, a POST or PUT answers `422 not_in_enum`, and a PATCH that leaves `proto` out refuses only `broadcast_flag` and keeps the options of the proto's handler. netifd takes such a proto, so it is no error of the section, and the validation sweep does not list it. On such a proto, a write stores one value of `ipaddrs`, `ip6addrs` or `ip6prefix` as an option, as LuCI writes it. netifd hands a uci list to a handler only for an option that the handler declares as a list in `ubus call network get_proto_handlers`, and 6in4, gre, ipip and vxlan declare `ipaddr` as one value. So several values for such an option, or one value stored as a list, are an error of the section with `422 conflict`, and a PATCH that sends the value stores it as an option. |
| `network/devices` | `config device` | Bridges, VLANs (8021q/8021ad), macvlan, veth, tun/tap. `mtu` below 68 is refused on write, because netifd ignores it. A stored one reads as it is. |
| `network/routes` | `config route` | Static routes; cross-refs interface. `table` reads a stored name as its id (253 `default`, 254 `main`, 255 `local`, or the id in `/etc/iproute2/rt_tables`), and 0 when netifd cannot resolve it and drops the route. A write takes an id from 1 to 4294967295, or a table name, which is resolved like netifd resolves it and stored as its id; a name that does not resolve answers 422, as does an id of 0. |
| `network/rules` | `config rule` | Policy routing. `lookup` reads and writes like the `table` of `network/routes`: the read answers the id, a write takes an id or a table name stored as its id. netifd parses no `lookup` or `goto` action: a rule without `action` is a goto rule when `goto` is set and a lookup rule otherwise, so a read derives `action` that way and a write stores no action for those two. A `goto` must jump forward, past `priority`, and goes only with action goto. A rule needs no selector, as for netifd, the kernel and LuCI. Such a rule matches every packet, so with a table that holds a default route it routes all traffic, the management session included, and without a `priority` netifd numbers it by its place among the rules, from 1 up, ahead of `main`. LuCI allows the same. `suppress_prefixlength` and `tos` read as netifd reads an integer, like `priority`. `ipproto` reads a decimal as an integer, and the other spellings that netifd takes, such as `06` or `tcp`, as uci holds them. `uidrange`, `sport` and `dport` read as uci holds them. Each reads null when unset. A write takes an integer from 0 to 32 for `suppress_prefixlength` and from 1 to 255 for `ipproto`, as LuCI's form does, a `tos` of 0, 4, 8, 12, 16, 20, 24 or 28, and ports from 1 to 65534 and uids from 0 to 4294967294 as plain decimals, alone or as a range that does not run backwards. A stored value in another form blocks every write of the rule until a write replaces it. The validation sweep lists it, live when netifd drops the enabled rule or the kernel refuses it. |
| `network/bridge_vlans` | `config bridge-vlan` | Bridge VLAN tagging (vlan 1-4094 + port spec). |
| `network/wireguard_peers` | `config wireguard_<iface>` (dynamic) | Peers on a wireguard interface; preshared_key masked on read. `endpoint_port` reads a service name such as `https` as its port from `/etc/services`, as wg resolves it, and 0 when the name does not resolve. A peer with a host and no port reads `endpoint_port` null, and both proto handlers, the kernel apply and the restore give wg port 51820 for it. On 25.12, wireguard.sh gives wg every host, and wg refuses the config of the whole interface for a name that does not exist, which then stays down from its next start. So a write that sends such a name for an enabled peer with a key answers `422 conflict` on `endpoint_host`: a name for which busybox's nslookup gets NXDOMAIN, or a reply with no address, such as a reply that holds only a CNAME. A lookup that fails for a time, as on a timeout or a SERVFAIL, is not refused, because wg retries the name and the interface comes up once it resolves. A host that inet_aton reads as an IPv4 address, such as `192.168.1.01`, `10.1` or `0x0a000001`, asks no resolver. Both handlers give wg an IPv6 address as it stands, and musl's getaddrinfo takes a %zone of digits up to 4294967295 on any address, and the name of an interface only on a link-local or multicast link-local address. wg refuses the config of the whole interface for any other zone. A write refuses such a zone with `invalid_format`, a stored one too. A write that sends a zone that names no interface of the router, for an enabled peer with a key, answers `422 conflict`. On OpenWrt main, the ucode handler gives wg a host of only digits and dots as it stands, so a write refuses one that inet_aton does not read, such as `10.0.0.256`, with `invalid_format`, a stored one too, because wg then refuses the config of the whole interface. The handler looks up every other host with nslookup, leaves out the endpoint of one for which nslookup prints no address, and keeps the peer, so the write sets the peer without it and answers `X-Kernel-Status: omitted`. Apart from the `invalid_format` rules, a stored host is not checked, because a name or an interface can exist at one time and not at another. `persistent_keepalive` reads `off` as 0, and -1 when wg cannot read the stored value. `allowed_ips` is optional, as in LuCI, and a peer without it is set in the kernel with none. `allowed_ips` reads the entries as wg gets them: wireguard.sh joins a list with spaces, leaving out an empty entry, makes each space a comma, and expands the escapes of printf %b, and wg cuts the line at a NUL byte and at `#` and splits it at commas. So `\054` and a comma separate two entries, two prefixes that a tab separates read as one entry, and a space at either end or next to another adds an empty one. wg refuses the last two, and so does a write, on a disabled peer too. A value that the escapes would give a second line, the end of the config or a byte that is not printable ASCII, or that holds a backslash and is longer than 512 bytes, reads unexpanded. A value that wg reads as an empty line, such as one that starts with `#`, reads as one empty entry, because wireguard.sh still writes the line and wg refuses it. The routes of `route_allowed_ips` go to each word of the option as stored, split at tabs and newlines too and before the escapes, as wireguard.sh installs them: the address before the first `/` of a word and the length after its last, read as netifd reads it. A write refuses a key that is not on one line as `wg genkey` prints it, or that holds a backslash, a stored one too. A peer that stores such a key still takes a DELETE, unless the key holds a backslash and is longer than 512 bytes. On OpenWrt main, the ucode handler matches a key as uci holds it. It skips a peer whose `public_key` does not match, with its routes, and leaves out a `preshared_key` that does not, so there a stored key with whitespace or a `#` comment, or one that uci holds as a list, is an error too. A write of `network/interfaces` that brings up the peers does not check the other values of a peer that the handler skips. The restore after a failed write keeps a peer whose stored `preshared_key` wg cannot read as the kernel holds it, and sets the peers after it. It answers `reload_failed_unrecovered` when the failed write set or removed that peer, or the kernel does not hold it. `runtime` carries what the kernel holds for the peer, from one `wg show <iface> dump` for each interface that a request reads: `in_kernel`, under the key that wg reads from the stored `public_key`, the `endpoint`, `allowed_ips` and `persistent_keepalive` of the kernel beside the fields that uci holds, and `latest_handshake`, `rx_bytes` and `tx_bytes`. uapi compares nothing and corrects nothing, so a client sees a peer that `wg` changed by hand, or that a failed apply left behind. Only a GET reads `runtime`: unlike the other resources, a write answers `runtime: {}` and reads no kernel state, since the kernel apply comes after its body, and `X-Kernel-Status` says whether the apply landed. A GET in a `/uapi/batch` that writes answers `{}` too, since it runs before the apply of the batch. `runtime` is also `{}` when uapi did not read the kernel, because the interface is not up, wg fails or wg prints a dump in a shape that uapi does not read, and when the stored key gives wg more than a key or is too long to expand. `runtime.allowed_ips` is in the form that the kernel prints, with the host bits cleared and IPv6 in its short form, and two peers that store the same key both report the one peer of the kernel. |
| `network/wireguard_kernel_peers` (read-only collection) | `wg show <iface> dump` | The WireGuard peers the kernel holds that no uci section of their interface claims, on up interfaces with proto=wireguard: what a hand `wg set` added or a failed apply left, which no other read reports. Keyed as wg reads the stored key, the later `PublicKey=` lines of one included, and disabled sections included, because the `runtime` of a disabled section already reports a peer the kernel holds under its key. One dump per interface per request, the same one the `runtime` reads. A down interface or a failing `wg` lists nothing, as `runtime` answers `{}`. The stable `id` is the first 12 hex of the sha256 of the interface name and the public key. No write, no lock, no ETag. |

**`option disabled` is modelled on `network/interfaces`, `network/routes` and
`network/rules`.** netifd drops a disabled section outright on all three. A
disabled interface is never registered, so it has no ubus object and its
addresses and routes are absent. A disabled route or rule is never installed.
`network/wireguard_peers` models `disabled` as well.

Each resource reads the option with the helper that matches its own parser,
because netifd does not parse it the same way for all three. On the interface,
netifd compares the value literally against `1`, and uapi reads it with
`strict_bool`. On routes and rules, the value goes through the boolean blob
converter, which also takes `true`, and uapi reads it with `platform_bool`.
Neither parser takes `on` or `yes`. So `option disabled 'true'` disables a route
or a rule and leaves an interface running. One shared reader would report such
an interface as disabled while it is up. A unit test pins the difference in both
directions. netifd `e97e36f` (2026-07-16) takes `true` on the interface too.
When the OpenWrt branch that uapi supports carries it, the interface reader can
widen ([#311](https://github.com/openwrt-iac/uapi/issues/311)), and that test
shows when.

[#64](https://github.com/openwrt-iac/uapi/issues/64) tracked the gap. Two
alternatives were turned down:

- Ship `disabled` on routes and rules first, and wait for upstream on the
  interface. The interface is where disabling matters most, because it takes
  the addresses, routes and peers with it. `disabled` on two of three sibling
  resources is also an asymmetry that no operator can explain from outside.
- Read the flag one way on all three, and let `runtime` show the disagreement,
  as `effective_proto` does for the proto. But `disabled: true` with
  `runtime.up: false` cannot tell a disabled interface from an enabled one that
  failed, and that is the case an operator most needs to tell apart.

Reload: `network` (netifd), then `odhcpd` while procd holds a `config.change`
trigger for it, under the rule of a `dhcp` write below. odhcpd reads the network
config and has a procd trigger on `network`, which a commit through libuci does
not fire. So a network write runs one more init script while procd holds that
trigger, `/etc/init.d/odhcpd reload`, which sends odhcpd a signal, and holds the
global SH and the lock of `network` while it runs, so a non-uci write at that
moment answers `423 locked`. If that reload exits non-zero, the write answers
`500 reload_failed_restored` and restores the previous config, or `500
reload_failed_unrecovered` when the reload fails on that config too. A LuCI save
of `network` also reloads dnsmasq and unbound, because LuCI's ucitrack has
`network` affect `dhcp`. uapi leaves them out on purpose: from this package
dnsmasq.init reads only `ula_prefix` of the globals, which no resource here
writes, and unbound that and the names of the interface sections, and both
reload on the netifd events of the interfaces that they serve (`docs/raw.md`).
So a network write takes no lock of `unbound` and does not wait for unbound.

**Editing the interface that backs your management connection is dangerous.**
`/etc/init.d/network reload` returns exit 0 even when an interface fails to
come up at runtime; uapi only sees the init script's exit code, not the
daemon's runtime convergence.

## Firewall

| Path | Wraps | Notes |
|---|---|---|
| `firewall/zones` | `config zone` | `input`, `output_policy` and `forward` policies, `network` list. A policy that the zone does not set reads null: fw4 then applies the one of `firewall/defaults`, and DROP when that has none. The three policies carry `x-uapi-clear-on-omit`: a PUT that leaves one out, or a null, removes the option, and the zone takes the policy of `firewall/defaults` again. A PATCH that leaves one out keeps it. A write refuses a `name` that starts with a digit or a dash, since fw4 skips such a zone, and a stored one blocks every write of the section. |
| `firewall/rules` | `config rule` | Nested `match: {src_zone, dest_zone, src_ip, dest_ip, src_port, dest_port, proto, family, mark, dscp}`. MARK and DSCP targets carry `set_mark` / `set_xmark` and `set_dscp`. `src_zone` is required only for NOTRACK, matching fw4. A read also gives the HELPER target that LuCI writes. A write refuses it, except in a PATCH that sends it back: a PUT removes the `set_helper` option, which uapi does not model, and firewall4 skips a HELPER rule without it. |
| `firewall/redirects` | `config redirect` | DNAT + NAT loopback reflection. DNAT and SNAT. Every `match` field except `proto` is a scalar, because firewall4 refuses a list on them and drops the section. `match.src_dip` is the external address matched on a DNAT (and the address NAT reflection uses) and the rewrite source on an SNAT, where it is required along with a named `match.dest_zone`. Prefer `firewall/nat` for new source NAT; LuCI migrates these sections there. |
| `firewall/nat` | `config nat` | Source NAT: SNAT (`snat_ip` / `snat_port`), MASQUERADE, or ACCEPT to exempt traffic from rewriting. `match.src_zone` is the outbound zone. An unset `match.family` means IPv4 only, which is fw4's default for NAT. |
| `firewall/forwardings` | `config forwarding` | Zone-to-zone forwarding. |
| `firewall/defaults` (singleton) | `config defaults` | Global verdicts, syn_flood, synflood_burst/rate, tcp_syncookies, flow_offloading. `syn_flood` reads what fw4 applies: `synflood_protect`, which LuCI writes, and `syn_flood` only when uci holds no `synflood_protect`. A write of true stores `synflood_protect` and removes `syn_flood`, as LuCI does. A write of false removes `synflood_protect` and stores `syn_flood` `0`, where LuCI removes both. `synflood_rate` reads as fw4 applies it, always with its unit, such as `25/second`, and a write also takes an integer, a rate per second. A rate that overflows 64 bits in the kernel with the burst, such as `1/minute` with a burst of 4294967295, answers 422 `out_of_range` and is an error of the section when stored, since fw4 then applies no ruleset while `syn_flood` is on. `synflood_burst` reads as fw4 parses it, so `0x10` reads 16. A bool or number option that fw4's parser refuses, such as a `synflood_rate` of `abc` or a `synflood_protect` of `maybe`, reads `false` or null and is an error of the section, since fw4 then applies no ruleset. |

Reload: `firewall` (fw4).

A policy, a target, `reflection_src` and a family read as fw4 reads them: a
choice in any case or a prefix of one, such as `accept` or `acc` for ACCEPT,
and `all`, `*`, `inet` or a word with 4 or 6 for a family. A target that fw4
replaces with its default, with a warning, reads as that default. A port or
proto that uci holds as one option of several words reads as its words, as LuCI
writes the ports of a rule. A match port, mark or DSCP takes a `!` with blanks
around it, as LuCI writes it.

## Wireless

| Path | Wraps | Notes |
|---|---|---|
| `wireless/devices` | `config wifi-device` | Radios (mac80211/broadcom), the `path`, `macaddr`, `phy` and `radio` that bind them to their hardware, band, channel, htmode, country, txpower, cell_density, legacy_rates. |
| `wireless/interfaces` | `config wifi-iface` | SSIDs, with every 802.11r option of LuCI's WLAN roaming tab. `key`, `r0kh` and `r1kh` are write-only, and a PUT that leaves them out keeps them. Responses include `has_key`, `has_r0kh` and `has_r1kh`. `device` and `network` read a list that uci holds as an array, since netifd takes a list or words for either, and a write takes a string or a list. `ssid`, `nasid`, `mobility_domain` and `r1_key_holder` read a stored list as an array too, which is no error, and a write takes only a string. wifi-scripts writes `key`, `nasid`, `mobility_domain`, `r1_key_holder`, `r0kh` and `r1kh` into the daemon's config as lines, so a write refuses a newline in them, more than 1024 bytes in each of them but `key`, and a key holder entry that hostapd reads and cannot parse. A stored one blocks every write of the SSID, also while wifi-scripts does not set the SSID up, which it does only while the SSID and its radio are enabled. A write also refuses the values that the daemons refuse or misread: an `ssid` over 32 bytes, a `key` in a form that hostapd or wpa_supplicant refuses for the mode and encryption, a `nasid` over 253 bytes on an EAP access point, `ieee80211r` with owe on an access point, a `reassociation_deadline` outside 1000 to 65535, a `mobility_domain` other than 4 hex digits, an `r1_key_holder` other than 12, and an `encryption` that starts with `wep` in mode mesh, or where the router does not set WEP up. WEP needs the shell wifi-scripts and the daemon of the mode built with WEP: hostapd in mode ap, wpa_supplicant in mode sta or adhoc. The ucode wifi-scripts, which OpenWrt builds by default, give the daemon no WEP key, and the SSID runs without encryption. uapi asks `hostapd -vwep` or `wpa_supplicant -vwep`, as LuCI does, at most once per request and only for a WEP value. `encryption` also takes the `wep-open` and `wep-shared` that LuCI writes, under the same rule. A stored one of these blocks every write too, whether the daemon reads it yet or not. A write refuses mode `wds` and `ahdemo` too, which wifi-scripts skips as it skips a section without a mode, and a stored one is no error. hostapd reads `mobility_domain` as the mobility domain with 802.11r, and as the EAP domain of an access point with `fils`, which uapi does not model. That domain takes any form, so the sweep marks a newline or a length in `mobility_domain` live on an EAP access point too, and its form only with 802.11r. A write to `wireless/devices` that turns a radio on is refused while an enabled SSID of the radio holds any of these values. The validation sweep lists every SSID that holds such a value. These rules follow the ucode wifi-scripts, which OpenWrt 25.12 builds by default. They were not checked against the shell wifi-scripts, which OpenWrt 24.10 uses: uapi supports 25.12 and later, where the shell variant runs only on an image built without `CONFIG_WIFI_SCRIPTS_UCODE`. A write that sets an EAP mode needs `key`, and a stored EAP SSID without one, as LuCI writes it, is no error. A create or a PUT that sends no `mode` stores none, and so does a write that sends a null `mode`. wifi-scripts sets up nothing for such a section, and a read reports its mode as null. A write to it is still checked as mode `ap`, but none of its errors blocks turning its radio on. `runtime` carries iwinfo state. |

Reload: `network`. A LuCI save of `wireless` also reaches odhcpd, dnsmasq and
unbound, because LuCI's ucitrack has `wireless` affect `network`, which affects
`dhcp`. None of them reads `/etc/config/wireless`, so a wireless write leaves
them out (`docs/raw.md`). Requires `rpcd-mod-iwinfo` at runtime for the
`runtime` block on `wireless/interfaces`.

## DHCP

| Path | Wraps | Notes |
|---|---|---|
| `dhcp/hosts` | `config host` | Static leases. `macs` (the whole uci `list mac`), `ip`, `name`, `leasetime`, `duid`, `tag` (tags the host sets), `match_tag` (tags a request must carry). dnsmasq.init joins `mac` and `tag` with spaces and splits the words, so a list entry `a b` reads as two. A MAC octet can be `*`, which dnsmasq and LuCI take. odhcpd cannot parse such a MAC and skips the whole host. |
| `dhcp/servers` | `config dhcp` | Per-interface server config. `runtime` carries active-lease counts. `dhcpv4`, `ra_flags` and `ra_slaac` are the options that odhcpd.defaults writes into the stock `lan` section. `ra_flags` reads null when unset, which odhcpd takes as `other-config` only, and `["none"]` sets no flag. A read gives the flags that odhcpd sets: uci passes it the words of an option split at spaces and tabs, or each list entry whole, and odhcpd stops at the first word that is no flag name. When it sets none, such as for an option of spaces, the read gives `["none"]`. `dhcpv4` takes the four modes of `ra`. odhcpd has no DHCPv4 relay, so dnsmasq and odhcpd both serve on every value but `disabled`, and odhcpd reads `dhcpv4` only when `dhcp/odhcpd` sets `maindhcp`. An unset `dhcpv4` differs by platform: the dnsmasq of OpenWrt 25.12 serves it, and the dnsmasq of OpenWrt main takes it as `disabled` (`dnsmasq.init`, `config_get dhcpv4 "$cfg" dhcpv4 disabled`), as odhcpd does. LuCI's DHCP setup writes `server`. `dhcp_option` takes one option per entry, because dnsmasq.init passes each entry to dnsmasq whole and dnsmasq reads it as one option. An entry answers `422 invalid_format` when, outside a quoted string, a field that reads as an address, such as `10.0.0.1` or `[::]`, is followed by whitespace and then by what starts a `dhcp-option` value: a number and a comma, `option:`, `option6:`, `tag:`, `net:`, `set:`, `vendor:`, `encap:` or `vi-encap:`, as in `3,10.0.0.1 6,10.0.0.1`. LuCI's form takes any entry. A text option with spaces, such as `15,my domain` or `15,my 6,domain`, stays valid. A stored entry that the rule refuses blocks every write of the section. Other entries that dnsmasq refuses, such as `3,10.0.0.1, 6,10.0.0.1`, pass the rule and are left to the `--test` check below. |
| `dhcp/dnsmasq` (singleton) | `config dnsmasq` | Global dnsmasq tuning; forwarders, address overrides, rebind protection. dnsmasq.init passes `server` and `address` with `config_list_foreach`, so an option of either reads null. |
| `dhcp/odhcpd` (singleton) | `config odhcpd` | `maindhcp`, `leasefile`, `loglevel`. `maindhcp` reads true only for `1` in the section named `odhcpd`, which both daemons take. dnsmasq.init stops serving DHCPv4 for any number above 0 in that section, and odhcpd takes `true` too and keeps the value that it has for any other value or no option, since a reload does not reset it. A write that sends `maindhcp` stores `1` or `0` even when the read already gives that value, so that both daemons agree, and null removes the option. LuCI shows a value other than `1` unchecked and removes the option when it saves the form. |
| `dhcp/leases` (read-only collection) | `/tmp/dhcp.leases`; `?family=v6` reads the `leasefile` of odhcpd, `/tmp/odhcpd.leases` by default | IPv4 leases from dnsmasq's lease file, or IPv6 leases from odhcpd with `?family=v6` (merged in v4, #320), one entry per address or prefix. A `*` that dnsmasq writes for a missing host name or client id reads null. Entry id is the MAC for v4, the IP for v6. Another `family` answers 400 `bad_request`, and the `Link` to the next page keeps the `family`. |

Reload: each write reloads the daemons that read what it writes, in this order,
and each of them only while procd runs it. `dhcp/servers` and `dhcp/hosts`
reload `dnsmasq`, `odhcpd` and `unbound`. odhcpd reads a server section too,
`ra`, `dhcpv6` and `ra_default` among others, and the static leases of a host.
unbound reads `interface` and `ignore` of a server section, and makes records of
the `name` and `ip` of a host when its `add_extra_dns` is set. `dhcp/odhcpd`
reloads `odhcpd`, `dnsmasq` and `unbound`, because dnsmasq.init reads `maindhcp`
and unbound makes the directory of `leasefile`. `dhcp/dnsmasq` reloads `dnsmasq`
and `unbound`, which reads `domain` and `port` when it forwards local names to
dnsmasq. procd runs a daemon while it holds a `config.change` trigger for it,
from the start of the service to its stop, whatever its instances show, which is
when a LuCI save reloads it. A daemon that the router does not ship, that the
operator stopped, or that has no such trigger yet, as unbound at boot until 3 s
after the last interface event, is skipped: the write does not answer `503
init_script_missing` for it, and its reload does not start it, as the reload of
dnsmasq.init and unbound.init would. When the `service list` call fails, uapi
cannot tell, and reloads the daemon. A write when none of them runs answers 2xx
with `X-Reload-Status: no_reload`. LuCI saves through rpcd, which fires the
procd reload trigger on `dhcp` of each daemon that procd lists with one. A
commit through libuci fires none, so uapi runs the reloads above itself. A write
takes the lock of `unbound` too while `/etc/init.d/unbound` exists, before it
asks procd which daemons to reload, so a write to the `unbound` packages, or a
`system` write that can reload unbound, at the same moment answers `423 locked`,
whether unbound runs or not. When unbound ran before the write, it waits 2 s for
unbound to keep running, as a write to `unbound/server` does.

After a write that reloads dnsmasq, uapi runs the command of each dnsmasq
instance with `--test` on the config that dnsmasq.init just wrote. If dnsmasq
refuses it, the write answers `500 reload_failed_restored` and restores the
previous config. dnsmasq refuses a line such as a `dhcp_option` of
`3,not-an-address` in a section that it reads, one that is not ignored, on an
interface that is up and static. The check covers every instance, one that is
not running included, so on a router whose dnsmasq config was refused before the
write, a write that does not fix it answers `500 reload_failed_unrecovered`. A
`--test` that cannot run, because fork fails, fails the write in the same way. A
`--test` that does not finish within 10 s, such as one that reads a `conf-file`
on a mount that hangs, or that another `SIGKILL` stops, is killed and judges
nothing: the write keeps its commit and answers 2xx with `X-Reload-Status:
unverified`. A target that takes longer than 10 s to parse its config, such as a
slow router with large adblock lists, answers `unverified` on every dhcp write.
`--test` only parses: a config that dnsmasq parses but cannot start with, such
as one whose port another daemon holds, still answers 2xx. No write waits for
the daemon to start, and each pays one parse of the whole config per instance,
which grows with its size, and again on a restore. A write that does not reload
dnsmasq, because procd does not run it, runs no check.

## System

| Path | Wraps | Notes |
|---|---|---|
| `system` (singleton) | `config system` | hostname, timezone, log_size, log_ip, log_proto, log_remote, urandom_seed. Reloads `system` and `log`, then `dnsmasq`, `odhcpd` and `unbound` while procd runs each: dnsmasq.init and unbound read the hostname, and odhcpd the timezone. It runs no `dnsmasq --test` check. While `/etc/init.d/unbound` exists, the write takes the lock of `unbound`, so a write to `unbound/server`, `unbound/srv`, `unbound/ext` or the `dhcp` package at the same moment answers `423 locked`, whether unbound runs or not, and when unbound ran before the write, it waits 2 s for unbound to keep running. |
| `system/timeservers` | `config timeserver` | NTP server list; reloads sysntpd, then `dnsmasq` while procd runs it, because dnsmasq.init reads `enabled` for DNSSEC. It runs no `dnsmasq --test` check. |
| `system/password` | `/bin/busybox passwd` (non-uci, write-only) | `POST {user, password}` -> 204. A user that `/etc/passwd` does not hold answers 422 `conflict`. Audit-logged without password. |
| `system/authorized_keys` | `/etc/dropbear/authorized_keys` (non-uci) | `GET`/`POST`/`PUT`/`DELETE` for SSH key entries. Server-side key-type validation. |
| `system/cron_jobs` | `/etc/crontabs/root` (non-uci) | `GET`/`POST`/`DELETE` for one crontab line each. Lines from packages stay as they are. `runtime.crond_running` reports whether crond runs, and `runtime.runs_as_written` flags a line crond misreads. |

## Other daemons

| Path | Wraps | Notes |
|---|---|---|
| `dropbear/instances` | `config dropbear` | Per-instance SSH config (port, password_auth, root_login, etc.). |
| `uhttpd/instances` | `config uhttpd` | Per-instance HTTP server. Validate refuses to strip uapi's own `ucode_prefix` from `main` (self-lockout protection). |
| `uhttpd/certs` | `config cert` | px5g cert generation params. |
| `unbound/server` (singleton) | `config unbound` | Recursive DNS tuning. |
| `unbound/srv` (singleton) | `config unbound_srv 'main'` | Server-clause directives (`interface_bind`, `interface_outgoing`, `ip_transparent`, plus a raw `srv_line` passthrough). Requires `apk add unbound-uci-ext` from the openwrt-iac feed; otherwise the first write returns `503 init_script_missing`. |
| `unbound/ext` (singleton) | `config unbound_ext 'main'` | Outside-server clauses (`forward-zone:`, `view:`, `stub:`, `remote-control:`) expressed as a verbatim `ext_line` list (one entry per rendered line). Same install dependency as `unbound/srv`. |
| `sqm/queues` | `config queue` | Per-interface SQM shaping. |
| `snmpd/agents` | `config agent` | SNMP listen addrs. |
| `snmpd/com2secs` | `config com2sec` | community-to-security mapping. |
| `snmpd/groups` | `config group` | SNMP group definitions. |
| `snmpd/accesses` | `config access` | group-to-view ACLs. |
| `snmpd/system` (singleton) | `config system` (snmpd) | sys_location, sys_contact, etc. (snake_case in v2). |
| `lldpd/config` (singleton) | `config lldpd 'config'` | LLDP/CDP/etc. toggles. |
| `prometheus_node_exporter_lua/config` (singleton) | `config prometheus-node-exporter-lua 'main'` | `listen_interface` + `listen_port`. |
| `vnstat/config` (singleton) | `config vnstat` | `interfaces`, the devices vnstat tracks (kernel device names, not uci interface names). The only vnstat option any shipped code reads. |
| `mwan3/globals` (singleton) | `config globals` | `mmx_mask`, `logging`, `loglevel`. A write takes the `loglevel` names that LuCI offers. A stored level that iptables refuses, such as `err` or `warn`, blocks every write of the section, and one that iptables takes, such as `panic` or `0x3`, is no error. |
| `mwan3/interfaces` | `config interface` (mwan3) | Per-WAN tracking: `track_ip`, `track_method`, probe sizing and timing, up/down thresholds, `flush_conntrack`. |
| `mwan3/members` | `config member` | Binds an `mwan3/interfaces` section to a `metric` and a `weight`. A write takes a metric from 1 to 256, since mwan3 leaves a member with a higher one out of its policy, and a stored one above 256 blocks every write of the section. |
| `mwan3/policies` | `config policy` | `use_members` plus a `last_resort` verdict. |
| `mwan3/rules` | `config rule` (mwan3) | Traffic match (family, proto, src/dest ip and port, ipset) routed to a `use_policy`. A write takes a `proto` that iptables takes, in any case. With `src_port` or `dest_port`, it refuses `tcp` or `udp` in another case, whose ports mwan3 drops, and a stored one blocks every write of the section. mwan3 drops the ports of any other proto too, and such a rule is no error. `family` reads a list as mwan3's `config_get` joins it, and a value other than `ipv4` or `ipv6`, which mwan3 runs for both families, blocks no write. |
| `openvpn/instances` | `config openvpn` | Per-instance OpenVPN config. `key`, `tls_auth` and `pkcs12` are write-only; responses carry `has_key` / `has_tls_auth` / `has_pkcs12`. |
| `usteer/config` (singleton) | `config usteer` | Band-steering and roaming thresholds for the usteer daemon. |

When unbound runs, a write to one of the three unbound resources waits 2 s after
the reload. If unbound stops in that time, the write answers `500
reload_failed_restored` and restores the previous config. unbound stops for a
line of `srv_line` or `ext_line` that it cannot parse. Two of these writes at
the same time answer `423 locked` for the second, because each restarts unbound,
and so does one of them beside a `dhcp` or `system` write, which can reload
unbound.

## Packages (non-uci)

| Path | Source of truth | Notes |
|---|---|---|
| `packages/installed` | apk DB | `GET` lists, `POST {name}` installs (`apk add`), `DELETE /<name>` removes. |
| `packages/feeds` | `/etc/apk/repositories.d/*.list` | `GET` lists the feed files and `GET /<id>` reads one. `POST {name, url}` creates a feed file + `apk update`, and `DELETE /<id>` removes one + `apk update`. |

## Anonymous sections and adoption

OpenWrt's uci distinguishes **named** sections (stable identifier across
rewrites) from **anonymous** sections. libuci names an anonymous section at each
load as `cfg`, the position of the section in its package in hex, and four hex
digits of a hash of its type, such as `cfg0692bd`. When an earlier section is
deleted, each later anonymous section gets a lower position in its name, so it
can take the old name of the section before it. Anonymous ids are useless for
IaC state tracking.

uapi-managed sections are always named: when a client POSTs to create a
resource, the server emits a ULID-style identifier (Crockford base32,
alphanumeric only, fitting uci's `[A-Za-z0-9_]` charset) and writes it as the
section's `.name`. From that point on, the section behaves like any other named
uci section and its id is stable. Optional one-character type prefix for
grep-ability (`r_01HX...` for rules, `i_01HX...` for interfaces). No `uapi_`
namespace prefix; uapi is just another writer to uci.

Section names are caller-pickable on every CRUD resource (since 2.2.0). `POST
/<resource>` accepts an optional `id` field; if supplied it becomes the section
name (after charset / length / collision checks). Absent, the server emits the
ULID.

### Pre-existing anonymous sections

The common starting state for a router under management is a mix of LuCI-named
sections, hand-edited sections, and anonymous sections from prior tooling.
Posture: **read-only by default, explicit adoption.**

- `GET /<resource>` returns existing anonymous sections with their libuci name
  as the id and `managed: false`. That id changes when an earlier section is
  deleted, so a client adopts the section first and keeps the new id.
- `PUT`/`PATCH`/`DELETE` on a `managed: false` section returns `409
  unmanaged_resource`.
- `POST /<resource>/<id>/adopt` on an **anonymous** section renames it under
  uapi's ULID scheme and flips it to `managed: true`. The section is writable
  like any other after that.
- `POST /<resource>/<id>/adopt` on a **named** section is an idempotent
  acknowledgement: the section keeps its name and the response carries the
  existing view with `managed: true`. The 2.2.0 behavior change replaced the
  prior rename-to-ULID which broke uci cross-references where sections
  referenced this one by name (`firewall.zones.lan` → `firewall.rules.src_zone =
  "lan"`).

Sections that already have a `.name` (e.g. LuCI-named `myrule`) are managed
normally, using their existing `.name` as the id. uapi does not rewrite names it
didn't author.

`GET` on a collection includes both managed and unmanaged sections by default.
Clients filter via `?managed=true` / `?managed=false` when they want one or the
other. The `Link` to the next page keeps the filter.
Another value answers 400 `bad_request`.

A page that ends on an unmanaged section gives the cursor `c_<id>.<hash>`, where
the hash covers the ETags of the items up to and including that section. When
one of these items changed, for example because an earlier section was deleted
and the names moved, the cursor answers 400 `invalid_cursor` and does not skip
an item. Read the list again from the first page. A cursor of a managed section
is `c_<id>`, and a change before it does not refuse it.

## Generic raw passthrough

`/api/v4/raw/<package>/<id>` is the escape hatch for any uci config type
uapi doesn't curate. See `docs/raw.md` for full semantics, scope
composition rules, and stability caveat.

## System endpoints

| Path | Auth | Notes |
|---|---|---|
| `GET /healthz` | none | `{status, version, checks: {ubus, uci, lock_dir, time_sync}}`. 503 when any subsystem is degraded. |
| `GET /openapi.json` | none | The OpenAPI 3.1 spec. |
| `GET /schema/<package>/<resource>` | none | One resource's `schema_properties`. `GET /schema` lists all keys. |
| `GET /uapi/whoami` | any token | Token introspection: token_id, scopes, source_ip, expires_at, allowed_cidrs, last_used_at, last_used_ip. |
| `GET /uapi/tokens`, `GET /uapi/tokens/<id>`, `POST /uapi/tokens`, `DELETE /uapi/tokens/<id>` | `uapi:tokens:ro` for a GET, `uapi:tokens:rw` for a write (or `*`) | HTTP token rotation. POST refuses a scope outside the scope tree with 422, and requires the caller's scopes to cover the requested scopes, equal or narrower. |
| `GET /uapi/metrics` | `uapi:metrics:ro` (or `*:ro`) | Prometheus 0.0.4 text. |
| `GET /uapi/diagnostics` | `uapi:diagnostics:ro` | Version, uptime, loaded resources, the lock files present, `state_dirs`, `limits`, `interrupted_writes`, `recent_errors` and `management_path`. `?validate=1` adds the validation sweep. `docs/operations.md` § Diagnostics has the fields. |
| `POST /uapi/batch` | each sub-request scope-checked | Multi-package all-or-nothing transaction (max 50 ops). |
