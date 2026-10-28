# Changelog

All notable changes to this project will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`network/interfaces.sourcefilter` lets the downstream subnets of a routed `ip6prefix` reach
  the internet.** An ISP that routes a static block instead of delegating one by DHCPv6-PD goes in
  `ip6prefix` on the uplink, but the uplink's default route is source-specific and covers only its
  own addresses, so traffic from the downstream /64s matched no route. `sourcefilter: false` makes
  the upstream script add the default route without a source. It applies to protos `dhcpv6`,
  `ppp` and `pppoe`, whose scripts read it, and reads as null when unset. (#206)
- **`network/interfaces.ip6class` and `ip6weight`** complete the prefix-assignment options next to
  `ip6assign`, for every proto: `ip6class` limits which prefixes an interface takes its subnet from
  (`local` for the ULA prefix, or the name of the interface that received the prefix), and
  `ip6weight` orders the interfaces when they share a prefix. A stored scalar `ip6class` reads as
  its whitespace-separated words, which is how netifd reads it. (#206)
- **`network/interfaces.broadcast_flag` is uci's `broadcast` flag on proto `dhcp`**, which makes
  udhcpc ask the server for broadcast replies. LuCI writes it as `broadcast '1'`. uapi read that
  value as the static broadcast address, so a PUT of a dhcp interface that LuCI configured answered
  422. The wire name differs from the uci option because `broadcast` stays the address on proto
  `static`. Measured on OpenWrt 25.12.5: `true` starts udhcpc with `-B`, and `false` without it.
  (#208)
- **`network/interfaces.reqprefix` accepts a prefix with its length**, for example
  `2001:db8::/56`, as LuCI documents it and odhcp6c reads it. It accepted only a length, `auto` or
  `no`. (#208)

- **`wireless/devices` and `wireless/interfaces` model the options that bind a radio to its
  hardware and the 802.11r group of an SSID.** A PUT replaces the section with what the resource
  models, so a PUT of the read deleted them, and an IaC client updates with PUT. wifi-scripts finds
  the phy of a radio by `path`, then `macaddr`, then `phy`. `wifi config` writes `path` for every
  radio whose phy is named `phyN`, so the first apply that changed a radio deleted it, and the radio
  stayed down with all its SSIDs. On an SSID, the 802.11r options were dropped, which turned fast
  roaming off. `wireless/devices` gains `path`, `macaddr`, `phy` and `radio`, and LuCI's
  `cell_density` and `legacy_rates`. `wireless/interfaces` gains every 802.11r option of LuCI's WLAN
  roaming tab: `ieee80211r`, `nasid`, `mobility_domain`, `reassociation_deadline`, `ft_over_ds`,
  `ft_psk_generate_local`, `r0_key_lifetime`, `r1_key_holder`, `pmk_r1_push`, `r0kh` and `r1kh`.
  Each `r0kh` and `r1kh` entry holds a shared key, so both lists are write-only, a read reports
  `has_r0kh` and `has_r1kh`, and a PUT that leaves them out keeps them, as it keeps `key`.
  wifi-scripts writes `nasid`, `mobility_domain`, `r1_key_holder`, `r0kh` and `r1kh` into
  hostapd's config as lines, so a write refuses a newline in them and a value or an entry over 1024
  bytes. It refuses a `nasid` over 48 bytes with fast transition, and over 253 bytes, the RADIUS
  limit of NAS-Identifier, on an EAP access point. It refuses a `mobility_domain` other than 4 hex
  digits, an `r1_key_holder` other than 12, and an entry that hostapd cannot parse while hostapd
  reads the key holder lists, which it does with owe too. hostapd refuses its whole config for any
  of these three. hostapd needs the form of `mobility_domain` only with 802.11r. With `fils`, which
  uapi does not model, wifi-scripts also gives the value to hostapd as the EAP domain of an access
  point, which takes any form, so a newline or a length in it counts there too, and its form does
  not (#273). It refuses `ieee80211r` with owe on an access point: owe gets no fast transition, and
  wifi-scripts reports the setup as failed unless both key holder lists are set. wifi-scripts stops
  the setup of the radio, with all its SSIDs, for a `reassociation_deadline` outside 1000 to 65535
  on any enabled SSID that it sets up, so a write refuses such a value, and a negative
  `r0_key_lifetime`. A write is refused for such a value only when it adds the error, for example
  when it changes the field, enables the SSID or turns fast transition on. So a PUT or a JSON Patch
  that keeps a stored value passes, as a merge PATCH does. Turning the radio of the SSID on, or
  moving the SSID from a radio that is off or missing to an enabled one, is refused too. `GET
  /api/v3/diagnostics?validate=1` lists every SSID that holds such a value. The request schema
  declares the limits of `nasid` and the form of the key holder entries only for a body that
  names `mode` `ap`, because a merge PATCH that leaves `mode`
  out keeps the stored one. `reassociation_deadline` and `r0_key_lifetime` read the number that
  wifi-scripts reads from the stored text, as ucode converts it: ` 500` is 500, `0x10` is 16, a
  fraction is cut, and other text is 0, as hostapd reads it. Only the whole group keeps fast roaming
  working: with `ieee80211r` kept and the key holder lists dropped, wifi-scripts derives lists that
  the other access points do not share. `ft_psk_generate_local` reads null when unset, because
  wifi-scripts then picks it from `encryption`. A stored value other than `1`, `true`, `0` or
  `false` reads false, as wifi-scripts takes it. Other options still go with a PUT,
  such as `num_global_macaddr` on a radio and the 802.11k and 802.11v options of an SSID. Every
  radio and SSID read gains the new fields, so its ETag changes once at the upgrade, and a write
  with an `If-Match` from before the upgrade answers 412. A client that builds its PUT body from its
  own model, such as terraform-provider-uapi until it models these fields, still deletes them, so
  upgrade the provider together with uapi. (#239)

- **`503 config_missing`** answers a write into a uci package whose file under `/etc/config/`
  does not exist, and names the file. `wireless` is the common case: `wifi config` writes
  `/etc/config/wireless` only when it finds a radio. (#235)

- **A sweep error of a `validate_new()` rule has `live`.** `GET /api/v3/diagnostics?validate=1`
  lists a stored value that such a rule refuses, whether the daemon reads it yet or not.
  `live: false` says that the daemon does not read it yet, for example because the section is
  disabled, so the value breaks nothing until a write or another writer enables the section. A 422
  does not have the field. (#256)

### Changed

- **`network/interfaces` refuses a field that the proto of the interface does not take, with 422
  `conflict` naming the field.** The spec publishes which protos take each field, as `allOf` entries
  on `proto`. Before, such a write answered 200 with no effect. A static address field such as
  `ipaddrs` or `netmask` was stored on any proto and read back, but netifd ignores it outside proto
  static. Any other field, such as `hostname` on a static interface, was dropped. That tightening
  uses the carve-out in `docs/versioning.md` for payloads that produced a state no caller can rely
  on, and it fails loudly. A `null`, an empty string or an empty list for such a field is still
  accepted and stores nothing. A request is checked only for the fields that it names, so a PATCH
  that changes only `proto` succeeds, unless the section fails a check of the new proto: static
  requires an address, wireguard a private key and addresses, and ppp and pppoe take an `mtu` from
  128 to 16384 only. That PATCH now removes the options of the old proto and keeps the options that
  apply to every proto. Before, it kept the static address fields when it left proto static. With
  terraform-provider-uapi before 3.2.0, a proto switch fails with 422 when the state holds a field
  that the new proto does not take. That is always the case away from static or wireguard, and away
  from a proto that uapi does not model unless the new proto is wireguard: static requires its
  addresses, a read of the other two answers `nohostroute: false`, and only wireguard takes
  `nohostroute`. Upgrade the provider together with uapi. (#208)
- **A `network/interfaces` read omits the fields that do not apply to its proto.** Before, it
  carried the static address fields on every proto, with any value that uci stored there. A stored
  option that the proto does not take is no longer read. A PATCH keeps it and a PUT removes it, as
  LuCI removes it on save. On a proto that uapi does not model, such as `6in4`, uapi cannot know
  which options the handler reads. A read there shows the modelled options that uci stores, and
  `nohostroute` reads `false` when it is unset, as on wireguard. A PATCH that leaves `proto` out
  refuses only `broadcast_flag`. The ETag of every interface changes once at the upgrade, so a
  write with an `If-Match` from before the upgrade answers 412. The Response schema requires only
  `proto`, as in 3.1.0, which already omitted the dhcp, dhcpv6 and wireguard fields on the other
  protos, so a field that a proto does not take is absent, not removed from the schema. On proto
  dhcp, uci `broadcast` is udhcpc's flag, and 3.1.0 read it as the static broadcast address, as
  `"broadcast": "1"`. No value of it was ever a correct answer there, which is branch (a) of the
  type carve-out in `docs/versioning.md`. It now reads as `broadcast_flag`, and `broadcast` is
  absent on dhcp. That is silent for a script: `jq .broadcast` prints null, so grep scripts for
  `.broadcast` on dhcp interfaces. (#208)
- **`network/routes.table` and `network/rules.lookup` refuse 0.** netifd cannot resolve table 0
  and drops the route or rule, so such a write answered 200 with no effect. It now answers 422
  `out_of_range`. That tightening uses the carve-out in `docs/versioning.md` for payloads that
  produced a state no caller can rely on, and it fails loudly. A stored table that netifd cannot
  resolve, such as a name missing from `/etc/iproute2/rt_tables`, reads as 0 too, and the
  validation sweep reports it. Every write to that section answers 422 until the table is fixed,
  where a PUT of the read used to remove the option and move the route into the main table.
  `table` and `lookup` also declare `maximum: 4294967295`, and a larger write answers 422
  `out_of_range`. netifd keeps a table id in 32 bits, so a larger number named another table or
  none, under the same carve-out. (#212)

- **`network/rules` refuses a `goto` that the kernel refuses, with 422.** Beside an action other
  than goto it answers `conflict`: with lookup, netifd installs a goto rule instead, and the
  kernel refuses the rule with any other action. A goto that does not jump past `priority`
  answers `out_of_range`, because the kernel answers "Backward goto not supported", for
  `goto 0` too. That tightening uses the carve-out in `docs/versioning.md` for payloads that
  produced a state no caller can rely on, and it fails loudly. `goto 0` answered `required`
  before. The schema no longer declares `default: "lookup"` on `action`, because the default
  depends on `goto`, and `goto` gets `maximum: 2147483647`. (#218)
- **`NetworkWireguardPeersResponse.endpoint_port` declares minimum 0.** A read of 0 means a port
  name that does not resolve, a number above 65535, or a stored `'0'`, which LuCI's form allows, so
  the old minimum of 1 did not describe the read. That is branch (b) of the type carve-out in
  `docs/versioning.md`. The Request keeps minimum 1, as in 3.1.0, so a write that changes the port
  to 0 still answers 422. A write that leaves a stored 0 as it is passes, unless it enables the
  peer, or changes the host or the key of an enabled peer, because the peer then uses port 0. That
  tightening uses the carve-out in `docs/versioning.md` for payloads that produced a state no caller
  can rely on, and it fails loudly. A write that passes sets the rest of the peer in the kernel,
  which keeps its endpoint, where 3.1.0 gave the kernel port 0. (#219)
- **`network/interfaces.mtu` and `network/devices.mtu` refuse a value below 68, with 422
  `out_of_range`.** netifd applies a device mtu only from 68 up and ignores a smaller one
  without a log, so such a write answered 200 with no effect. On proto wireguard,
  `wireguard.sh` applies it itself, and below 68 the device carries no IPv4 address while
  netifd reports the interface up. That tightening uses the carve-out in `docs/versioning.md`
  for payloads that produced a state no caller can rely on, and it fails loudly. A stored
  smaller value reads as it is, `GET /diagnostics?validate=1` lists it, and every write to that
  section answers 422 until it is fixed. LuCI's device form refuses values below 576, and uapi
  follows netifd. Measured on OpenWrt 25.12.5: a bridge with `mtu '60'` keeps 1500 and one with
  `mtu '1400'` gets 1400, and a wireguard interface with `mtu '60'` gets MTU 60 and no IPv4
  address. (#220)

- **`network/interfaces.mtu` takes 128 to 16384 on proto ppp and pppoe.** `ppp.sh` passes the
  value to pppd, which refuses anything outside that range. uapi 3.1.0 accepted 0 to 65535
  there, so such a write answered 200 and the link never came up. A write outside the range now
  answers 422 `out_of_range`. That tightening uses the carve-out in `docs/versioning.md` for
  payloads that produced a state no caller can rely on, and it fails loudly. LuCI's ppp and pppoe
  forms accept any value up to 9200, 0 to 127 included. Measured on OpenWrt 25.12.5: pppoe with
  `mtu '100'` logs "mtu value must be between 128 and 16384", and netifd disables the interface
  with `OPTION_ERROR`, without retrying. (#224)
- **`NetworkInterfacesResponse.listen_port` declares minimum -1.** -1 is what a port name that does
  not resolve reads, since 0 asks the kernel to pick a port, and wg then cannot bring the interface
  up. The old minimum of 0 did not describe the read either: a hand-written
  `option listen_port '-1'` already read -1, and `'65536'` read 65536 above the maximum. That is
  branch (b) of the type carve-out in `docs/versioning.md`. The Request keeps minimum 0, as in
  3.1.0, so a write of -1 answers 422. LuCI writes only 0 to 65535, so only a hand edit or another
  tool reaches -1. A write that brings up an interface that stores such a value, by a switch to
  wireguard or by enabling it, also answers 422, which uses the tightening carve-out for payloads
  that produced a state no caller can rely on, and fails loudly. A PATCH that leaves the value as it
  is passes. A switch from a proto whose read does not show `listen_port`, such as static, is
  checked too (#272). (#225)
- **Request schemas declare the bounds that a write accepts, and Response schemas keep the bounds
  of a read.** A request inherited the read bounds, so it declared values that every write
  refuses. `NetworkInterfacesRequest.mtu` now starts at 68, or takes 128 to 16384 on proto `ppp`
  and `pppoe`. `NetworkDevicesRequest.mtu` starts at 68. `table` on `network/routes`, and
  `lookup` and `goto` on `network/rules` start at 1. The `name` of `firewall/rules`,
  `firewall/nat` and `firewall/redirects` takes at most 122 characters. The limit counts bytes,
  so that bound is exact only for an ASCII name. No request changes acceptance, because
  `validate()` already refused each of these values. The module marker is
  `x-uapi-write`, described in `docs/versioning.md`, and `GET /schema/<package>/<resource>`
  serves it as the module declares it: on `network/interfaces`, the enum of `proto` is now under
  `x-uapi-write`. (#229)
- **`FirewallNatRequest.match.device` declares at most 15 characters.** A write refused a longer
  name with 422 `out_of_range`, because nftables caps an interface name at 15 bytes, while the
  request schema declared no limit. The limit counts bytes, so the bound is exact only for an
  ASCII name. No request changes acceptance. `x-uapi-write` now applies to a nested property as
  well, and to an array element under `items`. (#232)

- **A raw write removes an option for `null` and `""`, as for `[]`.** uci removes an option set to
  `""`, LuCI does the same for both, and a raw PATCH merges as RFC 7396 says, where `null` removes
  a member. Before, `""` removed the option while the response still showed it, and `null` answered
  200 and stored nothing. (#237)
- **A raw write answers with the section as uci stores it, as a GET reads it.** Before, it echoed
  the request: `true` where uci stored `"1"`, a number where uci stored text, and `[]` for an
  option that the write had removed. (#237)
- **A raw PUT or PATCH refuses a `.type` or an `id` that differs from the section, with 422
  `read_only`.** Before, it answered 200 and changed neither. An echo of the values of the section
  still passes. That tightening uses the carve-out in `docs/versioning.md` for payloads that
  produced a state no caller can rely on, and it fails loudly. (#237)
- **`/diagnostics` keeps the first 512 bytes of each error message**, and ends a cut message with
  `...`. The 400 for a control character in a request body names the key, and it answers before
  authentication, so without a limit any client could store a body of any size in the error ring,
  which lives in RAM. The response itself still carries the whole message. (#242)
- **The response schemas of the curated resources declare no `pattern`.** A read returns a value as
  uci holds it, and uci, LuCI or uapi 3.1.0 can store a value that breaks a pattern, so a GET
  answered a body that failed its own schema. For example, a section with
  `option clientid '01-23-45'` read back a `clientid` outside the declared `^[0-9A-Fa-f:]*$`. The
  request schemas keep every pattern, and the server checks a write as before. That is branch (b)
  of the type carve-out in `docs/versioning.md`. It only widens the response schemas, so no read
  that passed before fails now. (#256)

- **WireGuard keys must be keys that wg accepts.** A key is 32 bytes, so the last base64 character
  before `=` carries 2 bits that must be zero, and wg refuses a key in which they are not. uapi took
  any 43 base64 characters and `=`. So such a peer key answered 500 from `wg set` on an up
  interface, and any such key answered 200 otherwise, and then the tunnel did not come up at the
  next ifup. `public_key` and `preshared_key` of `network/wireguard_peers`, and `private_key` of
  `network/interfaces`, now answer 422 `invalid_format` for such a key. That tightening uses the
  carve-out in `docs/versioning.md` for payloads that produced a state no caller can rely on, and
  it fails loudly. The two peer keys declare the pattern `^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$`.
  A key from `wg genkey`, `wg pubkey` or `wg genpsk` always matches it. LuCI's form takes the other
  keys too, and wg then refuses them. A write carries a stored `private_key` forward, so an
  interface that stores such a key answers 422 to every write until a write sends a new key, as it
  did in 3.1.0 for a key outside the old pattern, and `GET /api/v3/diagnostics?validate=1` lists
  it. The same holds for a PUT of a peer that stores such a `preshared_key`. (#253)
- **`network/wireguard_peers.endpoint_host` refuses a `#`, and a colon outside an IPv6 address.**
  wg cuts its config line at `#`, so it finds no port. wireguard.sh puts brackets around every
  host with a colon, and wg reads a host in brackets only as an IPv6 address. Such a host made wg
  refuse the whole config at ifup, and `wg set` refuse the peer on an up interface, which answered
  500. An IPv6 address can end in a `%zone`, and whitespace around the host is ignored, as wg
  ignores it. As for the escapes of #247, a write is refused for such a host when it changes the
  host or enables the peer, and `GET /api/v3/diagnostics?validate=1` lists a peer that stores one.
  That tightening uses the carve-out in `docs/versioning.md` for payloads that produced a state no
  caller can rely on, and it fails loudly. LuCI takes only a host name or an address without a
  zone. (#253)
- **A WireGuard peer that routes its allowed IPs refuses a prefix length with a leading zero, such
  as `/010`.** netifd and `ip route` read the length in base 0, and wg reads it in base 10. So
  `fd00::/010` gave a route for `/8` to a peer that wg gave `/10`, and netifd installed no route for
  `/08`. `/00` to `/07` read the same in both and stay accepted. A write that sets such a prefix is
  refused, also when `route_allowed_ips` is off, because another writer can turn it on. A write
  that leaves a stored one as it is is refused only when it turns `route_allowed_ips` on or enables
  the peer, and the validation sweep lists the peer. That tightening uses the carve-out in
  `docs/versioning.md` for payloads that produced a state no caller can rely on, and it fails
  loudly. LuCI takes such a length. (#253)
- **`network/wireguard_peers.persistent_keepalive` reads -1 when wg cannot read the stored value,
  and `NetworkWireguardPeersResponse.persistent_keepalive` declares minimum -1.** wireguard.sh gives
  the stored text to wg, which cuts it at `#`, removes whitespace, and takes `off` or a decimal from
  0 to 65535. uapi read `off` and `25x` as null, and the apply then gave the kernel 0, while wg
  refused `25x` at ifup and failed the whole tunnel. Such a value now reads -1, and `off` reads 0.
  The old minimum of 0 did not describe the read: a hand-written `'-1'` already read -1, and
  `'65536'` read 65536 above the maximum. That is branch (b) of the type carve-out in
  `docs/versioning.md`. A stored `'off'` now reads 0 instead of null, which is silent for a script.
  The Request keeps minimum 0, so a write that changes the keepalive to -1 answers 422. A write that
  leaves such a stored value as it is passes, and a PUT of the read stores -1, which wg refuses as
  it refuses the stored value. A write that enables the peer answers 422 for it, which uses the
  carve-out for payloads that produced a state no caller can rely on, and fails loudly.
  `GET /api/v3/diagnostics?validate=1` lists the peer. The kernel apply of a write and the restore
  after a failed write set such a peer, and leave its keepalive as the kernel holds it, so the peers
  after it in uci are set too. LuCI's form takes a decimal such as `25.5`, which wg refuses. (#253)
- **`dhcp/dnsmasq` and `dhcp/servers` refuse a double quote and a `#` after whitespace, with 422
  `invalid_format`.** The init script copies these values into dnsmasq's config without quotes.
  There, a double quote opens a string. When the string does not close, dnsmasq refuses to start,
  so DHCP and DNS stopped on the whole router after a write that answered 200. A `#` after
  whitespace starts a comment, so dnsmasq used only the start of the value. `domain`, `local`,
  `server` and `address` of `dhcp/dnsmasq`, and `domain` of `dhcp/servers`, now refuse both. A
  `#` after another character stays valid, as in `/#/` or `1.2.3.4#53`. `leasefile` and
  `resolvfile` refuse a double quote too. `dhcp_option` of `dhcp/servers` takes a quoted string
  with backslash escapes, as dnsmasq does. It refuses a string that does not close, a string
  right after another string, and a `#` after whitespace or right after a string. That tightening
  uses the carve-out in `docs/versioning.md` for payloads that produced a state no caller can
  rely on, and it fails loudly. No value in the uci configs of the OpenWrt feeds is refused.
  (#254)
- **`lldpd/config` refuses a backslash in `lldp_description` and `lldp_mgmt_ip`, and a quote,
  whitespace, a backslash or a `#` in an `interface` entry, with 422 `invalid_format`.**
  lldpd.init writes these values on lldpcli command lines. lldpcli reads a backslash as an escape,
  also between quotes, so it removed a backslash from the value. After a final backslash, the
  quote stays open, and lldpcli skips the line. lldpd then used its default description or
  management address, while a read showed the stored value. The init writes `interface` without
  quotes, where lldpcli also reads a quote and a `#` as syntax. The shell splits an entry at
  whitespace into two entries. When lldpcli skips that line, lldpd listens on every interface. A
  single quote and a `#` stay valid in the two quoted fields. This reading of lldpcli comes from
  the lldpd 1.0.20 source, which OpenWrt 25.12 ships. That tightening uses the carve-out in
  `docs/versioning.md` for payloads that produced a state no caller can rely on, and it fails
  loudly. No value in the uci configs of the OpenWrt feeds is refused. The read of an `interface`
  that uci holds as one option, such as `option interface 'loopback lan'`, changes from one entry to
  its words, as the init splits it and LuCI shows it (#274). Read as one entry, as 3.1.0 read it,
  the option would break the new pattern and make a JSON Patch of any field, or a merge PATCH of the
  read, answer 422. (#254)
- **`snmpd/accesses` refuses an access without `context`, `version`, `level`, `prefix`, `read`,
  `write` or `notify`, with 422 `required`.** snmpd.init skips an access that does not set each
  of these, so such a write answered 200 and snmpd did not use the access. The init tests
  `context` without quotes, so an empty `context` passes the test. The init then writes an
  access line with a word missing, which snmpd drops. The 422 for `context` says to use `none`,
  which the init writes as the empty context. `context` also refuses `*`, `?` and `[`, because
  the same test expands them to file names, and fails when several names match. LuCI writes no
  `context` unless the operator types one, and uapi 3.1.0 required only `group`. A write to an
  access that lacks one of these fields is refused only when it changes that field and leaves it
  empty, as for the key in #246. `GET /api/v3/diagnostics?validate=1` lists the access. That
  tightening uses the carve-out in `docs/versioning.md` for payloads that produced a state no
  caller can rely on, and it fails loudly. The stock snmpd config sets all eight fields. (#254)
- **`wireless/interfaces.ssid` takes at most 32 bytes.** hostapd and wpa_supplicant refuse a
  longer SSID in their config, so such a write answered 200, and the SSID did not come up in mode
  ap, sta or adhoc. A write that sends one now answers 422 `out_of_range` in every mode, as LuCI
  refuses it. uapi counts bytes, so a non-ASCII character counts for more than one. The
  `maxLength` of `WirelessInterfacesRequest.ssid` counts characters, so it is exact only for an
  ASCII SSID. A write that leaves a stored SSID as it is is refused for its length only when it
  enables the SSID or moves it into mode ap, sta or adhoc, and `GET
  /api/v3/diagnostics?validate=1` lists it. That tightening uses the carve-out in
  `docs/versioning.md` for payloads that produced a state no caller can rely on, and it fails
  loudly. (#255)
- **`wireless/interfaces.key` refuses a key that the daemons refuse or misread.** This applies
  with `psk`, `psk2`, `psk-mixed`, `sae` and `sae-mixed`, with or without a forced cipher. In mode
  ap, wifi-scripts gives hostapd a key of 8 to 63 bytes as a passphrase and one of 64 bytes as a
  PSK, which hostapd takes only as hex digits, and no key for another length. With plain `sae`, a
  PSK leaves SAE without a password. In mode sta and adhoc, wifi-scripts gives wpa_supplicant every
  key as a passphrase between double quotes. wpa_supplicant refuses a passphrase that is not 8 to
  63 bytes or that holds a control character, except with plain `sae`, so a key of 64 hex digits
  fails there. The shell variant of wifi-scripts gave such a key as a PSK. In mode sta, adhoc and
  mesh, wpa_supplicant reads a `#` after an odd number of double quotes as the start of a comment.
  A write that sends such a key now answers 422 `out_of_range`, `invalid_format` or `conflict`, and
  no message quotes the key. A write that leaves a stored key as it is is refused for it only when
  it enables the SSID or changes its mode or encryption, and `GET /api/v3/diagnostics?validate=1`
  lists it. LuCI takes 8 to 63 characters or 64 hex digits in every mode, and counts characters,
  where uapi counts bytes as the daemons do. That tightening uses the carve-out in
  `docs/versioning.md` for payloads that produced a state no caller can rely on, and it fails
  loudly. (#255)
- **`wireless/interfaces` refuses mode `wds` on write.** wifi-scripts sets up no interface in mode
  wds on OpenWrt 25.12, so such a write answered 200, and the SSID never came up. LuCI writes a WDS
  access point or station as mode `ap` or `sta` with option `wds`, which uapi does not model. A
  write that sends `wds` now answers 422 `not_in_enum`. A read still reports a stored `wds`, and a
  write that leaves it as it is is refused for it only when it enables the SSID.
  `WirelessInterfacesRequest.mode` drops `wds` from its enum, and the Response keeps it. That
  tightening uses the carve-out in `docs/versioning.md` for payloads that produced a state no
  caller can rely on, and it fails loudly. (#255)
- **`dhcp/servers.domain` refuses `*`, `?` and `[`, with 422 `invalid_format`.** dnsmasq.init
  splits the value into words without quotes when dnsmasq serves DHCPv6, so the shell expanded such
  a word to the names of the files in its working directory, and dnsmasq announced those as search
  domains. A domain name cannot hold these characters. That tightening uses the carve-out in
  `docs/versioning.md` for payloads that produced a state no caller can rely on, and it fails
  loudly. (#257)
- **`wireless/devices` refuses a write that turns a radio on while an enabled SSID of the radio
  holds a value that wifi-scripts or a daemon refuses, with 422 `conflict` on `disabled`.**
  wifi-scripts sets up an SSID only while the SSID and its radio are enabled, so the daemons read
  its values only then. `wireless/interfaces` refused a write that enabled an SSID with such a
  value, but not a write that turned its radio on or moved it to another radio. Such a write
  answered 200, and the daemon got the value: a key with a newline added a line to hostapd's config,
  and a `reassociation_deadline` outside 1000 to 65535 stopped the radio. A create turns the radio
  on unless it sends `disabled: true`. The message names each such SSID and its fields, and quotes
  no value. A write that leaves a radio on, or off, is not checked. A write to `wireless/interfaces`
  that moves an enabled SSID with such a value from a radio that is off or missing to an enabled one
  is refused too. A move between two enabled radios is not checked, as before. An SSID is on each
  radio that `device` names, as a list or as words, as netifd reads it, and a radio is off when its
  `disabled` is `1` or `true`, or when it has no `type` (#262). The other way round, a write to an
  SSID whose radio is off or missing is no longer refused for a stored value that it leaves as it
  is, so enabling the SSID there passes, and the validation sweep lists the value with
  `live: false`. The refusals use the carve-out in `docs/versioning.md` for payloads that produced a
  state no caller can rely on, because such a write gave wifi-scripts or a daemon a value that it
  refuses, and they fail loudly. The rest only widens what a write takes. LuCI checks no SSID when
  it turns a radio on. A radio and its SSID as `wifi config` writes them, on 2g, 5g and 6g, take the
  enable. (#260)
- **A write of `network/interfaces` that makes the stored peers of a WireGuard interface live
  refuses a peer that a peer write refuses to enable, with 422 `conflict`.** wireguard.sh gives
  every enabled peer of the interface to one `wg syncconf`, and wg refuses the whole config for one
  peer that it cannot read, so the interface stays down. A peer write checks only its own peer. So a
  write that switched an enabled interface to proto `wireguard`, enabled a wireguard interface, or
  created one under the name of stored peers answered 200, and the tunnel did not come up. Such a
  write now answers 422 on `proto`, or on `disabled` when it enables the interface. The message
  names each such peer and its fields, and no value. A peer write needs its parent on proto
  `wireguard`, so a switch can send `disabled: true`, and the interface is enabled once its peers
  are fixed or disabled. The peer rules are the ones that a write of `network/wireguard_peers`
  checks when it enables the peer: the keys, the endpoint host, the port, the keepalive, and a
  prefix length with a leading zero when the peer routes its allowed IPs, which wg takes and the
  route reads in another way, and an allowed IP that a peer write refuses (#262). A write of an
  interface that is already live on wireguard, or that stays disabled, does not check the peers, and
  neither does the validation sweep. That tightening uses the carve-out in `docs/versioning.md` for
  payloads that produced a state no caller can rely on, and it fails loudly. LuCI checks no peer
  when it switches the proto. (#261)
- **A stored `network/wireguard_peers` value that wg refuses is live only on a peer with a public
  key.** wireguard.sh writes no `[Peer]` block for a peer without a key, so wg never reads its other
  values. `GET /api/v3/diagnostics?validate=1` reports the error of such a value with `live: false`,
  and a write that sets the key answers 422 for it. A port name that does not resolve keeps a second
  error there, because a PUT of the read is refused for it. The routes of `route_allowed_ips` do not
  need the key, so a prefix length with a leading zero stays live without one. (#261)
- **A radio without a `type` counts as off, and a write that gives an enabled radio its type is
  checked as one that turns it on.** netifd sets up no SSID of a wifi-device without a type
  (`/lib/netifd/wireless.uc`, before it reads `disabled`). So a write to an SSID of such a radio is
  no longer refused for a stored value that it leaves as it is, the validation sweep lists the
  value with `live: false`, and so does the `cell_density` of such a radio. A write of
  `wireless/devices` that gives the radio a type answers 422 `conflict` on `disabled` while an
  enabled SSID of the radio holds a value that wifi-scripts or a daemon refuses, as a write that
  enables the radio does. That uses the same carve-out as the refusal of #260, and the rest only
  widens what a write takes. (#262)
- **A write of `network/interfaces` that makes the stored peers of a WireGuard interface live also
  refuses a peer with an allowed IP that a peer write refuses.** wg refuses the whole config for an
  allowed IP that it cannot parse, as for the other peer rules of #261, and a peer write refuses
  such a value, and a few forms that wg takes, such as a prefix length of three digits, on every
  write. The rule counts only on an enabled peer with a public key, because wireguard.sh gives wg no
  other peer. That uses the tightening carve-out of #261. (#262)
- **The uapi release APK installs `openapi.json` without whitespace**, and so does the test VM of
  the integration suite. `main.uc` reads the installed file whole into the request process that
  serves `GET /api/v3/openapi.json`, and uhttpd sends it uncompressed, so its size is paid in memory
  and on the wire. The file shrinks by about 30%, from 949,429 to 668,736 bytes for the spec at this
  change. The served document is the same JSON value, with its keys in the same order, so a client
  that parses it sees no change. A script that matches its text, such as a `grep` for
  `"version": "`, has to match without the space. The uapi package of the OpenWrt packages feed
  copies `build/openapi.json` from the release tarball, so it installs the indented file until its
  Makefile runs `tools/compact_json.py`. `make stage` now needs `python3`, which the OpenWrt SDK
  requires on the host too, and fails unless the installed copy parses to the same value as
  `build/openapi.json`, which stays indented in the repository. (#264)
- **A PATCH that switches an enabled `network/interfaces` to proto `wireguard` refuses a
  hand-written `listen_port` that does not resolve, with 422 `conflict` on `listen_port`.** The read
  of a proto that takes no `listen_port`, such as `static`, does not show the option, and a PATCH
  keeps an option that it leaves out, so the check of #225 could not see a value such as
  `nosuchservice` that a hand edit left there. wireguard.sh wrote it after `ListenPort=`, wg refused
  it, and the interface did not come up, while the PATCH answered 200. Such a PATCH now passes when
  it names `listen_port`: a port, a `null`, which now removes the option, or the `remove` of a JSON
  Patch. A `null` removed nothing before, because a PATCH deletes only the options that the read of
  the old proto shows. A switch with `disabled: true` passes too, and a write that sends a port or
  `null` can then enable the interface. A PUT removes every option that it does not write, so the
  check does not apply to it. That tightening uses the carve-out in `docs/versioning.md` for
  payloads that produced a state no caller can rely on, and it fails loudly. LuCI saves such a
  switch, and its wireguard form refuses the value at the next save, so uapi refuses earlier, at the
  write that makes wg fail. No stock `/etc/config/network` holds a `listen_port`. (#272)

### Deprecated

- **`network/interfaces.ip6prefix` as a string on write.** v4 removes it, so send an array. The
  row is in `docs/deprecations.md`, and the "Upcoming in v4" block of the spec announces it.
  (#217)

### Fixed

- **`wireless/interfaces.encryption` accepts a forced cipher, such as `psk2+ccmp`.** LuCI appends
  the cipher when one is chosen, and wifi-scripts reads the suffix. A read of such an SSID answered
  a value outside the declared enum, and a PUT of the read answered 422 `not_in_enum`, so the SSID
  could not be updated with PUT at all. The enum now takes each of its modes that LuCI offers a
  cipher for, followed by `+` and one of the ciphers that wifi-scripts parses, `aes` spellings
  included. These are new enum values. That is branch (b) of the type carve-out in
  `docs/versioning.md`: the server broke its declared enum for every SSID whose cipher LuCI forced.
  No read changes, so nothing fails: a client that validated such a read failed before and now
  passes. A key is required with a forced cipher as without one. That fixes a PSK or SAE SSID. An
  EAP SSID, with `wpa`, `wpa2`, `wpa3` or `wpa3-mixed`, still cannot be updated with PUT: LuCI
  removes its `key`, and uapi requires one. LuCI's `wpa-mixed` and `wpa3-192` are not in the enum
  yet, with or without a cipher. (#239)
- **`network/interfaces.ip6hint` and `ip6ifaceid` now apply to every proto, as netifd reads
  them.** They were read and written only for proto `dhcpv6`. On a static interface, which is where
  they matter, a write answered 200 and stored nothing, so no caller could choose which /64 an
  interface gets, and a PUT erased a value that LuCI had written. They are now checked the way
  netifd parses them, as LuCI does: `ip6hint` as a hexadecimal subnet id below `0xffffffff`, and
  `ip6ifaceid` as `eui64`, `random` or an interface id whose network half is zero. This refuses with
  422 a prefix-form `ip6hint` such as `2001:db8::/56`, which netifd read as subnet `0x2001`, and an
  `ip6ifaceid` that has a network part or is not an address, which netifd replaced with `::1`. That
  tightening uses the carve-out in `docs/versioning.md` for payloads that produced a state no
  caller can rely on, and it fails loudly: an interface that already stores such a value answers
  422 to every write, naming the field, until the value is corrected or cleared, for example with
  `"ip6hint": ""`. 3.1.0 accepted only the prefix form, on dhcpv6, so this is the case for every
  `ip6hint` that uapi 3.1.0 wrote. An empty string still clears either option, and `ip6ifaceid`
  now also accepts `eui64` and `random`, which it refused. (#206)
- **`network/interfaces` reads and writes the options that netifd takes on every proto, on every
  proto.** `metric`, `defaultroute`, `delegate`, `ip4table` and `ip6table` each applied to some
  protos only: `metric` not to static, and `ip4table` not to dhcp. On the other protos, a write
  answered 200 and stored nothing, and a PUT erased a value that LuCI wrote. The same was true of
  `peerdns` on `pppoe`, `ppp` and `wwan`, of `reqprefix` on `pppoe` and `ppp`, and of `clientid` on
  `dhcpv6`, where it is a DUID. Measured on OpenWrt 25.12.5: `metric` and `ip4table` on a static
  interface put its routes into that table with that metric. (#208)
- **`network/interfaces.listen_port` is declared nullable.** A wireguard interface without
  `option listen_port` reads it as null, because the kernel then picks the port, and the spec
  declared an integer. That uses branch (b) of the type carve-out in `docs/versioning.md`: the
  server broke its declared type for every such interface. No read changes, because the value was
  already null. (#208)
- **`network/interfaces` reads integers and lists as netifd reads them.** uci hands netifd an
  integer option through `strtol` with base 0. uapi read decimals only, so `metric '0x10'`, which
  netifd applies as 16, read null, and `ip6assign '010'`, which netifd takes as 8, read 10. A
  scalar `dns`, `ipaddr`, `ip6addr` or wireguard `addresses` with several words read as one entry,
  while netifd, and the wireguard script for `addresses`, use each word. For example, `option dns '192.0.2.1 192.0.2.2'` is two servers, and
  a PUT of the old read of a scalar `ipaddr` with two addresses answered 422. `metric`,
  `ip6assign`, `ip6weight` and `mtu` now read hex and octal, and the lists read as their words.
  An empty string reads null, as before. A value past int32 now reads null too, because netifd
  truncates it differently on 32- and 64-bit targets. Measured on OpenWrt 25.12.5:
  `metric '0x10'` gives routes with metric 16, `mtu '0x578'` on wireguard gives mtu 1400, and
  `metric '16 '` gives routes without a metric, which uapi reads as null. (#209)
- **`network/routes` and `network/rules` read a table name as its id.** netifd resolves `table`
  and `lookup` as a number, as one of the aliases `default`, `main` and `local`, or as a name in
  `/etc/iproute2/rt_tables`, and LuCI writes the name. uapi read decimals only, so a name read
  null. A rule with `lookup 'main'` answered 422 "is required" to every write, and a PUT of the
  read of a route with a named table removed the option and moved the route into the main
  table. A name now reads as its id, a PUT of the read writes the id, and a PATCH keeps the
  stored name. Writing a name waits for the next major. (#212)
- **`network/routes`, `rules`, `devices`, `bridge_vlans` and `wireguard_peers` read integers and
  lists as netifd and `wireguard.sh` read them**, as #209 did for `network/interfaces`. Route
  `metric` and `mtu`, rule `priority` and `goto`, device `mtu` and bridge-vlan `vlan` now read
  hex and octal. A scalar `ports` on a device or a bridge-vlan, and a scalar `allowed_ips` on a
  peer, now read as their words. Before, a PUT of the read of a bridge with
  `option ports 'eth0 eth1'` wrote one port named `eth0 eth1`, which netifd cannot find, so the
  bridge lost both ports. A peer with a scalar `allowed_ips` of several prefixes answered 422 to
  every write, and uapi's own apply took the whole string as one prefix, so a DELETE did not
  withdraw the routes of the peer. The management-path guard splits a scalar `ports` too. The
  ETag of each affected section changes once. Measured on OpenWrt 25.12.5: `table 'uapi55'`
  with `metric '0x10'` gives a route in that table with metric 16, `table '0'` gives no route,
  a scalar `ports` with two names gives two bridge members, and a scalar `allowed_ips` with two
  prefixes gives two routes, which a DELETE withdraws. (#212)
- **`network/interfaces.ip6prefix` reads as an array, the list that netifd reads.** netifd's
  static proto, `dhcpv6.sh`, `wireguard.sh` and `6in4.sh` read `ip6prefix` as a list, and
  LuCI's wireguard and 6in4 forms write `list ip6prefix`, even for one prefix. uapi declared a
  string, so such a section read as an array that broke the declared type. A PUT of that read
  answered 422 `invalid_type`, every merge-PATCH of the section answered 422 `invalid_format`,
  even `{"auto": false}`, and `GET /diagnostics?validate=1` flagged it. A read is now always an
  array, also for a stored scalar, which netifd reads the same way. **Carve-out
  (`docs/versioning.md`, branch b): a response type changed in a minor, because the server
  violated its own declared `["string", "null"]` for every section that stores
  `list ip6prefix`.** A static section, which LuCI writes as a scalar, read back correctly, so
  branch (a) is not claimed. The change fails loudly for a typed reader: every interface with
  `ip6prefix` now reads an array, which terraform-provider-uapi before 3.2.0 stores as text, so
  every plan shows a change for such an interface and the apply fails with an inconsistent
  result. It is silent for a script: `jq -r .ip6prefix` now prints a JSON array, so grep
  scripts for `.ip6prefix`. Writers keep working, because a string is still accepted and split
  into words, as netifd splits a stored one. One prefix is stored as a scalar and several as a
  list, because blob.c drops a list given to a string attribute, and 6rd, map and 464xlat read
  `ip6prefix` as a string. So a PUT of the read turns LuCI's one-entry list into a scalar,
  which no reader tells apart. `option ip6prefix ''` reads null instead of `""`. The ETag of
  each interface with `ip6prefix` changes once. Measured on OpenWrt 25.12.5: two listed
  prefixes on a static interface both appear in its `ipv6-prefix` status and survive a PUT of
  the read. (#217)
- **`network/rules` goto rules reach the kernel.** netifd parses `action` with
  `system_rtn_aton`, which knows `unicast`, `unreachable`, `prohibit`, `blackhole` and `throw`
  but neither `lookup` nor `goto`, and it drops a rule whose action it cannot read. A goto rule
  is one with a `goto` and no `action`, which is what LuCI writes. uapi wrote `action 'goto'`,
  so netifd dropped every goto rule written through uapi while the write answered 200. It also
  read LuCI's goto rule as action `lookup`, so every write to it answered 422. A read now
  derives the action as netifd does, with `unicast` read as `lookup`. A write stores no action
  for lookup and goto, and clears a stored one. A rule that uapi stored before stays
  uninstalled until its next write; `uci show network | grep "action='goto'"` lists them.
  Measured on OpenWrt 25.12.5: a rule with only `goto` is installed, the same rule with
  `action 'goto'` is not, and a PATCH of it through uapi installs it. (#218)
- **The published `network/rules` conditional accepts a rule whose only selector is `mark`**, as
  `validate()` does, so a client that validates against the spec can create one. (#218)

- **Installing, upgrading or removing uapi no longer starts a uhttpd that the operator
  disabled.** The install hook reloaded uhttpd, the postinst restarted it and the prerm reloaded
  it, and on OpenWrt both `reload` and `restart` start a stopped service. On a router where
  another web server owns ports 80 and 443, that started uhttpd beside it. Each step now runs
  only when uhttpd is enabled. (#203)
- **`network/wireguard_peers.endpoint_port` reads a service name as wg resolves it.** `wireguard.sh`
  passes `endpoint_port` to `wg`, which strips whitespace and resolves a name through
  `/etc/services`, so `option endpoint_port 'https'` works on the box. uapi read such a name as
  null. A PATCH of the peer then pushed port 51820 to the kernel, and the restore after a failed
  write pushed port 0, while wireguard.sh used 443. A read now gives the port that wg uses, and both
  apply paths push it. A name that does not resolve reads 0, which wg cannot use either, and so does
  a number above 65535, which read above the declared maximum. A peer that stores such a name read
  null in 3.1.0, and a write that leaves it as it is still passes. A write that enables the peer, or
  changes the host or the key of an enabled peer, answers 422 for it, and so does a PUT of the read,
  with `conflict`, because it would store port 0, which wg takes where it cannot resolve the name.
  That tightening uses the carve-out in `docs/versioning.md` for payloads that produced a state no
  caller can rely on, and it fails loudly. `persistent_keepalive` now reads with whitespace removed,
  as wg reads it, so `'25 '` reads 25 where it read null. (#219)
- **The `network/interfaces.mtu` description says where netifd applies it.** netifd applies an
  interface's `mtu` to its device only when that device has no `config device` section of its
  own, as `br-lan` has in the stock configuration, and to every device that joins the interface
  later, such as a Wi-Fi netdev. A device with its own section takes its MTU from
  `network/devices`. Measured on OpenWrt 25.12.5: on a bridge with its own section, the
  interface's `mtu '1400'` left the bridge at 1500, a device added to the interface got 1400 and
  the bridge then dropped to 1400 with it, and a dotted VLAN without a section got the
  interface's value. (#224)
- **`network/interfaces.listen_port` reads a service name as wg resolves it.** `wireguard.sh`
  writes `ListenPort` for `wg`, which resolves a name through `/etc/services`, so
  `option listen_port 'openvpn'` makes the tunnel listen on 1194. uapi read such a name as null,
  and a PUT of the read removed the option, so the tunnel then listened on a random port. A read
  now gives the port that wg uses. A PUT of the read writes the number, which netifd sees as a
  change, so it restarts the interface once and drops the tunnel briefly. A PATCH keeps the
  stored name and restarts nothing, also for a name that does not resolve, which reads -1. A write
  that sends -1 answers 422, so a PUT of such a read is refused. netifd itself reads the option as
  an integer and does not restart the interface when it changes to a name, so a name takes effect
  at the next ifup. Measured on OpenWrt
  25.12.5: `listen_port 'openvpn'` listens on 1194 and reads 1194, and
  `listen_port 'nosuchservice'` leaves the interface down and reads -1. (#225)
- **A `network/interfaces` read of a proto that uapi does not model conforms to the Response
  schema.** LuCI writes `6in4`, `gre`, `6rd` and other tunnel protos, and a read answers them as
  stored, while `NetworkInterfacesResponse.proto` declared an enum of the eight modelled protos.
  The Response no longer declares that enum, and the Request keeps it. That uses branch (b) of the
  type carve-out in `docs/versioning.md`: the server broke its declared type for every interface
  that LuCI configured with such a proto. A POST or PUT with such a proto still answers 422
  `not_in_enum`, now with a message that names the PATCH, which keeps the options of the proto's
  handler. A JSON Patch on such an interface now succeeds, as a merge patch already did. Before,
  it answered 422. No read changes, so nothing fails: a client that validated the read failed on
  such an interface and now passes. (#229)
- **A `network/interfaces` PATCH no longer writes `nohostroute '0'` when it does not name the
  field.** A PATCH skips a field whose value is the default, but it took the defaults from an
  empty section, read as proto `none`, where `nohostroute` does not apply. So every PATCH of a
  wireguard interface added `nohostroute '0'`. The value had no effect, but the section changed
  on a write that did not ask for it. A PATCH of any resource now takes the defaults from the
  section as the write leaves it. A PUT still writes `nohostroute '0'`, as it writes `auto '1'`
  and `disabled '0'`, because a PUT writes every field of the body. (#230)

- **A write into a uci package without a config file answered 200 and stored nothing.** The uci
  cursor stores nothing in a missing file and reports it only through a null return, which uapi
  ignored. On a router without a radio, `POST /wireless/devices` and `POST /wireless/interfaces`
  answered 200 with an `id` that a GET then answered 404 for, and a raw POST to a package without a
  file did the same. Such a write now answers `503 config_missing` before any uci write. That
  tightening uses the carve-out in `docs/versioning.md` for payloads that produced a state no
  caller can rely on, and it fails loudly. A PUT, PATCH or DELETE of a curated id there answers the
  same 503 where it answered 404, as with `init_script_missing`. The raw ones still answer 404,
  because they look up the section first. A uci set, rename or commit that the cursor refuses now
  answers 500 instead of 200, and a raw write whose reload service is not installed answers `503
  init_script_missing` instead of a 500 that named an unknown kind. (#235)

- **A raw write of an option that uci cannot store answered 200 and stored nothing, or only part of
  it.** The cursor drops an option name outside letters, digits and `_` and still returns true. It
  refuses an object, and from a list that holds a null, an object or another list it stores only
  some of the items. Such an option, and a `.type` outside printable ASCII on create, such as one
  with a space, now answers 422 under the same carve-out. (#235)

- **A request body with a NUL or a control character answered 200 and stored something else.** uci
  drops a value with a control character other than tab, newline and carriage return when it replays
  the commit, and a NUL cuts the value short. A NUL also cut the check of an id short, so
  `"n1\u0000-x"` passed the section-name charset and created section `n1`. Such a body now answers
  `400 bad_request` on every endpoint. The message names the field that holds a control character,
  but not the one that holds a NUL, because `json()` cuts an object key at its first NUL. That
  tightening uses the carve-out in `docs/versioning.md` for payloads that produced a state no caller
  can rely on, and it fails loudly. A field check that refused such a byte with 422 before, such as
  `system/password`, the `name` of `dhcp/hosts` or the enum of `firewall/rules.target`, now answers
  400 instead. A tab, a newline, a carriage return and DEL still reach the field checks, because uci
  stores them, and a check that refuses them still answers 422. (#237)
- **A raw POST without an `id` answered 500 for a type that does not start with a lowercase
  letter**, such as `LoadPlugin` in olsrd. The generated id now takes the first letter of the type
  in lowercase, or `u`. (#237)
- **A raw read showed a stored `option id` as the section id**, as in a zerotier `network` section,
  and a PUT of that read deleted the option. `id` is now always the section name, and a PUT keeps
  the option. (#237)
- **A raw write stored `reloaded`, `reload_services` and `reload_note` as options when a client
  sent a write response back.** They are now ignored, as `managed` is. (#237)
- **A raw POST with an `id` of `0` or `false` got a generated id.** It now answers 422, as another
  id outside the section-name charset does. That tightening uses the carve-out in
  `docs/versioning.md` for payloads that produced a state no caller can rely on, and it fails
  loudly. (#237)
- **A raw list of several items that starts with `""` answered 200 and stored the list without
  that item.** The uci binding drops a leading empty item. Such a list now answers 422 and names
  the item, such as `server[0]`. A list of one `""` still passes, so the one-item placeholders in
  the stock aria2, dufs and dnsproxy configs read and write back unchanged. That tightening uses
  the carve-out in `docs/versioning.md` for payloads that produced a state no caller can rely on,
  and it fails loudly. (#237)
- **A raw 422 named only the first refused field.** It now lists every refused field, as
  `docs/errors.md` says, and names a list item by its index, such as `proto[1]`. (#237)
- **The spec declared any raw request body.** `RawSectionRequest` now declares the option names,
  the values and the `.type` that a raw write takes. (#237)
- **A write read the package as it was before uapi took the lock.** The read that checks the
  target and the scope loads the package into uapi's uci cursor, and the cursor served every later
  read of the write from that copy. A commit by LuCI or a shell in the milliseconds before the lock
  was then invisible to the write: a PUT kept an option that the commit had added, and the
  response showed a section that uci did not store. The commit itself merged both, so no change
  was lost. The transaction now drops the package from the cursor once it holds the lock, for
  every write and for `/batch`. A raw write also checks again that the section has the type that
  the scope check approved, and answers 404 when another section took the name in between, where
  it wrote its body into that section. (#242)
- **A path that names a section by position, such as `@zone[0]` or `@[-1]`, answered with the
  position as its `id`.** uci resolves the position, and uapi put the text of the path in place of
  the section name, on raw, on the curated resources and on `/tokens`. `id` is now the section
  name, and a write by position acts on that section. A curated PUT by position no longer refuses
  a unique field, such as the `name` of a firewall zone or the `ip` of a DHCP host, as taken by the
  section itself, and a token revoked by position no longer leaves its rate-limit bucket. (#242)
- **A raw PATCH removes the reload fields that a write stored as options before 3.2.0**, as it
  removes a stored `managed`. Only a PUT removed them, and a write response showed a stored
  `reload_note` next to a fresh `reloaded`. (#242)
- **The DELETE of a WireGuard peer works on an up interface when uci holds its `public_key` as a
  list, with whitespace, or not as a WireGuard key at all.** uapi refused to give such a value to
  `wg set ... remove`, so the DELETE answered 500, and so did a write that replaced the key or
  disabled the peer. uapi now removes the peer under the key that wg read from the config of
  wireguard.sh, which joins a list with spaces, and of which wg reads the first line without
  whitespace or a comment. When that is not a WireGuard key, the kernel holds no such peer, and uapi
  removes nothing. A key with a backslash, which wireguard.sh expands, still answers 500. (#247)
- **A stored WireGuard key with whitespace or a comment, which wg reads, no longer blocks its
  peer.** wireguard.sh writes the key on a line of the config for wg, and wg removes whitespace and
  a `#` comment from the line. uapi checked the text as uci holds it, so a write that enabled such
  a peer answered 422, and on an up interface every write of the peer answered 500. uapi now reads
  a stored key as wg does in each place: the check, the apply, the restore after a failed write,
  and the test that tells whether a write changes the key. So the restore no longer removes a peer
  whose key uci holds as a list, and a PUT that sends the same key no longer removes and sets the
  peer again, which cut its tunnel. (#253)
- **A WireGuard peer reads `endpoint_host`, `disabled` and `route_allowed_ips` that uci holds as a
  list as wireguard.sh reads them**, as one value of its items joined with spaces. A list `disabled`
  or `route_allowed_ips` read as unset, so a peer that wireguard.sh skips read as enabled, and a
  write put it into the kernel. Such a value now reads as wireguard.sh reads it, which is silent for
  a script. A list `endpoint_host` read as an array, outside the declared type, and reached `wg set`
  as JSON text, so every write of the peer on an up interface answered 500. It now reads as a
  string, which is branch (b) of the type carve-out in `docs/versioning.md`. A typed reader failed
  on the old read and passes now. uapi also removes whitespace from the host before it runs `wg
  set`, as wg does with the config of wireguard.sh. (#253)
- **The routes of `route_allowed_ips` are compared as netifd installs them.** uapi compared
  prefixes as text. A PUT that changed the spelling of a prefix, such as `FD00::/64` to
  `fd00::/64`, deleted the route that it had just installed, and the restore after a failed write
  deleted each route that uci spells in another way than the kernel prints it. A stored prefix
  length of 3 or more digits, such as `/0064`, was not read, so a DELETE left its route. An IPv4
  prefix with host bits, such as `10.0.0.1/24`, answered 500 on an up interface, because `ip
  route` refuses it. uapi now reads the length in base 0 and masks the address, as netifd does,
  compares routes in that spelling, and gives `ip route` the masked prefix. (#253)
- **Removing a WireGuard peer no longer drops another peer section with the same key from the
  kernel.** The kernel holds one peer per key. The DELETE, the disable or the key change of one
  section removed the peer that another enabled section of the interface also set, and that
  section stayed out of the kernel until the next ifup. uapi now sets each such section again, in
  uci order, so the last one wins, as at ifup. (#253)
- **A create or a PUT of `wireless/interfaces` that sends no `mode` stores mode `ap`.** A read
  reports `ap` for a section with no mode, but a create stored no mode, and a PUT removed the
  stored one. wifi-scripts sets up no interface for a section with no mode, so the SSID never came
  up while every read showed an access point. A PATCH writes only what it changes, so a section
  that a hand edit left without a mode keeps none until a write sends `mode`, and its read still
  reports `ap`. (#255)
- **`network/interfaces` answers 422 for an `ipaddrs` or `ip6addrs` sent as a string.** It
  answered 500, because `validate()` read the string as a list. (#256)
- **A PUT or a JSON Patch no longer type-checks a write-only value that the caller did not send.**
  A write keeps a masked secret from uci, and uci can hold it in a shape that the schema does not
  declare, such as a WireGuard `preshared_key` that uci holds as a list, which wireguard.sh reads
  as one key. The schema check refused it with 422 `invalid_type`, so a PUT of the read failed.
  The schema check now covers what the caller sent, and the validation sweep no longer reports the
  shape. `validate()` still checks each secret, and refuses one that the daemon cannot use. (#256)
- **`dhcp/servers.domain` reads a list as one string, its entries joined with spaces.** LuCI stores
  the search domains as a list. A read answered an array where the schema declares a string, so a
  PUT of the read answered 422 `invalid_type`. dnsmasq.init and odhcpd both take the words of the
  value, so the joined string is what they use, and a PUT of it keeps them. That is branch (b) of
  the type carve-out in `docs/versioning.md`: the server broke its declared type for every
  interface whose search domains LuCI set. (#257)
- **`wireless/devices` reads `radio`, `channel`, `txpower` and `cell_density` as wifi-scripts reads
  them.** netifd converts `radio`, `txpower` and `cell_density` with ucode's `+v`, and mac80211.sh
  converts `channel` the same way. `+v` takes whitespace, a `0x` prefix and a fraction, and gives
  NaN for other text, which uapi reads as 0. uapi read only plain decimal digits, so a stored ` 6`
  read null, and a PUT of the read removed the channel that the radio used. A write still refuses
  a value outside the range, but the Response no longer declares the range, because a read can
  give a stored value outside it, such as `txpower '0x40'`. That is branch (b) of the type
  carve-out in `docs/versioning.md`. A write that leaves such a stored value as it is now passes,
  and so does a write that enables the radio, except for a `cell_density` outside 0 to 3, for
  which wifi-scripts stops the radio. A write takes a channel up to 233, where it refused one above
  196, so the 6 GHz channels that LuCI offers can be written. (#257)
- **The descriptions of `unbound/srv.srv_line` and `unbound/ext.ext_line` no longer say that
  `unbound-checkconf` checks the lines.** Nothing runs it. unbound parses the lines when it
  restarts, and a line that it cannot parse makes it refuse its whole config. (#257)
- **A write that makes unbound stop answers `500 reload_failed_restored` and restores the previous
  config.** procd starts unbound with its new config on its own, so the init script exited 0, and
  unbound then exited on a `srv_line` or `ext_line` that it cannot parse. DNS stayed down while the
  write answered 200. When unbound runs, a write that reloads `unbound` or `unbound-uci-ext` now
  waits 2 s for each unbound instance to keep running. The restore runs the same check, so a
  restore that does not bring unbound back answers `reload_failed_unrecovered`. This applies to
  `unbound/server`, `unbound/srv`, `unbound/ext`, a `/batch` that holds one of them, and a raw
  write to the `unbound` package. These writes take 2 s longer. A write to `unbound/srv` or
  `unbound/ext` also takes the lock of the `unbound` package, so two writes that restart unbound at
  the same time answer `423 locked` for the second, as two writes to one package do. A write that
  answered 200 and left unbound down now answers 500, which is the tightening carve-out of
  `docs/versioning.md`. (#259)
- **A PATCH body no longer has to carry the fields that a create requires.** The spec declared the
  `application/json` body of each PATCH as an `allOf` of the Request schema, with its `required`
  list and its conditionals. The server checks the required fields after it merges the body into
  the stored section. So a strict client refused partial bodies that the server accepts, such as a
  `wireless/interfaces` PATCH without `device`. The body of a CRUD PATCH is now `<Name>Patch`. It
  has the properties of `<Name>Request` with the same types and patterns. It has no `required` and
  no conditionals, also on a nested object such as `match`, and no defaults. A singleton PATCH body
  is a `<Name>Patch` built the same way (#263). This only widens the request schemas of PATCH, so it
  is not breaking under `docs/versioning.md`. (#258)
- **A PATCH body takes null on the fields that the server removes for a null.** A merge patch
  (RFC 7396) removes a field with null. The server skips a null in its type check, the merge sets
  the field to null, and `toUci` leaves the option out, so the write removes it. But the PATCH
  bodies of the spec refused null on 100 fields, such as `enabled` of a firewall rule, its `match`
  and `match.family`, and the booleans of the singletons. So a strict client refused a removal
  that the server accepts. Each `<Name>Patch` now takes null on these fields, at the top level and
  in a nested object. A singleton now has a `<Name>Patch` too, built the same way, and it is the
  PATCH body in place of `<Name>Request`, as #258 did for the CRUD resources. So a regenerated
  client finds the PATCH type of a singleton under `<Name>Patch`. `<Name>Request` stays for a
  client that names it. An array still takes no null item, because a merge patch replaces an array
  whole. Some fields keep their Request type, because a null does not remove them. A PATCH ignores
  `id`. A null keeps a write-only secret, such as `wireless/interfaces.key`. The server refuses a
  null with 422 for a field that the Request requires, such as `network/interfaces.proto`, except
  `mwan3/interfaces.family`, which its `validate()` does not require. It also refuses a null
  `wireless/interfaces.mode` with 422, although the Request does not require `mode` (#273). No
  `<Name>Request` and no `<Name>Response` changes. Every PATCH body that was valid stays valid, so
  this is not breaking under `docs/versioning.md`. (#263)
- **A WireGuard peer write and a feed create no longer answer 200 when the filesystem cannot hold
  the file that they write.** ucode's `close()` drops the write error, and uapi did not check the
  write. On a full `/tmp`, the preshared key file stayed empty, and `wg` reads an empty key file
  as no key: a peer write set the kernel peer without its preshared key and answered 200 with
  `X-Kernel-Status: ok`, and the tunnel stopped handshaking with a peer that uses the key. Such a
  write now fails its kernel apply, and uci gets its previous config back. uapi stages a key
  before it changes the peer in the kernel, so a peer whose key cannot be staged stays as the
  kernel holds it, and no peer is removed for it. The restore sets every peer of the interface
  again and stages each key, so on a full `/tmp` it answers `500 reload_failed_unrecovered` when
  a peer of that interface has a key, and `500 reload_failed_restored` when none has one. On a
  full overlay, `POST /packages/feeds` left an empty `<name>.list` and answered 200, a read then
  showed an empty URL, and a retry answered 409 because the file existed. It now removes the file
  and answers 500. No request or response field changes. (#267)
- **`/diagnostics` keeps its recent errors when several requests fail at the same moment.** Every
  append to the error ring wrote through one temp file name, so two appends at once wrote into
  one file, which then held a short array followed by the tail of a longer one. That is not JSON,
  so `recent_errors` read as empty right after a burst of errors, such as the 423s of a Terraform
  apply at parallelism 10 on one package. Each request process now writes its own temp file, and
  when two appends cross, the ring keeps the later one. An error ring append or a metrics counter
  whose rename fails also no longer leaves its temp file in `/tmp`. (#267)
- **A revoke whose commit fails keeps the rate-limit bucket of its token.** `DELETE
  /tokens/{id}` dropped the bucket before it committed the delete, so a commit that failed kept
  the token and gave it a full burst again. The bucket is now dropped after the commit. (#267)
- **The restore after a failed reload no longer leaves the package empty or cut short.** It wrote
  the snapshot over `/etc/config/<package>` in place and did not check the write. A kill or a
  power cut between the truncation and the write left the package empty, a full overlay left it cut
  short while the write answered `500 reload_failed_restored`, and a `uci commit` by LuCI or a shell
  during the restore could read the half-written file. The restore now writes the snapshot to a
  temp file beside the package, reads it back, and renames it over the package. Before it writes,
  it waits up to 5 s for libuci's flock on the package file, so it does not write while a `uci
  commit` reads and writes the package. A LuCI or shell commit that already held the lock, or
  waited on it, can still rename its own file over the restored one, as one libuci commit can over
  another. A restore that cannot take the lock, write or rename the file answers `500
  reload_failed_unrecovered`, and its `restore_error` names the file. A restore also writes back
  only the packages that the write changed: the snapshot of another one would undo a commit that
  another writer made since. Measured with the ucode of the OpenWrt 25.12 SDK on a full tmpfs: the
  old restore kept 4096 of 10600 bytes and reported nothing. (#268)
- **A read no longer shows a change that another writer staged and did not commit, and a write no
  longer commits or deletes it.** `uci set` in a shell stages a change in `/tmp/.uci`, and libuci
  applies that directory to every cursor that loads a package by name, uapi's included. So a GET
  reported a value that neither the file nor the daemon held, and its ETag changed with it. The
  next uapi write of the package committed the change, and a write that uapi refused deleted every
  staged change of the package. uapi now loads each package by its path, which reads the file
  alone, and its commit reloads the file and replays the writes of the request, so a commit by
  LuCI or a shell during the request is still kept. When another writer deleted a section that the
  request wrote into, the commit fails with a 500 that names the package. LuCI was not affected,
  because rpcd keeps a delta directory per session. A response changes only on a router where a
  shell staged a change and did not commit it, and no field or type changes. The staged change now
  takes effect when the shell commits it, and not before, which applies to the `uapi` package too:
  a token that `uci delete uapi.<name>` removes without a commit keeps authenticating, where it
  answered 401 at once, a token that `uci set` adds without a commit does not authenticate yet, and
  a staged change to `uapi.logging` or `uapi.ratelimit` applies once committed. uapi also reads,
  writes and restores `/etc/config/<package>` only, and ignores an override that libuci reads in
  its place from `/var/run/uci/<package>`. Nothing in the OpenWrt feeds writes one. (#268)
- **A token minted per run no longer adds files to tmpfs, which is RAM, until a reboot.** The metric
  series that carry `token_id`, in `uapi_requests_total` and `uapi_rate_limit_drops_total`, and the
  last-used marker in `/var/run/uapi-token-update/` kept a file per token name, and nothing removed
  them. So a client that mints a token per run, as the Terraform provider's ephemeral `uapi_token`
  does, added files with every run. A mint and a revoke, over HTTP and with `uapi-token`, now run a
  reap after their commit. It removes the rate-limit bucket and the marker of every token that no
  longer authenticates, because it is revoked, expired or deleted by hand, and it folds each series
  of such a token into the series with the same other labels and `token_id="-retired"`, which no
  token can be named. The count is added there, and the series of the token is deleted once that
  count is on disk. So a sum over `token_id` keeps its value across a fold, except in a scrape that
  overlaps the fold and in the cases that `docs/operations.md` § Metrics lists, and the requests of
  a token that no scrape saw twice reach Prometheus once a `-retired` series exists for their
  labels. The metrics output changes: a scrape after a fold no longer shows the series of the token
  and shows a `-retired` series, and `rate()` reads the fold as requests at that moment, so a
  `sum(rate())` over `token_id` shows a spike after a mint or a revoke. A token with no expiry that
  is never revoked keeps its files. The reap runs after the commit and under the `uapi` lock. No
  request, response or header changes. (#269)
- **A metrics counter that a full `/tmp` could not write no longer reads 0 until a reboot.** The
  write of a counter checked only its rename, and ucode does not report the failed close, so on a
  full `/tmp` the rename put an empty file over the counter. The counter then read as NaN, printed
  as 0, and every later increment wrote NaN again. A counter is now renamed into place only when its
  size on disk is the size of its line, a counter file that holds no count is left out of a scrape
  and starts again at its next increment, which Prometheus reads as a reset, and a fold into
  `token_id="-retired"` deletes the series of a token only once its count is added. (#269)
- **Every path that no route serves is recorded as `path="unmatched"` in the metrics.** A request
  with no token could add metric files in tmpfs, which is RAM, until a reboot. The
  `path` label now names the route that serves a path, with `:id` for each parameter, a `/raw` path
  keeps its package only when `/etc/config` holds it, and every other path has the one label
  `unmatched`. The label of each route is the one it had. The metrics output changes for the paths
  that no route serves, such as `/` and `/auth`, which had their own label. (#269)
- **`uapi-token create` and `revoke` take the lock of the `uapi` package.** A write of `uapi-token`
  and a write of the HTTP path to `/etc/config/uapi` at the same moment could lose one of them, a
  revoke included. Both commands now take the locks that an HTTP write of the token store takes,
  load the package only then, and wait up to 10 s for the locks. When a lock is still held after 10
  s, the command names it and exits 75 (`EX_TEMPFAIL`), having written nothing. `uapi-token create`
  prints the bearer before its reap, so an interrupt during the reap cannot lose the bearer of a
  committed token. `docs/tokens.md` has the details. (#269)
- **A request that uhttpd kills no longer leaves its lock to the processes it started.** The lock
  files were opened without `O_CLOEXEC`, so every child started under a lock, such as an init
  script, `apk`, `passwd`, `wg` or `ip`, held a copy of the descriptor, and an flock belongs to the
  open file description. uhttpd sends `SIGKILL` when the client goes away before the response and
  when `script_timeout` runs out. The lock then stayed taken until that child exited, or for as long
  as a daemon that the child started outside procd ran, and every write behind the lock answered
  `423 locked` until then. The lock files are now opened with `O_CLOEXEC`, so the kill releases the
  lock. The child runs on, so the next write can now start while the reload or `apk` of a killed
  request still runs. A kill between the commit and the reload still leaves the write half done,
  which `docs/roadmap.md` records. No request, response or header changes. (#269)
- **The restore after a failed peer write no longer stops at a WireGuard peer without a public key
  or without allowed IPs.** wireguard.sh writes no `[Peer]` for a section without a key, and no
  `AllowedIPs` line for a peer without allowed IPs, which LuCI leaves optional, so ifup takes both.
  The restore sets every peer of an up interface again from uci and refused both, so any failed
  write of `network/wireguard_peers` on such an interface answered `500 reload_failed_unrecovered`,
  and the peers after it in uci were not set again. The restore now skips a section without a key,
  as wireguard.sh does, and sets a peer without allowed IPs with an empty `allowed-ips`, which
  clears the list in the kernel. A write that removes a peer from the kernel, such as a DELETE, sets
  again each other enabled section with the same key, and refused such a section in the same way. A
  write of `network/wireguard_peers` still requires `allowed_ips`. A failed peer write on such an
  interface now answers `500 reload_failed_restored`. No request or response schema changes. (#272)
- **A PATCH that changes nothing no longer rewrites the package of `network/rules`, `lldpd/config`,
  `snmpd/system` or `unbound/server`.** Each write of these clears an option, `action` of a lookup
  or goto rule, or the legacy `lldp_capabilities`, `sysServices` or `dnssec_enabled`, and a PATCH
  sent that delete even when the section did not hold the option. The bus counts a delete as a
  write, so the commit wrote the package again, which drops its comments. A PATCH now skips the
  delete of an option that the section does not hold. No request, response or header changes. (#272)
- **A write that sends `wireless/interfaces.mode` as null answers 422 `required`.** In 3.1.0, a
  merge PATCH of `{"mode": null}`, a PUT with a null mode, or a JSON Patch that removes `/mode` or
  replaces it with null removed the mode. wifi-scripts then set up no interface, while every read
  reported `ap`. Storing `ap` for the null, as a create without a mode does, would turn a station
  into an access point that broadcasts the station's SSID and key. So each of these writes, and a
  create with a null mode, now answers 422 on `mode`. A create or a PUT that leaves `mode` out
  stores `ap`, and a PATCH that leaves it out keeps the stored mode. LuCI cannot remove the mode.
  The Request and Patch schemas already refused a null `mode`. The 3.1.0 result was an SSID that
  never came up, which no caller can rely on, so this is the tightening carve-out of
  `docs/versioning.md`, and it fails loudly. (#273)
- **`dhcp/servers.dhcp_option` reads an option as its words, as dnsmasq.init does.** The init passes
  each entry of `list dhcp_option` to dnsmasq whole and splits `option dhcp_option` into words. LuCI
  shows such an option as its words too. uapi read the option as one entry, so a PUT of the read, or
  a write that changed the list, stored the whole value as one entry of a list. The init then wrote
  it on one line, such as `dhcp-option=lan,3,1.2.3.4 6,8.8.8.8`, which dnsmasq refuses as a bad IPv4
  address, so DHCP and DNS stopped on the whole router after a write that answered 200. Such an
  option now reads as its words, and a write stores them as the entries of a list. A list reads as
  before. The read changes only on a router that holds the option form with several words, from one
  entry to its words, which is how dnsmasq.init and LuCI read it. The type of the field does not
  change. (#274)
- **`dhcp/hosts.macs` reads a `mac` option as its words, as dnsmasq.init does.** The init splits
  `option mac` into words and gives dnsmasq each word as a MAC of the reservation. LuCI shows such
  an option as its words too. uapi read the option as one entry, which fails the MAC check, so every
  write to a host with `option mac '00:11:22:33:44:55 00:11:22:33:44:66'` answered 422 on `macs[0]`,
  a PUT of the read included. Such an option now reads as its words, a PUT of the read stores them
  as the entries of a list, and a PATCH that leaves `macs` out keeps the option. The read changes
  only on a router that holds the option form with several MACs, from one entry to its words, which
  is how dnsmasq.init and LuCI read it. The type of the field does not change. (#274)
- **The description of `mwan3/interfaces.family` says that a null removes the option, and that mwan3
  then uses ipv4.** The spec requires the key and takes null, and a read of an unset family gives
  null. So `PATCH {"family": null}` on the stock `wan6`, which sets `family 'ipv6'`, answers 200,
  and mwan3 then handles wan6 as IPv4 while the read says null. Only the description changes.
  `docs/roadmap.md` records the fix for the next major. (#274)

### Security

- **The metrics, the rate-limit buckets, the error ring and the idempotency cache keep their files
  private under `/var/run`, and so do the last-used markers of the tokens.** The first four were in
  `/tmp`. Each keeps its files in a directory of mode 0700, `/var/run/uapi-metrics`,
  `/var/run/uapi-ratelimit`, `/var/run/uapi-error-ring`, `/var/run/uapi-idempotency` or
  `/var/run/uapi-token-update`, with files of mode 0600. A package install or upgrade removes these
  five directories after its uhttpd restart, and the four that an older uapi kept in `/tmp` when
  each is a directory that root owns. The counters then start again from zero, which Prometheus
  reads as a reset, every token has a full burst, the error ring is empty, and the 24 h idempotency
  replay window starts empty. The buckets and the ring now check the size on disk before the rename,
  as the cache and the counters do, so a full tmpfs no longer empties the ring. Two idempotency
  stores of one key at the same moment no longer share a temp file, which could leave an entry that
  read as a miss. No request, response or header changes. (#270)
- **The idempotency cache keeps its entries private and bounded.** It uses only a directory that
  uapi owns with mode 0700 and writes each entry with mode 0600, a package install or upgrade
  removes the directory when root owns it, a store removes the entries older than the 24 h TTL at
  most once an hour, and a `POST /batch` that only reads stores no entry. (#266)
- **A stored `persistent_keepalive` no longer runs as a root shell command.** `src/lib/wg.uc`
  put a peer's `persistent_keepalive` into the `wg set` command without quoting it. The restore
  after a failed peer write reapplies the interface's peers from uci, and that path read the raw
  option, which never passed `validate()`. So a value such as `0;touch /tmp/x` ran as root on
  the next failed peer write on that interface. It could be written by hand, or through
  `/raw/network/...` by a token with `raw:network:rw` and `network:rw`, which `docs/security.md`
  does not grant a shell. The value is now read as a number, after removing whitespace as wg
  does, and formatted with `%d`. Measured on OpenWrt 25.12.5: the value ran before this change
  and does not after it. (#219)

- **A raw `.type` with `#` or `;` created a section of another type past the scope check.** uci
  writes the type unquoted, so `config rule#x` re-reads as an anonymous `rule`. The scope check had
  mapped `rule#x` to the bare `firewall` domain, so a token with `raw:firewall:rw`, `firewall:rw`
  and `firewall:rules:ro` could create a firewall rule. A `.type` with `'`, `"` or `\` left the
  package unparseable, and only a shell could repair it. A `.type` that holds any of these five
  characters now answers 422. That tightening uses the carve-out in `docs/versioning.md` for
  payloads that produced a state no caller can rely on, and it fails loudly. No section type in
  the uci configs of the OpenWrt feeds holds one of these characters. The re-read was measured on
  OpenWrt 25.12.5. (#237)

- **A newline in `wireless/interfaces.key` added a line to hostapd's config.** wifi-scripts writes
  the key as `wpa_passphrase=<key>` without escaping, so each newline in it started a hostapd
  directive. A token with `wireless:interfaces:rw` and no raw scope could add any hostapd directive
  that way, and no read showed it. Measured on OpenWrt 25.12.5: a key that ended in `\nssid2="x"`
  answered 200, and hostapd broadcast `x` while every read showed the stored SSID. A write that
  changes the key to one with a newline now answers 422 `invalid_format` in every mode and
  encryption, because another writer can enable the SSID or change its encryption later. A write
  that makes the daemon read a stored key with a newline, by enabling the SSID or changing its mode
  or encryption, is refused too. Any other write is not refused for the newline, and `GET
  /api/v3/diagnostics?validate=1` lists the SSID. Turning its radio on, or moving it from a radio
  that is off or missing to an enabled one, is refused too. That tightening uses the carve-out in
  `docs/versioning.md` for payloads that produced a state no caller can rely on, and it fails
  loudly. LuCI's key field takes one line only.
  (#246)

- **A WireGuard peer's `allowed_ips` ran a command as root.** `is_valid_ipv6_cidr` read the prefix
  length with `int()`, which stops at the first non-digit, so `::/0;id>x;` passed as `::/0`.
  `src/lib/wg.uc` then gave the prefix to `ip route del` through a shell, unquoted. A token with
  `network:wireguard_peers:rw` stored the value on a disabled peer with `route_allowed_ips`, and
  the DELETE of that peer ran `id` as root. Measured on OpenWrt 25.12.5: the file that the command
  wrote held `uid=0(root)`. Every release since 2.4.1 has this. wg.uc now builds every `wg` and
  `ip` command as an argument list and quotes each argument, and an IPv6 prefix length must be 1 to
  3 digits. The check is shared, so `network/interfaces` (`addresses`, `ip6addrs`, `ip6prefix`,
  `reqprefix`), `mwan3/rules` and the address fields of `firewall/rules`, `firewall/nat` and
  `firewall/redirects` now refuse an IPv6 prefix with anything after its length too: netifd, fw4
  and `ip route` refuse or misread one, and fw4 drops the rule. That tightening uses the carve-out
  in `docs/versioning.md` for payloads that produced a state no caller can rely on, and it fails
  loudly. No IPv6 prefix in the uci configs of the OpenWrt feeds has such a tail. A write of a
  section that stores such a prefix answers 422 until it replaces the value, as for any other
  value that these resources refuse, and `GET /api/v3/diagnostics?validate=1` lists the section.
  (#247)

- **A token's `allowed_cidrs` could admit every IPv6 address.** The same `int()` reading took
  `fd00::/0x40`, `fd00::/0.64` or `fd00::/-0` as `/0`, so a token minted with such an entry was
  usable from any IPv6 source. Every release since 3.0.0, which matches IPv6 callers, has this. An
  IPv6 prefix length must now be 1 to 3 digits: the mint refuses another one with 422, or with an
  error from `uapi-token`, and a stored one admits no caller, so the token answers 401. The
  validation sweep does not cover tokens, and `uapi-token list` shows their `allowed_cidrs`. A token
  minted with an entry such as `fd00::/64x`, which matched `fd00::/64`, also answers 401 now and
  must be minted again. That break uses the carve-out in `docs/versioning.md` for payloads that
  produced a state no caller can rely on: the same reading that gave `/64` here gave `/0` one
  character away. (#247)

- **A WireGuard peer's `endpoint_host` added a hidden peer at the next ifup.** On OpenWrt 25.12,
  wireguard.sh builds the config for `wg syncconf` with `printf %b`, which expands escapes, so the
  plain text `\n` in the host became a line break. A host such as
  `192.0.2.1\0072443\n[Peer]\nPublicKey=...\nAllowedIPs=0.0.0.0/0` added a peer that took the
  allowed IPs, and no read of uapi or LuCI showed it. Measured on OpenWrt 25.12.5 with a token
  scoped `network:wireguard_peers:rw`: a POST while the interface was down answered 200, and the
  next ifup installed the extra peer. Every release since 1.1.0 accepts such a host. `endpoint_host`
  now refuses a backslash, a newline, and a bracket in a host with a colon. wireguard.sh brackets
  every host with a colon, so a bracketed IPv6 address, which uapi took before, already failed the
  whole tunnel: on OpenWrt 25.12.5 wg refused the config with `Unable to find port of endpoint:
  '[[fd00::1]]:51820'`. The rule sees the peer as if it were enabled, because another writer such
  as LuCI can enable it later. A write that changes the host, or that enables the peer through
  `disabled`, is refused for it. Any other write is not refused for the host, and `GET
  /api/v3/diagnostics?validate=1` lists a peer that holds one, enabled or not. The sweep
  also lists
  a stored `public_key` or `preshared_key` that is not a WireGuard key, which reaches the same
  `printf %b`, and a write that enables such a peer is refused. That tightening uses the same
  carve-out, and it fails loudly. wireguard.sh takes the same host from LuCI's RPC, from `/raw` and
  from a shell, so the fix that closes it for every writer belongs upstream. (#247)

- **`docs/security.md` lists more write scopes that reach root.** `uhttpd:instances:rw`,
  `dhcp:odhcpd:rw` and `dhcp:dnsmasq:rw` set a program, a document root or a file that a root
  daemon uses, by design. `raw:<package>:rw` with a domain scope of that package counts as a root
  scope for each package that a root daemon or script reads. (#248)

- **Values that an init script writes into a daemon config or a shell command are checked.** An
  init script copies these values onto one line of a daemon config, so a newline added a
  directive: the string fields of every `snmpd` resource, `domain`, `local`, `server` and
  `address` of `dhcp/dnsmasq`, `domain` and `dhcp_option` of `dhcp/servers`, and
  `lldp_description` and `lldp_mgmt_ip` of `lldpd/config`. They now refuse a newline and a
  carriage return, and the two lldpd fields refuse a double quote too. snmpd splits its line into
  words, so `group`, `context`, `read`, `write` and `notify` of `snmpd/accesses`, `secname`,
  `source` and `community` of `snmpd/com2secs`, and `group` and `secname` of `snmpd/groups` also
  refuse whitespace. A script expands `leasefile` and `resolvfile` of `dhcp/dnsmasq`, and
  `src_port`, `dest_port` and `ipset` of `mwan3/rules`, unquoted, so these fields now refuse
  whitespace, `*`, `?` and `[`. `domain` of `unbound/server` takes only a DNS name, as labels of
  letters, digits, `-` and `_` separated by dots, and `clientid` of `network/interfaces` takes
  only hex digits with optional colons. In mode `monitor`, `adhoc` or `mesh`, wifi-scripts can
  pass `ssid` to a root shell command between single quotes, so `wireless/interfaces` refuses a
  single quote in `ssid` in these modes. As for the key in #246, a write that leaves such an SSID
  as it is is refused only when it enables the SSID or moves it into one of these modes, and `GET
  /api/v3/diagnostics?validate=1` lists it. Each refusal answers 422 `invalid_format`, under the
  carve-out in `docs/versioning.md` for payloads that produced a state no caller can rely on. No
  value in the uci configs of the OpenWrt feeds is refused. (#250)

- **The removal of a WireGuard peer revokes every kernel peer that its stored `public_key` gives.**
  A `public_key` that a hand edit, `/raw` or LuCI's RPC stores can make the kernel hold more than
  one peer for one section at ifup. The DELETE of the section, a write that disabled it and a write
  that changed its key removed only one of them, so the others kept their access to the tunnel.
  They now remove each key that wg can read from the stored value. A write through
  `network/wireguard_peers` cannot store such a key. (#253)

## [3.1.0] - 2026-10-11

### Added

- **`dhcp/hosts.match_tag` limits a reservation to requests that carry the given dnsmasq
  tags**, as LuCI's Match Tag does, and `!` negates. Only a tag that dnsmasq sets from the
  request itself before it looks up hosts can match, such as one from a `config vendorclass`
  rule: measured with a real DHCP client, a reservation with `match_tag: ["vc"]` applied to a
  client that sent the matching vendor class and not to one that did not. `known` and the DHCP
  range's own tag are set later, so `known` never matches and `!known` always does, whatever
  LuCI's help text suggests. dnsmasq reads only the list form, so a scalar `option match_tag`
  reads as null, and a write keeps even a single tag as a list. The spec described `tag` as
  tags a request must match, which is what `match_tag` does: `tag` sets tags on a request that
  matches. The description now says so. (#199)

- **`system/cron_jobs` manages the root crontab one line at a time.** `GET` lists the jobs in
  `/etc/crontabs/root` as busybox crond reads them, `POST` adds one, and `DELETE` removes one.
  Every other line stays byte for byte, so the lines that packages such as `acme` add survive. A
  write reloads cron and reports `runtime.crond_running` from procd, because the init script exits
  0 even when crond does not start. `runtime.runs_as_written: false` flags a line from another
  writer that crond reads differently from how it looks. Writes refuse what OpenWrt's crond
  misreads without a word: values out of range, weekday `7`, `*/N` in the day field, `@daily`,
  and `#` or a trailing backslash in the command. The new scope is `system:cron_jobs`. Its `rw`
  form runs commands as root, and its `ro` form reads every command in full. (#193)

### Fixed

- **A `dhcp/hosts` reservation on an IP that another reservation holds is refused.** dnsmasq
  treats two reservations on one address as fatal and stops, so the router lost DNS and DHCP
  after a write that answered 200. Such a write now answers `422` with field code `conflict` on
  `ip`. This tightening uses the carve-out in `docs/versioning.md` for a payload that produced a
  state no caller can rely on, and it fails loudly, with a 422, for every client. (#186)

- **An `authorized_keys` file that exists but cannot be read no longer loses keys.** uapi read
  such a file as empty, so the next add or remove rewrote it with only its own keys and could
  lock root out of SSH. A read, add or remove of such a file now fails with `500`, and syslog
  records the cause. A `PUT` replaces the file without reading it, as before. (#194)

- **A full filesystem no longer empties `authorized_keys` or the crontab.** uapi writes the new
  file under a temporary name and renames it into place, but it did not notice when the write
  ran out of space, because ucode's `close()` drops the error. The empty file then replaced the
  old one, and the request answered 200: every SSH key, or every cron job including package
  lines, was gone. Such a write now fails with `500` and leaves the old file in place. (#198)

- **A package install no longer fails on a cached index that is less than 4 hours old.** `apk
  add` refreshes an index only when its cached copy is older than 4 hours. Inside that window, a
  package that a feed rebuilt in place gave a 404, and a package that a feed added gave "no such
  package". When `apk add` fails, uapi now runs `apk update` and tries once more, even when
  `apk update` reports a failure, as it does whenever one feed is unreachable. A successful
  install costs nothing extra. (#195)

- **A package's `version` is complete.** `GET /packages/installed/{name}` and the install
  response cut most versions down to the release suffix, so `uapi` 3.0.0-r1 read as `r1`. The
  version now comes from `apk query`. The list response still returns `version: null`. (#196)

- **Links named the project's old location.** The spec's contact link and the SBOM's namespace,
  download location and homepage named `github.com/raspbeguy/uapi`. The provider link in the
  README and in the spec pointed at a Terraform Registry namespace that does not exist. All of
  them now name `openwrt-iac/uapi`. (#190)

### Security

- **`dhcp/hosts` refused nothing that dnsmasq reads as config syntax in `name` and `tag`.**
  Both go into the `dhcp-host` line that dnsmasq's init script writes. A newline in `name`
  started a dnsmasq directive of its own, so a token with `dhcp:hosts:rw` could add any dnsmasq
  option. Measured: `"name": "host1\nlog-queries"` put `log-queries` into the compiled config.
  A comma in `name` made dnsmasq refuse to start, and `tag: ["a,ignore"]` rendered
  `set:a,ignore`, which dnsmasq reads as the host's ignore flag. `name`, `tag` and `match_tag`
  now refuse a comma, a double quote, a `#`, a control character and a blank value, with `422`
  and field code `invalid_format`. This tightening uses the carve-out in `docs/versioning.md`
  for payloads that produced a state no caller can rely on, and it fails loudly for every
  client. (#199)

### Internal

- **A moved tag left its GitHub Release as an unpublished draft.** Deleting a tag to move it
  turns its release back into a draft, and the release job then uploaded the rebuilt artifacts
  to a release nobody could see. The job now publishes the release again. (#189)

## [3.0.0] - 2026-08-13

First stable v3 release. Promotion of `v3.0.0-rc3` after the provider integration window closed
with nothing filed. No code or spec changes since rc3; only the `VERSION` bump and this
changelog promotion.

The cumulative v3 changes vs. 2.5.1 are listed across the three RC entries below. As a contract
summary:

- `/api/v3/` mount; 48 curated resource endpoints plus `/raw/` passthrough, `/batch`, and the
  ops endpoints (`/healthz`, `/openapi.json`, `/schema`, `/metrics`, `/tokens`, `/auth/whoami`,
  `/diagnostics`).
- Separate `<Name>Request` and `<Name>Response` schemas for every resource. A read answers null
  for an unset uci option and both halves say so, which is what makes a read-modify-write
  round trip valid against the published document.
- A request naming a field the resource does not declare is refused with `422 unknown_field`
  rather than dropped in silence. `id`, `managed` and `runtime` stay tolerated so an apply can
  send a read straight back.
- A `PUT` or `PATCH` carrying no body is refused; a `PATCH` writes only the keys it was given,
  neither materialising defaults nor rewriting an operator's spelling.
- `allowed_cidrs` matches IPv6 callers, against entries of its own family only.
- 1230 unit tests, property-fuzz at 1000 iterations per resource per CI run, an integration
  suite against a real OpenWrt 25.12 VM including live response-conformance in both directions,
  soak with RSS/fd-leak watch, and eleven mutation-probed gates.

Upgrading from 2.x moves the mount from `/api/v2` to `/api/v3`; one installation serves one API
major. Read `docs/migration-v2-to-v3.md` before installing rather than after.

## [3.0.0-rc3] - 2026-08-13

### Added

- **The query-string fallbacks are declared in the spec.** uhttpd's CGI layer forwards a fixed
  header allowlist, and `If-Match`, `If-None-Match`, `Idempotency-Key` and `X-Request-Id` are not
  on it, so each has long had a `?if_match=` style fallback that a client had to know about from
  prose. They are now parameters on every operation that honours them, which is what a generated
  client needs in order to make a conditional or idempotent write at all.

- **`50_response_conformance_test.sh`**: validates live response bodies against the schemas the
  spec publishes for them, and checks the served document matches the one in the tree. Every
  other schema gate compares the document to itself, and the two defects above lived in exactly
  that gap: an unsatisfiable `allOf` composition is valid JSON Schema per node and only fails
  against a real body. It found the wireless defect on its first run.


- **`allowed_cidrs` accepts IPv6 prefixes.** The allowlist compared IPv4 only, so a token
  carrying one rejected every IPv6 caller and no v6 prefix could be expressed at all; both write
  paths refused one rather than store a prefix that could never match. A caller is matched
  against entries of its own family only, so `0.0.0.0/0` still denies an IPv6 caller and `::/0`
  denies an IPv4 one: on a dual-stack router, "any address" means listing both. An IPv4-mapped
  IPv6 caller is matched against the IPv4 entries, as before.

### Changed

- **BREAKING: a request naming a field the resource does not declare is now refused.** It used to
  be dropped in silence, so a body that named the wrong thing answered 200 and wrote nothing.
  `PATCH {"dest_port": ["9999"]}` on a firewall rule is the live example: the field lives under
  `match`, and at the top level it reported success and changed nothing. Such a request now
  answers 422 with field code `unknown_field`, naming the path (`match.nope` for a nested one).
  `id`, `managed` and `runtime` stay tolerated at the top level, because they appear in every
  response and in no request schema, and every IaC apply is a read-modify-write.

### Fixed

- **A revoked token's rate-limit bucket outlived it.** Nothing swept
  `/tmp/uapi-ratelimit`, so the file kept accruing against a name that no longer authenticated,
  and minting a fresh token under the same name inherited the old bucket's state. Both revoke
  paths now reap it. `uapi-token revoke` keeps its own uci cursor so it still works with ubus
  down, which means every side effect of revocation has to be repeated there rather than shared.

- **A `PATCH` or `PUT` with no body is now refused instead of writing.** The parser skipped an
  empty body and fell through with a null one. `PUT` was caught downstream by required-field
  validation, but a `PATCH` answered 200 and still committed: the merge folded the read view
  back in, so a request carrying no instruction at all materialised defaults into uci. Measured
  on a device, an empty `PATCH` added `enabled '1'` to a firewall rule that had no such option.
  Both verbs now answer 400 `bad_request`. `POST` is unaffected, because
  `/<resource>/{id}/adopt` legitimately takes no body.

- **A `PATCH` rewrote modeled keys it was not asked to change.** `diff_apply_patch` set every
  key in `toUci(merged)`, unchanged ones included, so a section storing `enabled 'on'` came back
  as `enabled '1'` after a `PATCH` of some unrelated field. uci and fw4 accept both spellings, so
  nothing behaved differently, but rewriting an operator's bytes is uapi correcting state rather
  than reporting it. A key is now written only when the patch actually moved it. `PUT` still
  normalizes the section, which is its documented contract.

- **Every entry of `GET /tokens` violated its own published schema.** `TokenMetadata` was
  composed as `allOf` over `WhoamiResponse`, which inherited that schema's `required` and so
  demanded `token_id` and `source_ip` from each entry. The token endpoints return neither: the
  listing names the token `name`, and `source_ip` is the caller's address, meaningful only for
  whoami. A strict generated client rejected the whole response. `TokenMetadata` now stands
  alone and declares the eight fields both `/tokens` and `/tokens/{id}` actually return.

- **105 response properties declared a type that forbade the null they return.** A read answers
  null for a uci option the operator never set, but `firewall/defaults.synflood_rate` was
  declared `integer`, `snmpd/system.sys_descr` `string`, `mwan3/globals.loglevel` an enum without
  null, and so on across 32 modules. A client generated from the document could not parse the
  response it was handed. rc1 widened 47 list-valued properties to `["array", "null"]`; these are
  the scalar equivalents, which were never swept. The widening applies to the response half only,
  via a new `x-uapi-read-nullable` marker: 21 of these properties are `required` on write and 26
  carry an enum, so widening the shared declaration would have made `{"target": null}`
  schema-valid on a create. Request schemas are byte-identical to rc2. Added
  `make lint-response-nullability`, which derives the requirement from each resource's real
  `fromUci` rather than from a list, with a gate-selftest probe.


- **`mwan3/globals.loglevel` declared a type admitting a null its own enum refused.** JSON Schema
  requires both to pass, so the property described a null nothing could satisfy while the runtime
  answers 200 to `{"loglevel": null}` and clears the option. The enum now lists null alongside the
  type. `lint-openapi-shape` gained a rule for the disagreement in either direction, with a
  gate-selftest probe.

- **A write-side rule demanded a masked secret of every read.** `wireless/interfaces` requires
  `key` when `encryption` is a PSK variant, and that conditional was copied verbatim into the
  response schema, where `key` is `writeOnly` and masked on read. Every read of an encrypted
  wireless interface therefore violated its own published schema. Response conditionals are now
  projected over what a response can actually supply, reusing the arm-keeping the request half
  already had. The property itself stays in the response half, because a request schema that is
  not a subset of its response makes a generated client treat a settable field as computed.


- **A `PATCH` wrote server-side defaults for fields it was not asked to touch.** Patching one
  field on a firewall rule added `enabled '1'`, and on a dhcp host added `dns '0'`, options the
  operator never set. Materialising a default pins it: the section stops following any later
  change to that default while an untouched section still follows it, so two sections that read
  alike diverge after an OpenWrt upgrade. A key absent from uci is now written only when its
  value differs from what an empty section of that type would read, which is what separates a
  default from a value the resource derived from another uci key (unbound reads `dnssec_enabled`
  and writes `validator`, and that write still happens).


- **Request schemas rejected the read-modify-write bodies the server accepts.** A read answers
  null for any uci option the operator never set, and an IaC apply sends that view back, so a
  live `firewall/rules` body carries ten null-valued keys. rc2's request half declared 248
  properties non-nullable, and 8 of 94 real bodies measured against a device therefore violated
  the schema they were published under while the server answered 200 to every one of them. The
  read-nullable widening now applies to both halves. The type was never what guarded a required
  field: `resource.validate()` is, and it still answers 422 naming the field for a null `target`
  on a create. A conditional that required a masked field went with it, for the same reason:
  `wireless/interfaces` demanded `key` when `encryption` was a PSK variant, and `key` is
  `writeOnly`, so no read-modify-write body could ever satisfy it. `validate()` still refuses a
  keyless PSK create with field `key`, code `required`.

## [3.0.0-rc2] - 2026-08-12

### Security

- **A feed URL carrying a newline appended a second, hidden apk repository.** `create_feed`
  anchored its pattern at the start only and wrote the value into
  `/etc/apk/repositories.d/<name>.list` verbatim, so
  `{"url": "http://legit/feed\nhttp://attacker/evil"}` produced two repository lines. apk trusts
  every line, so the injected one is arbitrary package installation as root on the next
  `apk add` an operator runs, and it was invisible through the API: both read paths parse a
  single line, so `GET` reported only the first. A token scoped to `packages:feeds` alone
  therefore reached code execution well outside that scope. Control characters are now rejected
  and the pattern is anchored at both ends. The same guard already existed for `set_password`
  and is now shared rather than duplicated.

- **`GET /raw/uapi` returned every token's `salt` and `hash`.** The curated endpoints gate both
  behind a flag only the internal auth path sets; the passthrough normalised the section
  verbatim and handed back exactly what they mask. Reaching it requires `raw:uapi` and
  `uapi:tokens` together, so this was disclosure rather than escalation, and bearers are random
  and salted, but the material flowed into anything built on a raw read, a config export or a
  backup being the obvious ones. Stripped now. A replace carries the stored values forward
  rather than deleting them, since a stripped field cannot come back in a request body and a
  plain read-modify-write would otherwise have destroyed the credential.

  Both were found by adversarially reviewing 3.0.0-rc1 and are fixed before 3.0.0 final.

## [3.0.0-rc1] - 2026-08-10

### Added

- **`POST /batch` reports its transaction outcome.** The 207 now carries `X-Reload-Status`, `X-Reload-Services`, `X-Kernel-Status` and `X-Kernel-Applied`, aggregated over the sub-writes. A batch commits and reloads once for the whole set, so there is one outcome to report, and the 207 is the only place it can be reported: the results array carries `{status, body}` and drops sub-response headers. A pure-read batch takes no lock and runs no transaction, so it emits nothing, matching a read anywhere else.

  This corrects a documented measurement rather than adding a new capability: the generator recorded that `/batch 207` returns none of these headers, which was true when measured and is now the thing being changed.

- `docs/migration-v2-to-v3.md`, and `make lint-wire-names` now fails on a waiver whose property no longer exists rather than only on one whose file does not.

- **`network/interfaces` models the IPv6 and broadcast fields a static interface needs**: `ip6addrs` (uci `list ip6addr`), `ip6gw`, `ip6prefix` and `broadcast`. An interface addressed only over IPv6 previously read back with no addresses and nothing to say a value had been seen and dropped, and echoing that body back was refused. The static-proto rule now asks for at least one address family rather than for IPv4, matching LuCI, whose static form marks neither `ipaddr` nor `ip6addr` required. Each field was observed taking effect on a real daemon: `broadcast` as `brd` on the netdev, `ip6gw` as the IPv6 default route, and `ip6prefix` in netifd's `ipv6-prefix`, delegating a /60 to `lan` from the /56 given.

### Changed

- **The URL prefix moves from `/api/v2/` to `/api/v3/`**, as it did across the v1 boundary. Upgrading the package strips every older mount and adds the new one, so uhttpd never serves the same `main.uc` under two prefixes: a stale `/api/v2` would otherwise look like the removed v2 surface while answering with v3 semantics. Verified by replaying the install hook against a box holding a v2 mount, which produced one `del_list`, one `add_list` and a single final prefix.


- **Every resource is now described by two schemas, `<Name>Request` and `<Name>Response`.** One schema served both directions until now, which is why `network/interfaces.ipaddr` had to be described in prose rather than as `readOnly`, why `dhcp/hosts.tag` kept `string` in its type for writers although responses were always an array, and why `runtime` and `managed` needed a `readOnly` annotation to stay out of a generated request model. Generated model names change for every resource. 46 pairs, and the 13 singletons gain a real request schema in place of the untyped `{"type": "object"}` patch body they carried before.

  Three announced changes ride on it, none of them expressible before: `managed` is absent from every request schema, `network/interfaces.ipaddr` is `readOnly` in the response half and absent from the request one, and `dhcp/hosts.tag` is array-only in both directions.

  `make lint-openapi-shape` gains a rule that a request schema may not carry `managed`, `runtime`, or any `readOnly` property, so the split cannot silently regrow. `GET /schema/<package>/<resource>` still serves the module's declared set as one object, and now says so.


- **List-valued fields read back `null`, not `[]`, when the uci key is absent.** uci cannot store an empty list, so `[]` already meant "absent" and distinguished nothing; a client could not tell the two apart because there were never two states. 46 properties across 22 resources widen to `["array", "null"]`. The request and response envelopes are untouched, where `[]` means empty rather than absent, as are the four `runtime` arrays, which come from ubus rather than uci. Verified that the four `runtime` arrays kept `[]` rather than being swept along with the rest.

  The payoff is that a list field can now carry `x-uapi-clear-on-omit`, which was impossible before: the flag requires a shape that reads absent as null, and `as_list` returned `[]`. `make lint-defaults` accepts the new `as_list_or_null(...)` shape alongside `section.X ?? null`, and still rejects plain `as_list`, verified in both directions.


- **`firewall/redirects` match fields are scalars**, where they were arrays capped at one entry: `src_ip`, `src_dip`, `src_dport`, `dest_ip`, `dest_port` and `src_port`. `proto` is genuinely a list and does not change. firewall4 refuses a list on these and discards the whole section, so the cap existed to stop uapi writing one; narrowing the type needed a major. What changes is when a mistake is caught, since a second value was accepted by the schema and refused at apply, after a declarative client had committed to a plan. Validation errors on them lose their index: `match.src_dport` rather than `match.src_dport[0]`.

- **A `<Name>Request` schema is emitted only where a write is possible.** The read-only lease endpoints carried one that nothing referenced, which blunts a signal a generated client reads: a missing request half means not writable, or removed. Two guarantees of the split are now asserted by `lint-openapi-shape` and written down in `docs/versioning.md`, the second being that a curated resource's response half contains every field of its request half, at any depth, which is what lets a client derive writability by membership.

### Removed

- **The `resolve_for_replace` seam in the handler.** Both implementors went with the mirrored names, and an extension point with no implementor is a permanent tax on every future change to the code around it. Its contract is gone from `docs/adding-a-resource.md` with it, along with the `Mirrored field pairs` section, which documented a hazard that no longer exists: a uci option now gets exactly one writable name, and a field that reads differently from how it writes is expressible as `readOnly` in the response half.


- **`dhcp/hosts.mac` and `dhcp/hosts.mac_aliases`.** `macs` is the only name, and it is the whole uci `list mac` as one array. Neither removed name was ever a uci option: `mac` was the list's first entry and `mac_aliases` the rest, so a client had to read two fields to learn what one reservation matched. Validation errors previously reported against `mac` now report against `macs`.

- **`network/interfaces.name` as a create input.** Send `id`, the universal section-name input since 2.2.0. The `422 conflict` for a disagreeing `id` and `name` goes with the field.

- **The 27 fields that wrote a uci option no OpenWrt component reads**, across `mwan3/globals`, `vnstat/config`, `lldpd/config`, `unbound/server`, `usteer/config` and `prometheus_node_exporter_lua/config`. Writes carrying them were already ignored, so nothing on the write side migrates; what changes is that they no longer appear in responses, where each carried a `default:` annotation an IaC client may have kept sticky. `prometheus_node_exporter_lua/config` loses 18 of its 20 fields and is now `listen_interface` and `listen_port`.

- **`vnstat/interfaces`, the whole endpoint.** It modelled `config interface` sections, which vnstat never reads, so a `POST` answered 200 and changed nothing the daemon looked at. Use the `interfaces` array on `vnstat/config`, remembering the values differ in kind: the removed endpoint took uci interface names (`lan`), vnstat wants device names (`br-lan`).

- **The compatibility machinery the above unlocks**: `merge_for_patch` and `resolve_for_replace` on both `dhcp/hosts` and `network/interfaces`, `equal_list`, and the mirrored-pair conflict rules in both `validate`s. Each existed only to decide which of two names for one uci option the caller meant.

### Fixed

- **A static interface could be created with no address at all, and reported `200`.** The static-proto rule counted the read-only `ipaddr` as an address, but only `ipaddrs` writes, so `POST {"proto": "static", "ipaddr": "192.0.2.99"}` passed validation, wrote nothing, and answered success; the error message for the empty case even recommended the field that does nothing. The rule now names `ipaddrs`, which is the only spelling a write can act on, so that body returns `422 ipaddrs required` instead of silently producing an interface the daemon cannot bring up. Verified on hardware, and the tightening was checked against a real `/etc/config`: 44 stock sections still round-trip, the four static interfaces among them included.

- **The management-path warning was blind to a `PUT` that strips the caller's own addresses.** It compared only the keys the body named, so a deletion, which a replace expresses by leaving a field out, produced no warning at all. A client still sending the retired `ipaddr` and no `ipaddrs` is exactly that shape: measured on a test box, the interface went from `192.0.2.88` to no address with a silent `200`. The comparison now treats an omitted field as a deletion on `PUT` and continues to treat it as "leave alone" on `PATCH`, and the retired `ipaddr` scalar left the watched set, since a read-only field can only describe a write that never happens. Verified against the interface carrying the request: the same `PUT` now answers `X-Mgmt-Path-Warning: interface=loopback changed=disabled,ipaddrs,netmask`, and the equivalent `PATCH` stays silent.

- Address formats are validated whatever the proto says. The checks sat inside the `static` branch while the write path was unconditional, so a body naming another proto skipped them entirely: a dhcp interface accepted `broadcast: "999.999.999.999"` and `ip6gw: "not-an-address"` with a `200` and committed both. Whether an address is required depends on the proto; whether a value is an address does not. `gateway` gains the format check it never had.

## [2.5.0] - 2026-08-09

### Added

- `examples/curl/adopt.sh`. Adoption is the operation an operator meets on any router configured before uapi arrived, and it had no runnable example: a section uci named anonymously reads `managed: false`, writes to it are refused with 409, and `POST .../adopt` renames it and hands back the new id. Verified end to end on hardware against a hand-written `config host`.

- `make lint-wire-names`, a gate over the second category a major has to announce: an API field whose name is not the uci option it writes. A rename is one API name for one key and stays; an alias is two API names for one key, which makes a round-trip ambiguous and cannot survive the request/response schema split. All three current aliases are announced for v3, and a fourth can no longer arrive quietly. Two further categories were built and rejected as too imprecise to gate on, recorded in the testing docs so nobody rebuilds them: section-type reachability reports thirteen false positives for every true one because netifd, odhcpd and mwan3 parse uci in C, and the boolean-as-free-text check cannot tell a type error from an ordinary raw comparison.

- `scripts/audit-dead-fields.sh` makes the dead-field audit re-runnable instead of a one-off claim: it checks all 426 uci options across every curated resource against the reader that consumes them, self-checks that it can see each package's option table before reporting anything, and fails on any option that is neither announced nor a recorded decision. The corpus is the part that goes wrong, and it fails in the direction of looking productive, so three wrong corpora on the first pass reported 63 live firewall4 options as dead. The audit now covers every curated resource. Five packages ship only a Makefile in the SDK feed, which left `firewall/*`, most of `network/*`, `dhcp/odhcpd`, `usteer/config` and `sqm/queues` unverified rather than verified-clean, and 2.5.0 is the last release that can announce a removal for v3. All 174 uci options those modules write were checked against the reader that actually consumes them, using the readers installed on a running device rather than extracted sources. One field was dead: `usteer/config.max_assoc_sta` is now flagged deprecated and announced for removal, because usteer's init forwards a fixed list of uci options to the daemon and this is not on it.

### Fixed

- `usteer/config.enabled` read the word spellings of true as enabled while usteer did not. The init reads the option with `uci -q get` and then compares `[ "$ENABLED" -gt 0 ]`, which is numeric rather than a bool parse, so `enabled 'true'` makes the shell bail with "out of range", and `start_service` returns without registering a procd instance, while uapi reported the daemon enabled. The read now mirrors that comparison exactly, including `enabled '2'` counting as enabled and an absent option defaulting to enabled.

- `disabled` on `network/interfaces`, `network/routes` and `network/rules`. netifd omits a disabled section entirely, so a section that does not exist on the box read back as ordinary active configuration and a declarative client saw a fully converged resource set with nothing to apply: no netdev, no route in the table, no matching ip rule, and nothing in a `GET` to say so. It also could not be cleared through the API, because a write cannot unset a field the model does not have, which left destroy-and-recreate as the only way back. `network/wireguard_peers` has modelled the same flag since it shipped. Verified on hardware: a route created with `disabled: true` is absent from `ip route`, reads back `disabled: true`, and a `PATCH` clearing it installs the route; the same holds for a rule in `ip rule` and for an interface, which netifd does not register at all while disabled. netifd does not parse the option the same way on all three: the interface flag is compared literally against `1`, while route and rule go through the boolean blob converter which also takes `true`. Each resource therefore reads it with the helper matching its own parser, measured three times against a reset baseline, because sharing one helper reports an interface as disabled while netifd has it registered and running.

- `lldpd/config` and `vnstat/config` now have integration coverage. Both packages sit outside the bare OpenWrt image, so every call to those resources answered 503 `init_script_missing` and neither was ever exercised against a real daemon, which is how `vnstat/interfaces` shipped modelling a section type vnstat has never read: an uninstalled package makes a wrong model look exactly like a right one. `install_uapi` now installs lldpd and vnstat2 at bootstrap, about 560 KiB together, and a new test asserts both of this release's daemon-boundary changes reach the daemon rather than merely reaching uci: `lldp_description` is checked in the `configure system description` line lldpd compiles into its config, and `vnstat/config.interfaces` in vnstat's own database via `vnstat --dbiflist`. Both resources also joined the stock-config round-trip. Verified on hardware in both directions, including that the section-type assertion rejects a `config interface` section holding the right device, which is the shape of the original bug.

- Eight deprecated fields now say why they are deprecated. `deprecated: true` tells a code generator that a field is going away; the description is the only place an operator learns the reason, and it is what a provider prints in a plan warning. Twenty-one fields carried that text and eight did not, two of them carrying no description at all, so anything downstream had to substitute a generic message that could not name the specific reason. Each now states it: `unbound/server.enabled` is read only on `config zone`, `vnstat/config.database_dir` is a key of a file that ships from upstream, and so on. `make lint-openapi-shape` now requires a description opening with `Deprecated` on any property carrying the flag, matched case-insensitively because `network/interfaces.name` predates the convention and opens `DEPRECATED in 2.2.0`. Documentation only, no behaviour change.

- `vnstat/config.interfaces`: the devices vnstat tracks, mapping to the `list interface` inside `config vnstat` that vnstat's init actually reads. This is the first time that setting has been reachable through the API. Values are device names as the kernel shows them (`br-lan`, `eth0`), which is what vnstat wants. Verified on hardware: `PATCH {"interfaces":["br-lan"]}` puts `br-lan` in the list and, after a service restart, vnstat is tracking `br-lan` in its database.


- Three response headers uapi emits are now declared in the OpenAPI document: `X-Kernel-Status`, `X-Kernel-Applied` and `X-Mgmt-Path-Warning`. All three were added to the code and to `docs/errors.md` without reaching the spec, so a generated client had no way to know they exist; the first two shipped earlier in this same release. Scoped to the responses that can actually carry them rather than to every write: the kernel pair comes from the uci transaction, so it is declared on the 163 curated-resource write responses and not on raw, non-uci or batch writes, which never run that path. `X-Mgmt-Path-Warning` is per-resource and per-verb, so it is declared on exactly three responses. `make lint-openapi-shape` now enforces both, deriving the guarded-resource count from `src/resources/` instead of a hand-kept list, and each rule ships with a self-test probe. Documentation only, no behaviour change.

- `dhcp/hosts.macs`: the whole uci `list mac` under one name, as an array. Every other uci list option in the API surfaces as a JSON array; this one did not. It was split positionally into `mac`, the first entry, and `mac_aliases`, the rest, so no single field answered what a reservation actually matched and a client had to concatenate two of them to find out. `macs` wins over both when sent, both old names keep working and keep reading back, and `PUT` resolves a stale split against the list the way `network/interfaces` already does for `ipaddrs` rather than refusing the body a full-replace client cannot avoid sending. Purely additive.

- The first architectural principle is now a test. "No partial-failure states, no config drift" was asserted in ten documentation files and covered by one unit test on the transaction module, never per resource, which is where it can go wrong: the transaction restores a snapshot, but whether a resource's write falls entirely inside that snapshot depends on the resource. `tests/unit/no_partial_state_test.uc` runs over the same 45 fixtures as the read-honesty property and injects the failure at reload, the one point where uci is already committed and the daemon then refuses. Validated by neutering the restore, which fails 33 of the 45 cases with the before-and-after uci printed.

- `make gate-selftest`: every gate now ships with a demonstrated failure. Thirteen probes break each gate on purpose and assert it says so, covering the six `lint` sub-targets, each of `lint-doc-refs`' five checks separately, `openapi-check` and `coverage`. A gate added without a probe fails the self-test, because the gate list is derived from the Makefile rather than hand-kept. Probes run in a throwaway git worktree that mirrors the working tree, so a mutation cannot reach your checkout and a gate can be validated in the same commit that adds it; a probe that changes nothing is reported as a broken probe rather than as a blind gate, since the two are indistinguishable from an exit code alone.

- `make lint-doc-refs`, a new lint that fails on a documentation reference which does not resolve: a repo path that is not there, a `module.export` a module does not export, a backticked `make <target>` the Makefile does not define, and an error code documented as returned that nothing in `src/` emits, plus the reverse of that last one. Four false claims about this project were found by hand within a few days, each corrected individually with nothing to stop the next; this catches the two shapes that are mechanically checkable, and its own header states the larger half it cannot reach ("this job proves X" where the job exists and does something adjacent, and modal invariants like `never` or `atomic`). Waivers are keyed by the reference with the reason as the value, because some references are deliberately unresolvable: `bench/baseline.json` is cited precisely because it does not exist.

- Advisory management-path guard. `GET /diagnostics` now reports `management_path`, naming the interface the request arrived through (`{address, device, interface}`), and a `network/interfaces` write that moves that interface's `disabled`, `proto`, `ipaddr` or `netmask`, or deletes it, returns an `X-Mgmt-Path-Warning` response header. This is the lockout class an atomic write cannot help with: a change that reloads cleanly and then severs the only path to the box. Advisory rather than a refusal, because renumbering the management path is a legitimate operation and LuCI warns rather than blocking on the same four field names; no firewall analysis, also matching LuCI, because predicting a firewall lockout means modelling fw4 zone and rule ordering. The interface is derived from the kernel's own route lookup rather than by comparing the caller's address against local prefixes, which is what makes it right for an operator arriving from another network, the case that matters most, and what makes it answer for IPv6 where uapi's prefix helpers are IPv4-only. Structural limit, documented: if the write really does strand the caller the response never arrives, which is why `management_path` exists as the pre-flight half. Purely additive.

- `GET /diagnostics?validate=1` sweeps every section a token may read through the same validation a write performs and reports the ones that would be rejected, with the reason. It answers "which sections on this router will stop being accepted" before an upgrade, instead of one `422` at a time part-way through an apply. Every section it reports is already broken on the router: a port match on `proto all` is already matching the whole protocol, and a multi-value redirect is already discarded by fw4, so the sweep is the first time anyone is told rather than new breakage. Opt-in, because it walks the whole configuration and `/diagnostics` is polled on an interval; without the parameter the response is unchanged. Each resource is included only if the token permits `:ro` on it as well as `uapi:diagnostics:ro`, since findings name sections and quote configured values, and `skipped_for_scope` reports what was left out so an empty result cannot be mistaken for a clean one. Read-only and side-effect free. Closes [openwrt-iac/uapi#47](https://github.com/openwrt-iac/uapi/issues/47).

- `X-Kernel-Status` and `X-Kernel-Applied` response headers on writes, saying whether a write reached the kernel rather than only uci. The kernel apply added in 2.4.1 skips an interface that is down or that netifd does not know, which is correct because `ifup` reads the peers from uci, but it left a client unable to tell that `200` apart from one whose peer is live. `X-Kernel-Status` is `ok` when every targeted interface was applied, `partial` when some were skipped, `skipped` when none was, and `no_kernel` for a resource with no kernel path, mirroring how `X-Reload-Status` reports `no_reload`. `X-Kernel-Applied` names the interfaces actually changed. Documented in `docs/errors.md` § Response headers.


- **`If-None-Match` is now evaluated on writes.** It was parsed for every method and then dropped for anything but `GET`, so a caller asking for "only if this has not changed" or "only if absent" had its condition silently discarded and the write performed anyway. RFC 9110 13.1.2 gives `304` for `GET`/`HEAD` and `412` for every other method; 13.2.2 requires the precondition to be evaluated before the method runs, so the check goes in the existing `precondition_check` seam, which already runs inside the transaction before `uci_commit`. A `412` therefore means nothing was written, and that is what the tests assert rather than the status alone. `If-Match` is still evaluated first, per 13.2.2's ordering.

  **This turns previously-successful writes into refusals**, which is the breaking clause in `docs/versioning.md`, and the carve-out argument is worth stating because it is arguable either way: the server accepted a request whose conditional semantics it then threw away, so the `200` was never a contract a caller could deliberately rely on. Anyone appending `?if_none_match=` to a write, which the integration suite proves is a real pattern, now gets `412` where they got `200`.

  Measured on hardware: `PATCH ...?if_none_match=*` on an existing resource returns `412` with uci unchanged; a matching etag likewise; a non-matching etag still writes and still carries its three transaction headers and its audit line; and conditional `GET` is untouched, returning `304` for both a matching etag and `*`.

  Out of scope, deliberately: collection `POST` still ignores `If-None-Match: *`, since there is no target resource whose etag could be tested, and the existing `409`-before-`412` ordering is unchanged because reshuffling it would move `If-Match` responses too.

- **`/raw` let a client write `option managed` into uci, where it then shadowed the derived value.** `managed` comes from uci's `.anonymous` flag and is never stored, but raw has no `toUci` to drop unknown keys: it copies the request body wholesale. A read-modify-write client therefore wrote the field back, and `normalize_section` let the stored option override the derived one, so the response came back as the **string** `"0"` where the schema promises a boolean. Measured on hardware, before and after: `PATCH /raw/firewall/<id> {"managed": false}` used to leave `option managed '0'` in the section and answer `"managed": "0"`; it now writes nothing and answers `"managed": true`. A section that already carries the stale option is handled too, which the first version of this fix missed: `normalize_section` derives `managed` after copying the section rather than before, so a stored value can no longer shadow it, and a patch sweeps the residue. Previously only a full replace could remove it, and the `[]` clear idiom could not reach it either, because the guard keeps the key out of the write set.

- `managed` is annotated `readOnly` across all 46 schemas that carry it. No `toUci` reads it and the write path hardcodes `.anonymous = false`, so a `PUT` sending `managed: false` has always answered 200 with `managed: true`; management state moves only through the adopt endpoint. Emitted as a bare boolean it read to a code generator as an ordinary writable field, so it landed in the request model of every generated client, which then sent a field the server ignores. The annotation is applied generator-side, mirroring how `runtime` is handled: adding it to each module's `schema_properties` instead would also add it to the runtime type checker and turn `managed: "true"` from 200 into 422, which is a tightening nobody asked for. `lint-openapi-shape` now enforces it, with a self-test probe.

- **Three fields wrote a uci key their daemon never reads, so the value never reached the device.** `lldpd/config.lldp_capabilities` wrote `lldp_capabilities` while lldpd reads `lldp_capability_advertisements`; `unbound/server.dnssec_enabled` wrote `dnssec_enabled` while unbound reads `validator`; `snmpd/system.sys_services` wrote `sysServices` while snmpd reads `sysService`, singular, a typo uapi inherited from upstream's own sample config. Each now writes the key its daemon reads, and still reads the old one when the new is absent, so an upgrade does not silently drop a value an operator set and report the default in its place. Every write also clears the legacy key. That is not tidiness: without it the legacy key never enters the footprint a `PATCH` deletes from, so clearing one of these fields removed the real key and left the old one behind for the fallback to resurrect, and the API answered `false` to the write and `true` to the very next read while the daemon had it off.

  **These settings start taking effect, which is the point and also the risk.** A value stored months ago and quietly ignored becomes live on the next write to that section. For `sys_services` that is inert SNMP metadata. For `lldp_capabilities` it can stop a TLV being advertised to neighbours. For `dnssec_enabled` it turns on **DNSSEC validation**, which will break resolution on a network whose upstream DNSSEC is broken. Check what those three options hold on your boxes before upgrading if that matters to you. **Carve-out (`docs/versioning.md`)**: the writes being corrected produced state no caller could rely on, because they never reached the daemon at all.

  Verified on hardware rather than by reading: `PATCH sys_services:76` now produces `sysService 76` in the generated `snmpd.conf`, and `lldp_capabilities:false` on a box carrying the old key produces `unconfigure lldp capabilities-advertisements` in lldpd's generated config.


- `dhcp/hosts.tag` now always reads back as an array. The same reservation answered with `"guest iot"` on a box storing `option tag 'guest iot'` and `["guest","iot"]` on one storing `list tag`, though dnsmasq word-splits the scalar and treats them identically, so a client had to handle two shapes to learn one thing. A stored scalar is split on the way out; a read never touches storage, and the first write-back converges it, which is invisible on the wire because both compile to `set:guest,set:iot`. Verified on hardware, including a `GET` fed straight back as a `PUT` leaving the view unchanged. A space-separated string is still **accepted on write**, because the 2.4.1 spec declared one and clients generated against it send one; v3 removes that and the field becomes array-only in both directions. **Carve-out (`docs/versioning.md`, branch b): a response type changed in a minor, because the 2.4.1 declaration `["string", "null"]` was violated by the server's own responses for any section storing `list tag`, the ordinary uci spelling for more than one tag.** A scalar `option tag 'red'` did read back correctly under the old type, so branch (a) does not apply and is not being claimed. This was previously announced as a v3 change to the read shape, which deferred a year of two-shape handling for no benefit: the objection was to normalizing storage, and splitting on read settles the wire shape without that.

- **The read-honesty property was blind to most of the fields it was supposed to protect.** Its default-masking guard compared each *seed* against the schema default, but seeds are keyed by uci option name and `schema_properties` by wire name, so every field whose names differ failed the lookup and was skipped in silence. It inspected 15 of 140 seeded keys. The consequence, measured rather than argued: deleting the `PasswordAuth` write from `dropbear.instances.uc`, which silently re-enables SSH password authentication across a `GET`-then-`PUT`, passed all 1126 tests. Dropping `masq` from `firewall.zones`, which silently disables NAT, did too. The guard now compares the **read-back** value against the default, which needs no name mapping because it asks the question the property actually depends on: if `toUci` dropped this field, would the re-read refill it and hide the loss? That exposed 101 blind pairs across 34 of the 46 cases, every one of which is now seeded off its default. Both deletions above are caught.

- The `/diagnostics` surface added in this release never reached `build/openapi.json`. The `?validate=1` parameter was undeclared, and `DiagnosticsResponse` still listed the six properties it had at 2.4.1 while the endpoint returns four more: `management_path`, `invalid_sections`, `swept_resources` and `skipped_for_scope`. A client generated from the spec could not see the sweep at all. All five are declared now, including the two error codes that appear only inside a sweep result, `unreadable` and `sweep_failed`, which are documented in `docs/errors.md` for the first time. Checked against a live response rather than against a reading of the source: the declared property set matches the emitted keys exactly, and a planted invalid section confirms the item shape down to the slash-form `resource` and the `{field, code, message}` errors.

- The management-path warning was blind to the field the deprecation steers clients toward. `ipaddrs` is the same uci option as `ipaddr` under the name that replaces it, but only the scalar was watched, and `merge_for_patch` deletes `ipaddr` from the merged body exactly when the caller sends the list. So `PATCH /network/interfaces/<inbound> {"ipaddrs": [...]}` renumbered the interface carrying the request and warned about nothing, as did a `PUT` naming only the list, whose `resolve_for_replace` returns early. Both are reported now. Also fixed the same omission in `docs/errors.md`, `docs/operations.md`, `docs/security.md` and the published header description, all of which named four fields.

- The DELETE arm of that warning had no test. It is not unreachable, contrary to the review that raised it: the delete path hardcodes `changed=removed` rather than going through the field comparison. The integration test can only assert the negative half, since exercising the real one would strand the box running it, so this is covered by a unit test instead: the handler now threads `mgmt.uc`'s existing route-lookup seam through from the request context, which production leaves unset.

- `PATCH {"mac": null}` on a `dhcp/hosts` reservation with more than one MAC returned `422` against `mac_aliases`, a field the caller never sent. `merge_for_patch` collapsed `mac` and `mac_aliases` into a single "did the body name the split" flag, so naming `mac` dropped the merged `macs` but kept the read view's `mac_aliases`, producing a list with no head, which is exactly the shape `validate` rejects. Clearing `mac` now clears the tail with it, since there is no uci list left to hold it. Dropping the DHCPv4 MACs while keeping a DHCPv6 reservation is a legitimate request and was the one shape that could not express it.

- **Clearing a list option answered 200 and changed nothing.** uci cannot store an empty list, so `[]` means "no value"; the uci binding refuses a zero-length array and `bus.uc` discarded that answer. Because the key was still present in the write set, neither diff loop took its delete arm, so `PATCH {"tag": []}` returned 200 with the field reported cleared while dnsmasq kept applying `option tag 'guest'` to the reservation. An empty array now takes the delete arm, The rule lives in `bus.uc`, which turns a set of `[]` into a delete: `[]` is the absence of a value, so setting one removes the option. Putting it there rather than in each write loop matters, because there are six across `handler.uc` and `raw.uc`, and it fixes raw passthrough as a side effect, which had the same silent drop. The test stub accepted `[]` and stored it, which is why no unit test could see this; it now refuses exactly what the real binding refuses. Affects `dhcp/hosts.tag`, `openvpn/instances` `remote`, `push` and `route`, `usteer` `event_log_types` and `ssid_list`, and `mwan3/interfaces` `track_ip` and `flush_conntrack`.

- **A write could be answered `304`, losing its headers and its audit line.** `maybe_304` ran on every response rather than only on reads, so appending the documented `?if_none_match=` fallback to a `PUT` or `PATCH` rewrote the response of a write that had already committed and reloaded. The caller got no `X-Reload-Status`, no `X-Kernel-Status` and no `X-Mgmt-Path-Warning`, and because the audit branch logs 2xx writes only, the write left **no audit line at all**: one query parameter kept a configuration change out of the trail that exists to record it. A `304`'d `POST` was also never cached for idempotency, so a retry with the same key created a second section. Measured on hardware: with the defect, `PATCH ...?if_none_match=*` returned `304` while uci moved from `192.168.222.1/24` to `192.168.222.77/24`; with the fix the same request returns `200`, three transaction headers and one audit line. Conditional GET is unaffected. RFC 9110 13.1.2 allows `304` only for `GET` and `HEAD`; the strictly conforming `412` for writes needs the precondition evaluated before the method runs (13.2.2) and is tracked separately.

- **An operator-disabled WireGuard peer could be re-enabled and pushed into the kernel.** `disabled` and `route_allowed_ips` are read by `wireguard.sh` with `config_get_bool`, which accepts `on`, `yes` and `enabled`; 2.5.0 moved them to the netifd-strict helper, which accepts only `1` and `true`. A peer spelled `option disabled 'yes'` therefore read back as enabled, and because a write persists the read view, any unrelated `PATCH` on that peer rewrote uci to `disabled='0'` and the kernel apply emitted a `set` that installed the peer live. Same defect on `route_allowed_ips`, where it also skipped route installation and skipped the `ip route del` on delete.

- `lint-defaults` was anchored on the literal name `normalize_bool`, so reclassifying fields onto the new helpers would have silently removed them from that gate: it went from seeing 75 boolean fields to 25 while still reporting OK, and a dropped `default:` annotation on any of the 50 would have shipped unnoticed. That annotation is what an IaC client reads to keep a field sticky, so losing it produces a perpetually non-converging plan. The lint now matches every helper that takes a default (79 fields), and the self-test gained a probe for the boolean shape, having previously probed only the string one, which is why the loss would have gone unreported.

- `mwan3/interfaces.enabled` and `openvpn/instances.enabled` declared a default of `true` while both daemons default them to off: mwan3's init reads `config_get_bool enabled $interface 'enabled' '0'` and openvpn's `section_enabled()` defaults both spellings to 0. A section with the option absent therefore read back as enabled, and because a write persists the read view, any unrelated `PATCH` wrote `enabled='1'` and switched it on. Same failure chain as the WireGuard peer above, reaching the opposite conclusion on adjacent lines, which is what an audit of the accepted set without the default looks like.

- Boolean readers, everywhere. The rule in the docs was "the netifd helper for netifd-owned fields and the wide one for the rest", and there is no "rest": OpenWrt has at least five readers with three different accepted sets, plus one this project cannot verify because ubox is not in the SDK. Auditing all 101 call sites against the actual reader in the OpenWrt sources moved 54 of them to a new `shell_bool` (the `get_bool` set, which the previous helper was short by `enabled`/`disabled`), 4 wireless fields to the strict netifd helper they had been reading too widely, and 4 raw-compare fields to a new `strict_bool`. The reader table in `docs/ucode-quirks.md` now lists every class with its helper, because that table is what produced the bug.

- Two fields were not booleans at all, and every write destroyed their value. `system.urandom_seed` is the filesystem path the entropy seed is saved to (`/sbin/urandom_seed` tests that it starts with `/`), and `lldpd`'s `lldp_description` is the free-text system description emitted verbatim into LLDP frames. Both were typed `boolean`, so a round trip replaced the operator's value with `"1"` and, for the seed, silently turned the feature off. Both are now strings. **Carve-out (`docs/versioning.md`): a type change on the wire.** It is earned by the write path, not the read path, and the earlier wording of this entry got that wrong. For `urandom_seed` the reader only acts on a value beginning with `/` (`sbin/urandom_seed`), so setting a real path was unreachable through a boolean, and asking for `true` wrote `'1'`, which leaves the feature off while every later read reports `true`: a lie that persists in uci. For `lldp_description` every write replaced the advertised system description with `"1"` or `"0"`. No uci value made either boolean a correct answer, which is the test the carve-out now states. What a caller does lose is the `false` a stock box returned for `urandom_seed='0'`; that reading was correct, but it was the only correct one the type could produce and it could not be acted on. **How loudly this lands depends on the client, and it is silent for a whole class of them.** A client sending a real JSON boolean is told: `{"lldp_description": true}` answers `422 invalid_type`. A client whose configuration language coerces booleans to strings never sends one. HCL does, so an unedited Terraform config carrying `lldp_description = true` serialises to `"true"`, which is a valid string and is accepted: verified on hardware, the advertised system description becomes the literal text `true`, and `urandom_seed = "true"` leaves the seed feature off while every read reports a plausible string. So check for the literal `"true"` or `"false"` in these two fields after upgrading rather than relying on an error. `dhcp/hosts.tag` is unaffected, because no such layer coerces a string into a list, which is why that correction does fail loudly.


- `ETag` was declared on 18 responses that never carry one and missing from 43 that always do. The same defect as the reload headers, in both directions at once: raw passthrough, `/packages`, `/tokens`, `/system/authorized_keys`, `/auth/whoami`, `/diagnostics` and the read-only lease views all declared an `ETag` they never send, while every `304` emitted one and declared nothing. `set_etag_header` has four call sites, all in the curated CRUD and singleton handlers, and `make_collection.get_one` returns bare, which is why "curated" alone is the wrong test: the lease views are curated and still carry none. The generator now takes explicit intent instead of guessing from the response schema shape, and `lint-openapi-shape` derives the expected set from the catalog's `kind` field. Measured on a real box: a curated item GET, a singleton GET and a curated PATCH each return one, while whoami, diagnostics, raw collection and item GET, a raw PATCH, the lease list and `POST /tokens` return none, a genuine 304 on both a singleton and a CRUD item (reached through `?if_none_match=`, since uhttpd's CGI env drops the header) carries the ETag it is now declared with, and a collection-kind item GET returns a real lease body with no ETag, which is the case that makes "curated" the wrong test on its own.

- `X-Reload-Status: no_reload` was documented with `system` as its example, which reloads `system` and `log`. All 43 writable resources declare at least one reload service, so `no_reload` describes a resource shape that does not currently exist and no shipped response carries it. The value stays defined, since the transaction still handles that shape, but the docs and the published enum description now say it is not reachable today instead of illustrating it with a resource that disproves it.

- `X-Reload-Status` and `X-Reload-Services` were declared on 15 response bodies that never emit them: every raw passthrough write, `POST /batch`, and the non-uci writes under `/packages`, `/tokens`, `/system/password` and `/system/authorized_keys`. None of those paths reaches `attach_reload_headers`, so a client generated from the spec was told to expect a header that could not arrive. Measured on a real box rather than inferred: curated writes return the pair on POST, PUT, PATCH, DELETE 204 and singleton PATCH, while raw returns neither on any of its four verbs, and `POST /batch`, `packages/feeds` POST and DELETE, `POST /tokens` and `authorized_keys` POST and DELETE return neither. The handful not exercised by hand (`DELETE /tokens/{id}`, `POST /system/password`, `packages/installed`) share the same response path as the ones that were, which is the thing the code check below actually pins. The declarations now follow the same `uci_tx` gate the kernel pair uses, leaving all four transaction headers on the 163 curated-resource write responses and nowhere else. `lint-openapi-shape` enforces both directions, deriving the curated path set from the generator's own `ENDPOINTS` catalog so a new resource needs no lint change, and both directions ship with a self-test probe. This removes a declaration rather than adding one, but nothing that was ever sent stops being sent: the header was already absent from these responses, so no client can have depended on receiving it, and OpenAPI response headers are never required.

- `dhcp/hosts` no longer accepts `mac_aliases` without `mac`, which silently discarded the MACs. The two are one uci `list mac`: the scalar is its first entry and the array the rest, so aliases with no primary describe a list with no head. `toUci` could not write it and wrote nothing at all, while `validate` passed the body because the identifier requirement is written against `mac` and `duid`; a reservation carrying a `duid` therefore answered `200` with its MACs gone. It now returns `422 conflict` on `mac_aliases`. Reported against that field rather than `mac` so it cannot collide with the identifier error under the field-and-code dedup. Writing the aliases as the list instead was rejected as a fix: `mac` would come back non-null, answering a different request than the one sent. **Carve-out (`docs/versioning.md`): a payload accepted before now returns 422**, earned because the old behaviour wrote no MACs, which is state no caller could rely on. The response body was already honest about the result, since it is rebuilt from `fromUci`; the defect was accepting a body uapi could not honour without saying so.

- `coverage`'s dead-export gate could never fire. `used_internally` scanned each module for the export's name as a token, and a module's own export block names every one of its exports, so every export counted as internally used and the `exit_code = 1` on dead exports was unreachable. A genuinely dead export passed cleanly. The export block is now excluded from that scan, verified in both directions: a planted dead export is reported and exits non-zero, and all 131 real exports still pass. Found by the gate self-test on its first complete run, which is the case for having it.

- `lint-emdash` had never run in CI. It lists tracked files with `git ls-files`, no CI job installed `git`, and `|| true` turned the resulting failure into a pass: the lint job logged `/bin/sh: git: not found` and reported success without reading a file. The em-dash rule was enforced on developer machines only. `git` is installed in the lint container now, and the recipe fails loudly if git is missing or if the checkout has no `.git` (an `actions/checkout` tarball export has no tracked-file list), so the next container change cannot silently disable the rule again.

- Seven false statements in the documentation, found by inventorying every checkable reference. `docs/packaging.md` cited `.github/allowed-signers`, which has never existed, for `.github/release-signers.asc`. The `verify-arch-build` "proves arch-neutrality" claim, corrected in the workflow comment in 2.5.0, survived in `docs/packaging.md` and `docs/release-process.md`. `docs/migration-v1-to-v2.md` documented dependency-aware ETags as current behaviour, though they were removed during the 2.x line. `docs/concurrency.md` said lock granularity for different packages is "asserted live" when the only assertion is a unit test over real flocks. Three docs claimed the concurrency test observes "5 distinct PIDs" when it asserts at least 2 and uhttpd caps concurrent CGI children at 3. `docs/operations.md` said 43 resources and `docs/testing.md` said the harness is ~100 lines. And `docs/lock-state-audit.md` claimed "17 sites audited" while its own reproduction command finds 36, with nine modules absent from the table entirely, including one added in this release; it now states its real coverage and the completion is tracked on the roadmap.

- A `PATCH` whose body is not a JSON object is rejected with `422 invalid_type` instead of answering `200` and changing nothing. The merge folded the body into the read view before validating, and the merge yields an object whatever the body was, so a scalar or a bare array reached the write path as a no-op and the response was indistinguishable from a successful partial update. A client sending a malformed body was told it had succeeded. This is a tightening under the `docs/versioning.md` carve-out: the payloads it now rejects could never have applied, so no caller can have been relying on the old answer, and reporting that a write landed when nothing was written is the one thing a write must not do. Both the collection and singleton PATCH paths are covered. Two shapes are deliberately unaffected: an empty request body, which arrives as null and has always meant "a request naming no fields", and a JSON Patch array under `application/json-patch+json`, whose body is an array of operations by definition. Closes [openwrt-iac/uapi#83](https://github.com/openwrt-iac/uapi/issues/83).

- CI no longer advertises checks it does not perform. The perf bench step was named a regression gate and the release process listed it as one, but the comparison it relies on runs only when `bench/baseline.json` exists; no such file has ever been committed and no step produces one, so the check has never executed and a latency regression of any size shipped green. It is now named and documented as measurement, which is what it does, and the threshold is marked uncalibrated rather than left looking tuned. `verify-arch-build`'s comment claimed it proved the APK is byte-identical across host arches and that a release should be held on divergence; it compares no digests and its matrix has no x86_64 leg to compare against. What it does enforce, and what 2.4.1 actually relied on, is that every arch's SDK tarball is pinned by checksum and that the package cross-builds under all three; the comment now says that. `415 unsupported_media_type` was documented as returned when a body is not JSON, but Content-Type is never inspected: `text/plain` and no header at all are both accepted and the write lands. It is now documented as reserved, since enforcing it would reject bodies that work today.

- Booleans owned by netifd are read the way netifd reads them. netifd converts uci strings through uci's own converter, which accepts only `1`/`true` and `0`/`false` and **drops the option** for anything else, falling back to its own default; uapi read them with a helper that also accepts `on`/`yes`/`off`/`no`, so it reported the operator's intent instead of the daemon's behaviour. Concretely `option auto 'no'` on an interface read back as `auto: false` while netifd, having dropped the value, autostarted the interface. The affected reads are `auto`, `nohostroute`, `peerdns`, `defaultroute` and `delegate` on `network/interfaces`, `disabled` and `route_allowed_ips` on `network/wireguard_peers`, `invert` on `network/rules` and `ipv6` on `network/devices`. Only netifd-owned fields changed: fw4 and the shell init helpers do accept the wider set, so reading those the strict way would introduce the same bug mirrored, and `docs/ucode-quirks.md` now carries the per-daemon table. Writes are unchanged and still emit `"1"`/`"0"`, which every reader accepts.

- A wireguard peer's `route_allowed_ips` routes are withdrawn even when the option was spelled `true` in uci. The kernel apply learns which routes the previous configuration installed from the peer's existing uci section, and that read accepted only `"1"`, so a section written by hand or by another tool with `true` was treated as having installed none: shrinking such a peer's `allowed_ips`, or deleting the peer, left its routes in the kernel directing traffic into the tunnel for prefixes it no longer had. Sections written through uapi were never affected, since uapi emits `"1"`/`"0"`.

- `network/interfaces` accepts IPv6 and dual-stack addresses on a wireguard interface. The `addresses` list was validated with the IPv4-only CIDR check, so `fd00::1/64` was refused with "must be a valid IPv4 CIDR" and **no IPv6-only or dual-stack tunnel could be configured through the API at all**, even though the published schema declares the array unrestricted and netifd's own handler parses both families. This is the same class as the `allowed_ips` fix in 2.4.1, which corrected the peer field and missed the interface's own addresses. Verified on hardware: a tunnel created with `["fd00:99::1/64", "10.99.0.1/24"]` comes up with both addresses present in the kernel. `ipaddr` and `ipaddrs` stay IPv4-only, since those are the static-proto v4 fields.

- `dhcp/hosts` no longer writes the inverse of a `dns` request. `name`, `tag` and `dns` were written by `toUci` but absent from `schema_properties`, so the central type gate never saw them: `dns: "0"` is a truthy string in ucode and wrote `dns=1`, enabling DNS for a reservation whose request asked to disable it. `name` and `dns` now carry schema properties, and the false lint waiver that excused `dns` as "not surfaced in schema_properties" is gone, its stated reason having been contradicted by `toUci` writing the field.

  **Carve-out (`docs/versioning.md`): these payloads were accepted before and now return `422`, and ship in a minor because the state they produced was one no caller could rely on.** `dns` earns it outright: the write did the opposite of what was asked, and `name: 123` was silently coerced into uci and rides the same carve-out. `tag` is deliberately left undeclared: dnsmasq reads it with a scalar `config_get` and then word-splits it, so a uci `list tag` is working configuration that the ubus API surfaces as an array, and a string schema would reject it. Declaring `tag` needs a decision about which shape the wire uses rather than just a type. Published types are unchanged, since the spec already inferred all three from a read sample; `dns` gains its `default: false`. dnsmasq reads `dns` with the shell `config_get_bool`, which accepts the wider spelling set, so the reader stays `normalize_bool` rather than the stricter netifd form.

- `wireless/interfaces.has_key` is always present. It was set only when a key existed, so the member was **absent** on a keyless section while the published schema declares a non-nullable boolean, meaning a plain `GET` of an open or OWE network violated the spec the server itself ships. Every sibling write-only flag already spelled it the documented way. Verified on hardware: two real `encryption: owe` interfaces now read `has_key: false` where the field was previously missing. An empty key also counts as no key, which is defensive rather than reachable, since uci does not store an empty option value.

- Two `unbound/server` validation messages named enum sets their own validator contradicts. `protocol` advertised `auto`, which is rejected, and omitted `default`, `ip6_local` and `ip6_prefer`, which are accepted; `resource_limits` omitted the accepted `default`. Both messages are now derived from the constant they validate against, as `domain_type` already was, so a new enum value cannot leave the message behind. Reachable on the `PATCH` delta path, where the central schema gate does not fire for a field the request did not name, which is why nobody had reported it.

### Deprecated

- Roughly thirty fields that write a uci option no OpenWrt component reads are announced for removal in v3, found by auditing every curated field against its reader in the OpenWrt sources. Each has never had any effect: the write is accepted and stored, and the daemon carries on as before. They are removed rather than corrected because, unlike the three repointed in this release, there is nothing to point them at: `mwan3rtmon` has no polling interval, vnstat's real settings live in a file that ships from upstream, LLDP-MED is a build-time switch, unbound is enabled through procd, and the prometheus exporter enumerates its collectors from disk. **Seven of that exporter's seventeen collector toggles name collectors that do not exist in the package at all.** Requests carrying these keys are already ignored, so nothing on the write side needs migrating; the read side does, since each is currently returned with a `default:` annotation, which is what an IaC client reads to keep an attribute sticky. Each is flagged `deprecated: true` on the property, which is what `docs/deprecations.md` requires and what actually reaches a client: a prose bullet in the spec description is read by a human, the flag is read by codegen.

- `managed` leaves the request half of every resource schema in v3. It is annotated `readOnly` from this release, which is the notice: a regenerated client stops putting it in request models.

- Each resource gains a separate request schema and response schema in v3. One schema serving both directions is what forces `dhcp/hosts.tag` to keep `string` in its type for writers while responses are always an array, and `network/interfaces.ipaddr` to be described in prose rather than as `readOnly`. The ledger already promised that consequence while the cause went unannounced.

- `vnstat/interfaces` is deprecated for removal in v3; use `vnstat/config.interfaces`. The endpoint has never worked. It models `config interface` sections, and vnstat only ever reads a `list interface` inside `config vnstat` (`vnstat.init:21,28`), so a `POST` returned 200, wrote a section, and vnstat carried on tracking exactly what it tracked before. Confirmed on a real router carrying both shapes at once: `vnstat.@vnstat[0].interface='br-lan' 'eth0'` was being tracked while two uapi-created `config interface` sections for `vlan30` and `lan` were ignored. **Migration is a translation, not a copy**: the dead endpoint took uci interface names (`lan`), the working field takes device names (`br-lan`). All seven of its operations carry `deprecated: true` in the spec, so a generated client surfaces the warning; prose in the ledger reaches a human reading the document and nothing else.


- `dhcp/hosts.mac` and `dhcp/hosts.mac_aliases` are deprecated in favour of `macs`, for removal in v3. All three name one uci `list mac`. Both are flagged `deprecated: true` on the property, unlike `network/interfaces.ipaddr` above, and the difference is not an oversight: `ipaddr` corresponds to a real scalar uci option and survives as a read, whereas uci has no scalar `mac` option on a host, so `mac` was never a uci field at all, only uapi's positional half of a list. Nothing is left for it to mean once `macs` exists, so both names go entirely rather than becoming read-only.

- `dhcp/hosts.tag` will read back as an array of strings, not a space-separated string, from v3. Both shapes are accepted on write today and the field reads back whichever uci holds, which is the inconsistency being retired: dnsmasq's tag construct is multi-valued and LuCI has always written the list form. Not flagged `deprecated: true` on the property, because the field itself survives and only the string form goes away; the notice lives in the field's description and in [`docs/deprecations.md`](docs/deprecations.md), alongside the other five v3 changes now listed under "Upcoming in v3" in the OpenAPI document's own description.

- `network/interfaces.ipaddr` is deprecated as a **write** input; send `ipaddrs` instead. Both name the same uci `list ipaddr` and the list already wins on write, so migrating means dropping the scalar from request bodies rather than changing any value. Reads are unaffected now and after removal: `ipaddr` keeps carrying the first entry of the list, and v3 marks it `readOnly` rather than deleting it. That read half is why the property is not flagged `deprecated: true` in the spec, since the flag has no read/write split and would tell a generator the field is disappearing; the announcement is in the field's `description` and in `docs/deprecations.md` instead. Announced now because a full-replace client cannot avoid sending both names, which is what [#60](https://github.com/openwrt-iac/uapi/issues/60) and [#65](https://github.com/openwrt-iac/uapi/issues/65) each cost a release to work around; one writable name per uci option removes the cause rather than resolving it per method.

- List-valued fields will read back `null` instead of `[]` when the underlying uci key is absent, targeted at v3 ([#39](https://github.com/openwrt-iac/uapi/issues/39)). uci cannot store an empty list, so `[]` already means "absent" and distinguishes nothing. This is a convention change across every curated resource and it breaks response validation for clients generated against the current `{"type": "array"}` schema, so it is announced here a major ahead rather than staged per field. Nothing changes in this release.

## [2.4.1] - 2026-08-03

### Fixed

- WireGuard peer writes now reach the kernel. A `POST`, `PUT` or `PATCH` on `network/wireguard_peers` committed the section to uci, answered `200`, and left the running tunnel untouched, so the peer did not exist as far as the kernel was concerned until something else restarted the interface. **`DELETE` had the matching hole: it answered `204` and the peer stayed live, so revoking a peer through the API did not revoke its access.** Operators who have deleted a peer through a release before this one and need that revocation to have taken effect should confirm with `wg show <interface> peers`.

  The cause is a platform-wide limitation rather than anything specific to uapi. netifd reads peer sections with `config_foreach wireguard_<iface>` inside the proto setup step, so a peer edit leaves the parent `interface` section unchanged, `/etc/init.d/network reload` finds nothing to converge, and does nothing at all. LuCI is affected too and documents the workaround in its own peer form ("Restart wireguard interface to apply changes"), because its Save and Apply resolves to that same `network reload` through a `config.change` event that carries only a package name and so cannot express which interface changed. uapi knows which resource was written, and therefore which interface is affected, so it applies the change itself.

  Each peer write is now pushed to the kernel with `wg set` after the commit: a set for a create or update, a remove for a delete, a remove for a peer being disabled, and a remove of the previous key before the set when a `PUT` rotates `public_key`. This is a new external command alongside the reload, `apk` and `passwd` calls uapi already makes. It is deliberate: WireGuard exposes no ubus service for peers, so netifd shells out to `wg` and so does LuCI's own backend. Asking netifd to re-apply instead was implemented and rejected on measurement, because the ubus call returns before the work happens and a failure takes the whole interface down: a single peer with an unresolvable `endpoint_host` dropped a working tunnel and its healthy peers while the API answered `200`. With `wg set` a bad peer fails alone, synchronously, and the write rolls back with the reason reported. uci remains the only config writer and the applied state is derived from committed uci, never from the request. `endpoint_host` is shell-quoted rather than newly validated, so no previously accepted payload starts being rejected; a preshared key is passed as a `0600` file and never as an argument.

  `route_allowed_ips` is applied too, with the routes spelled the same way netifd spells them and placed in `ip4table` / `ip6table` when the interface sets one; a prefix is withdrawn only once no remaining peer and no `config route` section still wants it. Peers on an interface that is down, or that netifd does not know, are written to uci and applied at the next `ifup`, as before. Closes [openwrt-iac/uapi#51](https://github.com/openwrt-iac/uapi/issues/51).

- `network/interfaces` no longer discards half of a body that sets `ipaddr` and `ipaddrs` to different addresses. Both are wire names for the same uci `list ipaddr`, and the list won whenever it was non-empty, so the scalar was dropped and the write answered `200` with the old address read back: a caller re-reading saw its own change vanish rather than fail.

  The answer differs by method, because the methods differ in what a caller can express. `POST` and `PATCH` report `422 validation_failed` with a `conflict` on `ipaddr`: naming both there is a choice, and `PATCH` can say which one it meant. `PUT` cannot. A full-replace caller sends every field it knows, the read mirrors the first list entry into `ipaddr`, so the scalar sits in its state even when its own config named only the list, and one of the two is stale by construction on every apply. Rejecting that body made `ipaddrs` unwritable through any such client. On `PUT` a differing `ipaddr` is therefore dropped in favour of the list, which is the precedence the write path already applied, so no uci outcome changes.

  **Carve-out (`docs/versioning.md`): the `POST` and `PATCH` rejection refuses a payload earlier releases accepted, and ships in a patch because the state it produced was one no caller could rely on.** The request said two different things about one option and was told neither had been ignored.

  The same collision made `PATCH` naming only `ipaddr` a silent no-op, since the merge folded the just-read `ipaddrs` into the body and that won. Whichever of the two the caller actually names now wins, and the other is dropped rather than resurrected from the server's own read. Closes [openwrt-iac/uapi#60](https://github.com/openwrt-iac/uapi/issues/60) and [openwrt-iac/uapi#65](https://github.com/openwrt-iac/uapi/issues/65).

- `network/wireguard_peers` accepts IPv6 and bare addresses in `allowed_ips`. The field required IPv4 CIDR notation, so **every IPv6 peer was refused and a dual-stack tunnel could not be configured through the API at all**, and a bare address was refused even though it is the form `wg show` prints back and netifd turns into a host route. All four shapes `wg` accepts (`10.0.0.0/24`, `10.0.0.5`, `fd00::/64`, `fd00::1`, and the `0.0.0.0/0` and `::/0` catch-alls) are now accepted, checked against `wg set` on a real interface, and what `wg` rejects is still rejected. This only widens what is accepted, so no payload that worked before stops working.

- `network/rules` accepts a packet mark as the only selector. It required one of `in`/`out`/`src`/`dest`, but `mark` is a selector in its own right and the one policy routing of reply traffic depends on: firewall4 marks in mangle prerouting and the rule sends the mark to a table, with neither source nor destination knowable in advance. `ip rule add fwmark 0x43 lookup 43` is valid, netifd writes exactly that from a rule carrying only `mark`, `lookup` and `priority`, and the kernel prints it back as `from all fwmark 0x43`. The check prevented nothing, since the workaround was to add `src: "0.0.0.0/0"`, which is what a mark-only rule already means. Closes [openwrt-iac/uapi#52](https://github.com/openwrt-iac/uapi/issues/52).

## [2.4.0] - 2026-07-31

Closes the gap between what the firewall resources advertise and what firewall4 actually applies. `target: "MARK"` was accepted but had no field to carry the mark value, so fw4 warned `must specify option 'set_mark' or 'set_xmark' for target 'mark'` and skipped the section: the write returned 200 and the rule silently never existed. Auditing the rest of the surface against fw4 found the same class repeatedly, plus the inverse (uapi rejecting configurations fw4 accepts). Closes [openwrt-iac/uapi#20](https://github.com/openwrt-iac/uapi/issues/20).

One item is a different and more serious shape than the rest, and is worth reading before upgrading: a port matched alongside a protocol that cannot carry one was not a no-op but a **widening**. firewall4 dropped the port and emitted the rule anyway, so it matched more traffic than asked for, and with the `all` wildcard it matched everything. Verified on hardware: `proto: ["all"]` with `dest_port: ["22"]` on an `ACCEPT` rule renders a bare `counter accept`. Such payloads are now rejected. See the entry under Fixed, and [openwrt-iac/uapi#24](https://github.com/openwrt-iac/uapi/issues/24).

### Upgrade note: payloads that were accepted and are now rejected

This release starts refusing configuration it previously wrote. Every shape below was already broken on the router before the upgrade: firewall4 was discarding the section, or emitting a rule matching more traffic than asked for, or the value was never validated at all. The `422` is not new breakage, it is the first time uapi says so.

Nothing here needs action on a router whose configuration uapi wrote and that has not been hand-edited. The risk is concentrated in sections adopted from an existing config, written by LuCI, or edited by hand, because those never passed through this validation.

| Payload | Result before | Why it was already broken |
|---|---|---|
| A port matched alongside a protocol that cannot carry one, on `firewall/rules`, `firewall/redirects` or `firewall/nat` | 200 | firewall4 dropped the port and emitted the rule anyway, so it matched the **whole protocol**. With `proto: ["all"]` it matched everything. |
| More than one value in a `firewall/redirects` `match` field (`src_ip`, `src_port`, `src_dport`, `dest_ip`, `dest_port`) | 200 | uci wrote a list, firewall4 refuses a list on those options and discarded the entire redirect. |
| `match.src_zone` or `match.dest_zone` set to `any` on `firewall/rules` | 200 | firewall4 has exactly one wildcard, `*`. `any` resolved against zone names, matched nothing, and the section was discarded. |
| `target: "NOTRACK"` with no source zone, or a wildcard one | 200 | firewall4 derives the chain name from the zone and discards the section without a named one. |
| A protocol token nftables cannot resolve (`ipcomp`, `l2tp`, `vrrp`), or a negated one | 200 | firewall4 renders the token verbatim and `nft -f` is atomic, so one unresolvable token rejected the **entire ruleset** and the router kept its previous firewall. A negated protocol had its negation silently dropped. |
| A port or address firewall4 cannot parse: out of range, a descending range, malformed | 200 | `firewall/rules` validated neither, so the section was discarded. |
| A zero-padded IPv4 octet such as `010.0.0.1` | 200 | `inet_pton` cannot read it, so firewall4 fell through to a network-name lookup, resolved nothing, and discarded the section. |
| A malformed IPv6 address such as `:::::` | 200 | Accepted by a character-class check, rejected by `inet_pton`, section discarded. |
| A non-contiguous netmask in an address firewall4 rewrites **to**: `snat_ip`, an SNAT redirect's `src_dip`, a DNAT redirect's `dest_ip` | 200 | firewall4 discards the section over one. Still accepted on match addresses, where it renders correctly. |
| A negated `match.dest_ip` on a DNAT redirect | 200 | firewall4 returns before emitting anything. Still accepted on an SNAT redirect, where `dest_ip` is an ordinary match. |
| `proto` or `dev_type` outside the accepted set on `openvpn/instances` | 200 | The enum reached the spec as the string `"NaN"`, which the type checker skips, so neither field was validated at all. |

Two of these were also widened while being enforced, so the new check is not simply stricter: the `openvpn` `proto` set gained the `tcp-client` and `tcp-server` spellings that luci-app-openvpn actually writes, and IPv6 validation now accepts the embedded-IPv4 form `::ffff:192.168.1.1` that the platform parses.

There is currently no way to ask a router which of its sections will be refused before writing to them; that gap is tracked in [openwrt-iac/uapi#47](https://github.com/openwrt-iac/uapi/issues/47).

### Added

- `firewall/rules` gains the `DSCP` target alongside the existing `MARK`, and the values they require: `set_mark` / `set_xmark` (value or value/mask, decimal or `0x` hex, 32-bit) and `set_dscp` (a symbolic class such as `CS0`, `AF11`, `EF`, `LE`, case-insensitive, or a number 0-63). A target that needs a value and does not have one is now a `422` instead of a rule the router discards.

- The `HELPER` target is deliberately **not** exposed. firewall4 accepts a `set_helper` naming any helper in its helpers file, but only emits the `ct helper` nftables object for helpers whose kernel module is loaded, and `nft -f` is atomic: a rule naming an unavailable helper makes the **entire ruleset** fail to load, leaving the router on its previous firewall. Helper modules ship as separate `kmod-nf-conntrack-*` packages and are absent by default, and uapi cannot verify availability from the resource layer (nor would a check hold, since the module can be removed later). Tracked as a follow-up.

- `firewall/rules` gains `match.mark` and `match.dscp`, each accepting a leading `!` for negation the way firewall4 does. `firewall/redirects` gains `match.mark`, the one match option fw4 accepts on a `config redirect`.

- New resource `firewall/nat` wrapping `config nat`, the only way to express MASQUERADE or exemption from source NAT. Targets are `SNAT` (with `snat_ip` / `snat_port`), `MASQUERADE`, and `ACCEPT`; the nested `match` block carries `src_zone` (the outbound, postrouting zone), `device`, addresses, ports, `proto`, and `mark`. Scope `firewall:nat`. Note `match.family` is deliberately not defaulted: firewall4 reads an absent family on a NAT section as IPv4-only for backwards compatibility, so reporting `any` would misdescribe the router; set it explicitly for dual-stack.

- `network/interfaces` gains `runtime.effective_proto`, the protocol netifd is actually running for the interface. It differs from the configured `proto` when the device has no handler registered for that protocol: netifd silently discards the value, reports `none`, and the interface is inert, while the write returns 200, uci keeps the value and a read-back returns it. `wwan` is the case that arises in practice, since its handler ships in the separate `wwan` package. Comparing the two fields is the only way to see the gap from outside, so a client can now detect and report it. The `proto` field description names the package each protocol needs. Closes [openwrt-iac/uapi#36](https://github.com/openwrt-iac/uapi/issues/36).

  Deliberately not a validation error. netifd registers handlers by scanning `/lib/netifd/proto` at startup and caches the result, and a `network reload` does not rescan, only a restart does. So a write refused for a missing handler could not be fixed by installing the package, which is the remedy such an error would have to recommend. The configuration is legitimate and only the runtime is behind it, which is what a runtime field is for.

### Fixed

- `firewall/redirects` models `src_dip`, the address firewall4 rewrites the source to on an SNAT redirect and matches the external destination against on a DNAT one. It was the only mandatory option of an SNAT redirect that uapi did not model, and because PUT is full-replace, leaving it out was destructive rather than merely limiting: verified on hardware that a plain read-modify-write of a working section returned 200, silently dropped `src_dip` and took two live nftables rules with it. The same loss applied to a DNAT section using `src_dip` for NAT reflection. With the field modelled it round-trips, and SNAT redirects are writable for the first time. Writes are refused exactly where firewall4 would discard the section: a missing or wildcard `match.dest_zone`, a missing `match.src_dip`, or a negated one. Source NAT on new configuration is better expressed with `firewall/nat`, which is where LuCI migrates these sections, and the `target` description says so. Closes [openwrt-iac/uapi#23](https://github.com/openwrt-iac/uapi/issues/23).

- **A redirect created through `firewall/redirects` was silently discarded by the router whenever it set `src_ip`, `src_port`, `src_dport`, `dest_ip`, or `dest_port`.** firewall4 marks only `proto`, `src_mac`, and `reflection_zone` as list options on a `config redirect`; the rest are scalars, and its `parse_opt` refuses a list outright, dropping the whole section. uapi modelled all of them as arrays and uci writes an array as a `list`, even for a single element, so the write returned 200 and the port forward never existed. The wire type stays an array for compatibility, but at most one value is accepted (a second is now a `422` rather than a dead rule) and uci receives a scalar. Sections adopted from an existing config were unaffected, which is why the failure went unnoticed.

- `firewall/rules` treated `match.src_zone` / `match.dest_zone` value `any` as a wildcard synonym for `*`. firewall4 has exactly one wildcard, `*`; `any` resolves against zone names, matches nothing, and the section is discarded. uapi additionally suppressed the "zone does not exist" error for it, so the operator got a stronger signal that the value was valid. `any` is now checked against real zones like any other name.

- Ports and addresses are validated against what firewall4 actually parses, across all three firewall resources. Previously `firewall/rules` validated neither, so `dest_port: ["70000"]` or a typo'd address returned 200 and the router discarded the rule; `firewall/redirects` bounded neither the magnitude nor the ordering of a range while rejecting fw4's `!` negation and `:` range separator, and accepted only bare IPv4 in `dest_ip`, rejecting IPv6, prefixes, ranges, and uci network names it resolves happily.

- The `proto` enum across the firewall resources rejected protocols firewall4 supports, including `gre`, `sctp`, `ipv6-icmp`, numeric values, `*`, and `tcpudp`, which is fw4's own default token and what LuCI writes. Accepted values are now exactly the tokens nftables can resolve, checked case-insensitively as fw4 does, with protocol numbers bounded at 255. The distinction matters more than it looks: fw4 renders the token verbatim into `meta l4proto`, nft resolves it against its own built-in table rather than `/etc/protocols`, and because `nft -f` is atomic an unresolvable token rejects the **entire ruleset** rather than one section. `ipcomp`, `l2tp`, and `vrrp` are in `/etc/protocols` but not resolvable by nft, so they are refused.

- `firewall/redirects` rejected `match.dest_zone: "*"`, which firewall4 permits on a DNAT (only the source side forbids the wildcard), and never checked `reflection_zone` against real zones, where a misspelling discards the entire port forward rather than just its loopback rules.

- `firewall/rules` no longer requires `match.src_zone` on every rule. firewall4 requires a source zone only for `NOTRACK`, whose chain name is derived from it; a rule without one is valid and lands in the `output` or `mangle_output` chain. Rules that omit it were previously rejected with a `422` uapi had no basis for.

- Conversely, `NOTRACK` now requires a **named** source zone: `match.src_zone` absent or set to the `*` / `any` wildcard is rejected. This is deliberate: firewall4 discards those sections outright (`must specify a source zone for target ...`), so the only configurations affected are ones that were already silently dead on the router.

- **A port matched alongside a protocol that cannot carry one was silently widened into a rule matching the whole protocol.** firewall4 assigns `src_port` / `dest_port` only inside its `case "tcp": case "udp":` branch, so for any other protocol the ports are dropped and the rule is still emitted. The wildcard is the worst case rather than an exemption: `{proto: ["all"], dest_port: ["22"]}` on an `ACCEPT` rule renders a rule accepting **everything**, because fw4 emits neither a protocol match nor a port match for it. Unlike the other defects in this release this is a widening rather than a no-op, so it fails validation on `firewall/rules`, `firewall/redirects` and `firewall/nat`. `firewall/nat` keeps one carve-out that the other two cannot have: a list of nothing but wildcards is accepted there, because `config nat` is the only section type fw4 runs `ensure_tcpudp` over, rewriting it to tcp+udp before the ports are read. A protocol list with no ports is unaffected, as is an absent `proto`, which fw4 defaults for itself. Closes [openwrt-iac/uapi#24](https://github.com/openwrt-iac/uapi/issues/24) in part.


- **`openvpn/instances` published a malformed `enum` for `dev_type` and `proto`, and validated neither field.** The schemas built the value with `keys(VALID_X) + [null]`, and ucode's `+` on two arrays does not concatenate: it coerces, yielding NaN, which the JSON encoder wrote as the string `"NaN"`. Both fields therefore shipped `"enum": "NaN"` where an array is required, so a code generator reading the published spec saw a broken enum on the only two fields of that resource with a closed value set. It also disabled the check at runtime, because `check_schema_types` skips a non-array enum, so any value at all was accepted. Nothing caught it: `openapi-check` only diffs the generated file against the committed one, and both were malformed identically. Found by running a real OpenAPI 3.1 validator over the document for the first time. Two new gates now stand behind it, `make lint`'s `lint-openapi-shape` and CI's `make openapi-validate`. Closes [openwrt-iac/uapi#27](https://github.com/openwrt-iac/uapi/issues/27).

- Repairing that enum makes `openvpn/instances` validate `proto` and `dev_type` for the first time, so a value outside the accepted set is now a `422` where it was previously stored unchecked. The accepted `proto` set was widened to everything openvpn takes before switching the check on: it had listed only `udp`, `tcp`, and the numbered variants, omitting the `tcp-client` and `tcp-server` spellings that luci-app-openvpn actually writes. Enforcing the narrower list would have rejected configuration the frontend most operators use produces.

- **A read-modify-write of any section holding a write-only secret either destroyed the secret or was impossible.** `private_key`, `key`, `preshared_key`, `tls_auth` and `pkcs12` are masked on read, surfacing only a `has_*` boolean, so a client that GETs a section cannot send the secret back. Each resource restored it inside its own `merge_for_patch`, which only the PATCH paths call; PUT is full-replace and had no equivalent, so it deleted the stored value. Where the field is optional the write returned 200 and silently erased the secret, the same shape as the `src_dip` loss above; where it is required (a wireguard interface, or a wireless interface whose encryption needs a key) validation rejected the body and the section could not be written through PUT at all. The carry-forward now lives in the handler, keyed on the `writeOnly` annotation the schemas already carried, and applies to every write path. An omitted **and** an explicit null secret both mean "keep": an IaC client that emits null for unset optional attributes must not destroy a working key, so clearing a secret remains deliberately inexpressible. Verified against a router's real wireguard interfaces, which previously could not be written back at all. Closes [openwrt-iac/uapi#30](https://github.com/openwrt-iac/uapi/issues/30).

- Non-contiguous netmasks are refused on the three addresses firewall4 rewrites **to** rather than matches on: `snat_ip` on `firewall/nat`, `match.src_dip` on an SNAT redirect, and `match.dest_ip` on a DNAT redirect. fw4 discards the whole section over one there. They remain accepted on every match address, where fw4 deliberately supports them and renders them as `saddr & <mask> == <addr>`; validating them uniformly would have rejected working configuration.

- A negated `match.dest_ip` is refused on a DNAT redirect, matching the guard firewall4 applies just before it gives up on the section. It stays valid on an SNAT redirect, where `dest_ip` is an ordinary match.

- Zero-padded IPv4 octets such as `010.0.0.1` are rejected. `inet_pton` parses an octet with base 0, so firewall4 cannot read the address at all, falls through to a uci network-name lookup, resolves nothing and discards the section. Same reasoning as the protocol-number spelling already enforced, and confirmed against `iptoarr` on a router.

- IPv6 validation was both too loose and too strict, in ways that each had a consequence. It accepted addresses `inet_pton` rejects, such as `:::::`, which reach the router and discard a section; and it refused the embedded-IPv4 form `::ffff:192.168.1.1`, which the platform parses and applies. Validation now follows the real grammar in both directions: at most one `::`, at most four hex digits per group, exactly eight groups once expanded, and an embedded IPv4 tail permitted only in the final 32 bits. This affects every resource that validates an address, not only the firewall ones.

- **`runtime` is now annotated `readOnly` on every schema that carries it, not just the three that document its shape.** It is derived from ubus and `toUci` ignores it, so it is never writable on any resource, but 42 of the 45 emitted a bare `{"type": "object"}` with no annotation, which a code generator reads as an ordinary writable free-form map. Regenerate any client that derives writability from the spec. `lint-openapi-shape` now asserts the annotation so it cannot go missing again. Reported from downstream while building provider support for this release, found by diffing the spec. Closes [openwrt-iac/uapi#40](https://github.com/openwrt-iac/uapi/issues/40).

- `firewall/rules` no longer lists `match` as required. It was accurate at v2.0.0, when every rule needed a source zone and therefore a `match` object to hold it; relaxing `src_zone` to NOTRACK-only earlier in this release made a match-less rule valid, and the spec kept advertising the old constraint. The server has always accepted such a rule, so this only stops the document overstating. `firewall/redirects` keeps the requirement, where it is real because `src_zone` is mandatory there, and `firewall/nat` still has none. Closes [openwrt-iac/uapi#42](https://github.com/openwrt-iac/uapi/issues/42).

- `/firewall/nat` stays singular, deliberately: `nats` reads badly and `nat_rules` would diverge from the `config nat` section type and from what LuCI calls it. The exception is now recorded at the endpoint declaration and allowlisted in the plural-collection lint rule, so it is enforced rather than remembered. Closes [openwrt-iac/uapi#41](https://github.com/openwrt-iac/uapi/issues/41).

### Internal

- `BatchOperation.body` declares `type: object` instead of being left untyped. Its shape is whatever the target resource accepts, so the spec cannot say more, but an untyped schema is precisely where the malformed `enum` above hid from every check that walks the document.

- `lint-openapi-shape` gains two rules, both prompted by spec defects a downstream consumer found by diffing rather than by any gate here: `runtime` must be `readOnly` wherever it appears, and a collection path segment must be plural unless allowlisted with a reason. A collection is identified structurally, by having a sibling `{id}` path, so neither rule guesses at naming. Closes [openwrt-iac/uapi#43](https://github.com/openwrt-iac/uapi/issues/43).

- `values.uc` gains `MARK_RE` / `MARK_MATCH_RE` / `MARK_MAX` and `masked_value_exceeds()`, shared by the three resources that now expose a mark so the accepted syntax cannot drift between them. The schema `pattern` constrains shape; `masked_value_exceeds` catches the bound a pattern cannot express, since a 10-digit decimal still overflows 32 bits and a 2-digit DSCP still exceeds 63.

- Where fw4 and LuCI disagree on accepted values, uapi follows fw4. LuCI's DSCP validation omits `LE` and is case-sensitive; fw4 accepts both, and fw4 is what applies the configuration, so a value the router honours is never rejected at the API.

- `firewall/nat` models `match.src_ip`, `match.src_port`, `match.dest_ip`, and `match.dest_port` as scalars, not arrays. firewall4 marks only `proto` as a list option on a `config nat` section; the others are scalars, and its `parse_opt` refuses a list outright ("option must not be a list") and discards the whole section. The sibling `config rule` and `config redirect` types do mark them as lists, so the arity genuinely differs per section type.

- Address and port fields on `firewall/nat` are validated against what firewall4 actually parses, in both directions. Addresses (`snat_ip`, `match.src_ip`, `match.dest_ip`) are typed `network` by fw4, which resolves a bare address, a prefix in either family, an address range, or a uci network name; uapi accepts exactly those forms, in fw4's own parse order, and additionally refuses the negation fw4 forbids on `snat_ip`. Ports accept fw4's full grammar (`80`, `1000-2000`, `1000:2000`, and a leading `!` on match ports but not on `snat_port`) and are bounded at 65535 with an ordered range, because a port fw4 cannot parse means it discards the whole section.

## [2.3.0] - 2026-06-24

Surfaces the known scope tree through a sanctioned interface so external consumers (the upcoming `luci-app-uapi` LuCI frontend, fleet inventory tools, anything that wants to render a scope picker) can enumerate valid scopes without parsing `src/lib/scope.uc` or hardcoding a copy. Closes [openwrt-iac/uapi#5](https://github.com/openwrt-iac/uapi/issues/5). Also plumbs per-token `rate` / `burst` overrides through the mint surfaces, closing a "planned for v2.x" gap that has been carried in `docs/tokens.md` since 2.0.

Commit-confirmed apply (the `?confirm` / `/confirm` surface) was present in the 2.3.0-rc1 pre-release and has since been deferred; it is not part of the 2.3.0 stable surface. The confirm wire contract is intentionally not frozen into v2 until its authz model is settled and a consumer needs it, so it does not lock in a contract that could only be changed with a major bump. See `docs/commit-confirm.md` and `docs/roadmap.md`.

### Added

- New CLI subcommand `uapi-token scopes` printing one scope path per line (sorted, greppable). Pair with `--json` for a JSON array suitable for piping into `jq` or any other consumer. The CLI is the durable cross-package interface; it works from any shell, Ansible playbook, or fleet inventory tool that can `ssh` to the router.

- New `scope.known_paths()` module export returning a sorted array of scope paths. ucode consumers on the same box (the LuCI frontend in particular) `require('scope')` and call this directly, matching how `uapi-token` itself imports the module.

Both surfaces enumerate the same internal `KNOWN_PATHS` const; the accessor (rather than a direct const export) lets the underlying representation change without breaking consumers.

- `POST /tokens` accepts optional `rate` and `burst` integer fields; `uapi-token create` accepts `--rate <N>` and `--burst <N>`. Both write `option rate '<N>'` / `option burst '<N>'` on the token's uci section. The request-path rate limiter (`src/lib/ratelimit.uc`'s `effective_limits()`) has been reading these uci options since 2.0.0; only the mint side was missing. `uapi-token show <name>` also now surfaces the configured rate/burst when set.

The OpenAPI vendor-extension option from the issue thread is deferred until a code-generated client surfaces with a concrete need; premature spec annotations without consumer evidence is what 2.2.2 / 2.2.3 corrected.

### Fixed

- PATCH no longer deletes uci options the resource does not model. Previously every write verb shared one `diff_apply` that deleted any existing uci option not re-emitted by `toUci`, so a partial PATCH (e.g. changing `unbound` verbosity, or any field on `firewall.rules`) silently wiped hand-set or stock options the curated model omits (`dns64_prefix`, `icmp_type`, `synflood_protect`, cert `key_type`/`ec_curve`, `ttylogin`, and many more). PATCH now preserves them (RFC 7396 merge-patch: only options inside the resource's own modeled footprint are touched). PUT keeps full-replace semantics: it normalizes the section to the modeled set, so unmodeled options are intentionally dropped on a PUT. An audit of all curated resources against their stock OpenWrt configs found this affected 13 resources.

- A JSON Patch (RFC 6902) that does not touch a write-only secret no longer drops it. The JSON Patch post-image is built from the masked read view (which exposes `has_key`, not `key`), so a patch that left the secret alone previously produced a post-image without it and tripped conditional-required validation ("key is required when encryption is ..."). The write path now carries forward any `writeOnly` field the patch did not set (`key`, `preshared_key`, `private_key`, `tls_auth`, `pkcs12`), matching what the merge-patch path already did; a patch that explicitly sets a new secret is left intact.

- Three validation rules relaxed to match what stock OpenWrt ships (found by the same audit): `wireless.devices` accepts an empty `country` (read back as null) and the `"00"` world regulatory domain (stock 6 GHz default); `wireless.interfaces` accepts `encryption='owe'` (Opportunistic Wireless Encryption, keyless, the stock 6 GHz default) without demanding a key; `network.devices` no longer requires `type`, so a `config device` options-override section (name + macaddr, no type, as `config_generate` emits on some targets) round-trips.

### Internal

- New integration test `tests/integration/44_stock_config_test.sh` round-trips every curated CRUD resource and singleton whose package ships in the bare OpenWrt 25.12.4 image (firewall, network, dhcp, dropbear, system): GET the section, adopt if unmanaged, PUT-self (or PATCH-self for singletons), then GET again and assert the persistable shape did not drift. A 422 or a diff surfaces a regression where uapi rejects (or silently mutates) what the platform itself ships. Resources from optional packages (snmpd, lldpd, vnstat, mwan3, etc.) are deferred to a follow-up that wires their install at VM-setup time. First run forced four schema relaxations to bring API rules in line with the platform: `igmp` accepted by `firewall.rules`/`firewall.redirects`; `*`/`any` wildcards accepted by `firewall.rules` zone refs; `dhcp.servers` no longer requires the referenced network interface to exist (stock ships `dhcp.wan` against an absent `network.wan` on x86); `is_valid_cidr_any` accepts IPv6 CIDR (used by `mwan3.rules` once mwan3 coverage lands).

## [2.2.3] - 2026-06-19

OpenAPI spec correctness fix on the `x-uapi-clear-on-omit` annotation introduced in 2.2.2. Caught by the terraform-provider-uapi agent before any consumer built against it.

### Fixed

- Drop `"x-uapi-clear-on-omit": true` from three `network/interfaces` fields whose fromUci shapes are incompatible with the Terraform plugin-framework's plain-Optional contract: `ipaddr` (derived from `ipaddrs`, the two alias to the same uci key), `ipaddrs` (`as_list()` returns `[]` for absent, not null), and `dns` (same `as_list()` empty-list coercion). A plain-Optional Terraform attribute MUST read back null when config omits it; anything else fails the apply with "Provider produced inconsistent result after apply." The flag stays on `netmask` and `gateway`, which read back null cleanly.

- The 2.2.2 criterion ("caller-owned and not defaulted") was too loose. The corrected criterion: a field carrying `"x-uapi-clear-on-omit": true` MUST have a fromUci assignment of exactly `<jsonkey>: section.<ucikey> ?? null` (no `as_list()`, no derivation, no aliasing) AND a `type:` declaration that includes `"null"`. `docs/adding-a-resource.md` documents both rules with safe/unsafe example pairs.

### Internal

- `make lint-defaults` gains two new checks:
  - `check_clear_on_omit_shape`: verifies each flagged field's fromUci RHS is `section.X ?? null`.
  - `check_clear_on_omit_type`: verifies each flagged field's `type:` declaration includes `"null"`.

  Both would have caught the 2.2.2 mistake at lint time. Verified by reverting the annotation drops and confirming all 3 violations fire before re-applying.

### Out of scope (deferred to openwrt-iac/uapi#3)

The original field-report leftover case (adopted `wan` carrying static `ipaddr`/`gateway`/`netmask`/`dns` after switching to `proto=dhcp`) is now partially closed: `netmask` and `gateway` can be cleared via clear-on-omit; `ipaddr`/`ipaddrs`/`dns` need a different clearing path. Three options sketched on the issue thread; the design call is its own conversation.

## [2.2.2] - 2026-06-19

OpenAPI spec enrichment to support the terraform-provider-uapi clear-on-omit work. No wire-surface change on any CRUD endpoint; no runtime behavior change; the `/openapi.json` document gains per-property annotations that downstream codegen consumes.

### Added

- `default: <value>` on every `schema_properties` field where uapi's `fromUci` synthesizes an unconditional fallback (`normalize_bool(section.X, true|false)`, `section.X ?? "literal"`). ~88 annotations across ~25 curated resources. Standard OpenAPI 3.1 / JSON Schema 2020-12 keyword; clients (Redoc, openapi-codegen, the terraform-provider-uapi spec ingester) surface it natively. Conditional defaults (e.g. `network.interfaces.peerdns` defaults to true under `proto=dhcp` only) are intentionally NOT annotated because the literal value would mislead under other protos.

- `"x-uapi-clear-on-omit": true` vendor extension on caller-owned, non-defaulted fields that are safe for an IaC client to clear when the operator's config omits them. Conservative scope: `network/interfaces` static-proto fields (`ipaddr`, `ipaddrs`, `netmask`, `gateway`, `dns`) surfaced by the 125-resource Terraform apply field report behind [openwrt-iac/uapi#3](https://github.com/openwrt-iac/uapi/issues/3). Other resources can opt in once concrete leftover-prone shapes surface in the field. Mutually exclusive with `default:`; a field cannot be both defaulted and clearable without producing perpetual non-converging diffs.

### Internal

- Load-bearing WHY comment in `src/lib/handler.uc` near `_check_value` declaring that `default:` in `schema_properties` is OpenAPI documentation only; the framework MUST NOT apply it. `fromUci` owns server-side defaults. A future change that silently fills absent fields from `default:` would defeat PATCH delta semantics and break the provider's clear-on-omit work.

- New `make lint-defaults` (folded into `make lint`): shell-grep check that every `normalize_bool(section.X, V)` and `section.X ?? "literal"` pattern in `src/resources/*.uc` has a corresponding `default: V` in the same file's `schema_properties` block. Catches the drift case where a new defaulted field lands without the annotation.

## [2.2.1] - 2026-06-18

Bug fix surfaced by a 125-resource Terraform apply on real hardware ([openwrt-iac/uapi#4](https://github.com/openwrt-iac/uapi/issues/4)). The 2.2.0 pre-create uniqueness check guarded the section id but missed the value-collision case for resources whose cross-section reference key is a separate option (e.g. fw4 keys forwardings/rules/redirects on `firewall.zone.name`, not the section id). A managed create with `name="lan"` next to the box's default `lan` zone produced two `firewall.zone` sections with the same `name` value, which fw4 could not disambiguate.

### Changed

- Pre-create and pre-modify (`POST` / `PUT` / `PATCH`) now reject payloads whose value in a resource's cross-section reference field collides with another section of the same type in the same package. The check returns `422 conflict` naming the offending section, which surfaces the correct workflow to callers: use `POST .../adopt` (Terraform: `terraform import`) to take over an existing section rather than creating a duplicate.

  Affected resources: `firewall/zones` (`name`), `network/devices` (`name`), `sqm/queues` (`interface`). `dhcp/servers` was already self-checking; its existing per-resource check is unchanged. All other resources are unaffected.

  Tightening previously-accepted payloads is technically a breaking change under strict semver reading, but the previously-accepted behavior produced broken state no caller can rely on (two same-named zones, two sqm queues on one interface, etc.), so it ships as a patch.

### Internal

- New optional `unique_field` declaration on curated resource modules. Framework reads it in `handler.uc.make()` to drive the new uniqueness check. Documented at `docs/adding-a-resource.md`.

## [2.2.0] - 2026-06-12

Three field-feedback items from a real OPNsense-to-OpenWrt migration drove this release. The naming-model items (callers want to keep meaningful section names like `lan` / `wan` instead of getting ULIDs) land here; the apply-with-rollback / commit-confirmed safety net is tracked as an open design question at [openwrt-iac/uapi#3](https://github.com/openwrt-iac/uapi/issues/3) and didn't make this cut.

Validated end-to-end across two RC cycles: rc1 on a 14-resource Terraform config against a PC Engines APU2 (OpenWrt 25.12.4), rc2 with the over-restriction fixes the rc1 testing surfaced.

### Added

- Settable `id` at create on every CRUD resource. `POST /<resource>` now accepts an optional `id` field at top level; when supplied it becomes the uci section name AND the response `id`. When absent the server emits the existing ULID. Validation runs once in the framework: uci section-name charset, 32-char default cap, and in-package uniqueness across all section types (so `POST /firewall/rules` with `id: "lan"` while a zone `lan` already exists returns `422 conflict` cleanly instead of failing on commit). Per-resource modules can tighten further; `network/interfaces` keeps its IFNAMSIZ-tight 15-char cap for `proto=wireguard` since netifd binds the uci section name to the kernel netdev name.
- `create_if_missing` opt-in flag on singleton resource modules. When set, `PATCH /<singleton>` creates the underlying uci section (named `main`) if absent instead of returning 404. Applied to `/unbound/srv` and `/unbound/ext` because their extension UCI packages can be wiped by an operator without uapi getting any warning; other singletons stay opt-out so a missing section keeps surfacing as a real problem.

### Changed

- `POST /<resource>/<existing-id>/adopt` keeps the existing section name when the target section is already named. Previously adopt always renamed the section to a ULID, which broke uci cross-references where other sections referenced this one by name (e.g. `firewall.zones.lan` referenced by `firewall.rules.src_zone = "lan"`). Anonymous (`cfgXXXXXX`) sections still get renamed to a managed id, since they had no stable name to begin with. Named sections become an idempotent acknowledgement: keep the name, return the existing view, no service reload (the previous path called `reload(services)` unconditionally on the success path; N adopts during a Terraform import fired N firewall/network reloads).
- `network/devices` no longer requires `ports` when `type=bridge`. uci and netifd accept portless bridges; the 2.1.0 validation was stricter than the platform, which inverted Terraform's create-bridge-before-members ordering, blocked incremental bridges, and rejected adoption of pre-existing portless bridges. The validate check and the `openapi_conditional` clause are both removed; `toUci` already handled the empty-list case correctly.
- `dhcp/hosts` no longer requires `ip`. dnsmasq accepts entries with just `mac` + `name` for DNS-only reservations (hostname-to-MAC mapping without a static lease), and the resource already has a `dns: bool` field reflecting that workflow. The validate check and the `openapi_required: ["ip"]` entry are removed; the existing `openapi_conditional` that requires either `mac` or `duid` (the actual platform constraint) stays.

### Deprecated

- `network/interfaces.name` (request input) in favour of the universal `network/interfaces.id`. Both are accepted during the deprecation window; if both are supplied they must match. The OpenAPI spec marks `name` as `deprecated: true`. Removal is scheduled for v3. See `docs/deprecations.md`.

### Policy

- Field renames within a major release are now allowed when paired with a deprecation window (both old and new accepted, old marked `deprecated: true` in the OpenAPI spec, removal scheduled for the next major). The deprecation log at `docs/deprecations.md` is the operator-facing source of truth.

### Documentation

- `docs/adding-a-resource.md` grows a "Validation should not be stricter than the platform" section pointing at the bridge and DNS-only-host antipatterns as canonical examples. Catching client mistakes is the point of `validate()`; inventing constraints uci/netifd doesn't have is not.

## [2.1.0] - 2026-06-07

Two themes in one release: new curated singletons for the
`unbound-uci-ext` package, plus the infrastructure move to the
`openwrt-iac` GitHub organisation (originally staged on `main` for a
2.0.3 tag that was rolled into 2.1.0 instead, since no API change
had shipped under 2.0.3).

### Added

- Curated `unbound/srv` + `unbound/ext` singleton resources.
  Wrap the UCI namespaces provided by the new `unbound-uci-ext`
  package (separate repo: `openwrt-iac/unbound-uci-ext`), exposing
  the unbound `server:` clause directives + outside-server clauses
  that the main unbound package deliberately keeps out of UCI.
  Install `unbound-uci-ext` from the openwrt-iac feed first; if the
  daemon is absent, uapi returns `503 init_script_missing` cleanly
  via the standard pre-flight (no partial state).
  - `GET` / `PATCH /api/v2/unbound/srv` carries `interface_bind` (list),
    `interface_outgoing` (list), `ip_transparent` (bool), `srv_line`
    (list, verbatim passthrough). Plus the standard `enabled`
    switch. Pair with `unbound.@unbound[0].interface_auto = false`
    on the existing `unbound/server` singleton for exclusive
    binding (loopback-only recursive resolvers behind dnsmasq is
    the canonical case).
  - `GET` / `PATCH /api/v2/unbound/ext` carries `ext_line` (list, one
    entry per rendered line; build whole `forward-zone:` / `view:` /
    `stub:` / `remote-control:` clauses by listing them in order).
  - New scopes `unbound:srv`, `unbound:ext`. The existing
    `unbound:*` umbrella covers both alongside `unbound:server`.

### Notice: feed and site URLs moved

The signed apk feed and the project site have moved from
`raspbeguy.github.io/uapi/...` to `openwrt-iac.github.io/...`. The
old URLs will stop serving fresh APKs after a 30-day grace period.
To migrate, replace the contents of
`/etc/apk/repositories.d/uapi.list` and
`/etc/apk/keys/uapi-feed.pub.pem` with the new feed:

```sh
curl -fsSL https://openwrt-iac.github.io/feed/uapi-feed.pub.pem \
    | tee /etc/apk/keys/uapi-feed.pub.pem > /dev/null
echo 'https://openwrt-iac.github.io/feed/packages/all/uapi/packages.adb' \
    > /etc/apk/repositories.d/uapi.list
apk update
```

The new feed aggregates stable releases from every repo under the
`openwrt-iac` org (uapi, `unbound-uci-ext`, ...), so one feed line
installs any of them. The signing key was rotated as part of the
move; the new public key is served from the feed root.

### Repository moves

- `raspbeguy/uapi` → `openwrt-iac/uapi` (this repo).
- New: `openwrt-iac/unbound-uci-ext`, the extension package exposing
  unbound `server:` directives that the main unbound package
  deliberately keeps out of UCI.
- New: `openwrt-iac/openwrt-iac.github.io`, the site + feed aggregator
  (signed apk index rebuilt from each source repo's latest stable
  GitHub Release).

GitHub redirects `raspbeguy/uapi/...` URLs to the new owner for
~60 days; bookmarks and git remotes should be updated. Tags and
commit history are preserved.

### Removed

- `.github/workflows/publish-web.yml`: the static site is no
  longer published from this repo; lives in
  `openwrt-iac/openwrt-iac.github.io:web/`.
- `.github/workflows/feed-purge-rc.yml`: the feed aggregator
  filters prereleases at the source via
  `gh release list --exclude-pre-releases`, so a scrub workflow is
  no longer needed here.
- The `Publish to APK feed on gh-pages` step in `ci.yml`:
  release-apk now attaches the APK to the GitHub Release and stops
  there; the aggregator picks it up.
- `web/` and `keys/` directories, migrated to the org-site repo.
- `FEED_SIGNING_KEY` repo secret, moved to the org-site repo.

## [2.0.2] - 2026-06-05

Bug-fix patch addressing two items from a real-world v2.0.0 field
migration (a ~127-resource OPNsense -> OpenWrt cutover driven through
`terraform-provider-uapi`). Strictly additive on the wire surface
(C1's `name` field is opt-in); compatible with every existing v2.0.x
client.

### Added

- **Caller-supplied `name` on `POST /network/interfaces` (every proto).**
  Interface section names are first-class semantic handles in OpenWrt
  (referenced by firewall zones, routes, dhcp servers, sqm queues;
  visible in `uci show network`; shown by LuCI). uapi now lets the
  caller pick the section name:

  ```json
  { "proto": "wireguard", "name": "wg_prod",
    "private_key": "...", "addresses": ["10.0.0.1/24"] }

  { "proto": "static", "name": "guest",
    "ipaddr": "192.168.99.1", "netmask": "255.255.255.0" }
  ```

  Validation: `^[A-Za-z][A-Za-z0-9_]{0,14}$` (uci section-name
  charset, IFNAMSIZ-tight; one rule across every proto). Only valid
  at create time (PUT/PATCH reject with `read_only`; rename via
  DELETE + POST). Must not clash with an existing section in the
  `network` package. The `name` becomes the uapi `id`; GETs return it
  under `id` only (the field is request-only).

  When `name` is absent, the server emits a 14-char `wg_<11-char>`
  fallback for `proto=wireguard` or the standard 28-char ULID
  otherwise.

  Touched: `src/lib/ids.uc` (length param on `new_id`),
  `src/lib/handler.uc` (new `id_for_create(body)` resource hook,
  used by `create()` and `adopt()` to override the standard ULID),
  `src/resources/network.interfaces.uc` (the `name` schema property,
  validation, and the `id_for_create` implementation).

### Fixed

- **WireGuard tunnels can finally come up.**
  In v2.0.0/v2.0.1, posting `proto=wireguard` to `/network/interfaces`
  silently created a config that could never bring the tunnel up:
  uapi named every managed section with a ~28-char ULID, but netifd's
  `wireguard.sh` uses the section name verbatim as the kernel netdev
  name, and Linux IFNAMSIZ caps interface names at 15 chars. The
  write returned 200; `logread` carried the actual failure
  (`Attribute failed policy validation`). Worst kind of bug: 2xx
  response, no client signal, broken on the box.

  Fixed by the `name`/`id_for_create` machinery from the Added entry
  above: wireguard interfaces either get a caller-supplied name or
  the IFNAMSIZ-fitting `wg_<11-char>` fallback. Adoption of
  anonymous `proto=wireguard` sections also uses the short-id format;
  before this fix, adopting an anonymous wireguard section also broke
  the netdev.

- **`423` message identifies the actual lock under contention.**
  Same-package writes serialise on the per-package EX (the design;
  cross-package writes still parallelise via SH on the global). The
  `423 locked` response in v2.0.0/v2.0.1 always said
  *"Another write transaction holds the global lock"*, which sent
  operators debugging in the wrong direction when the actual blocker
  was on the per-package EX. The message now branches:

  - `Another write transaction holds the per-package lock for '<pkg>'`
    - another uci writer holds the same package's EX. This is the
    common case under Terraform parallelism for same-package fleets.
  - `A non-uci writer holds the global write lock` - a `with_lock`
    path (`apk` install/remove, `system/password`,
    `system/authorized_keys`) is in flight.

  Touched: `src/lib/transaction.uc` (`default_acquire_pkg` returns
  `{ contention: "global"|"package" }` so `transaction()` can
  distinguish; `multi_transaction` and `with_lock` emit the same
  shape), `src/lib/errors.uc` (`locked(ctx, retry_after, info?)`
  branches the message; new `locked_from(ctx, retry_after, result)`
  helper that pulls `lock_kind`+`package` out of a transaction result
  so every call site is one line and another miss is unrepeatable),
  `src/lib/handler.uc` + `src/raw.uc` + `src/main.uc` +
  `src/lib/non_uci.uc` (all five locked-translation sites pass the
  info through).

### Documentation

- `CLAUDE.md` Concurrency section now states the actual two-tier
  lock model (SH on global + EX on per-package, vs. EX on global for
  non-uci writes) and the per-package vs. global distinction in the
  423 message. The previous one-line "Writes acquire a global flock"
  predated the v1.1 per-package design and was outdated.
- `CLAUDE.md` resource module contract gains the new optional
  `id_for_create(body)` field plus a paragraph documenting the
  `proto=wireguard` ULID exception (the only case in v2.x where the
  section name is consumed as a kernel object name).
- `docs/concurrency.md` adds two subsections: "423 message identity"
  (what the new wording means) and "Terraform parallelism" (when to
  drop to `-parallelism=1` for same-package fleets).
- `docs/errors.md` 423 row updated to match.

### Operator note

For clients that drive same-package fleets under default Terraform
parallelism (`-parallelism=10`): the provider's existing
retry-with-backoff continues to absorb the 423s. The change here is
purely the wording of those 423s; no behaviour change. For very
large same-package fleets (>100 writes), consider
`-parallelism=1` for that resource type; see
`docs/concurrency.md` for the trade-off.

## [2.0.1] - 2026-06-05

Bug-fix patch. Fixes a correctness issue in optimistic-concurrency
behavior reported against v2.0.0: per-resource ETags were polluted by
sibling-section state in the same uci package, causing legitimate
`If-Match` writes to fail with `412 precondition_failed` when an
unrelated sibling section changed.

### Fixed

- **Per-resource ETags are no longer package-global.**
  In v2.0.0, the `_deps_hash` mechanism walked every section of a
  resource's declared `depends_on` type via `uci_foreach` and folded
  the whole set into the ETag. Adding, mutating, or deleting an
  *unrelated* sibling section shifted every other resource's ETag,
  including resources the sibling did not reference. Real-world
  surface: a multi-resource `tofu destroy` left rules behind because
  deleting a firewall zone shifted the rule's ETag mid-run, and the
  rule's `DELETE` carried the now-stale `If-Match` from plan time.

  The fix makes the ETag a pure hash of the resource's own normalized
  body (the `runtime` block is still excluded, as before). Sibling
  sections in the same uci package no longer influence each other's
  ETags, so `If-Match` fires only when *this* resource has actually
  changed. The behavior previously documented and announced as
  "Dependency-aware ETags" (v2.0.0-rc1 entry, lower in this file) is
  **removed**: the cross-reference invariants those resources care
  about (`rule.src_zone -> zone exists`, `member.interface -> interface
  exists`, etc.) were already enforced at `resource.validate()` time on
  every write, so the ETag mix added no real protection.

  Touched: `src/lib/handler.uc` (deletes `_deps_hash`, `_canon_section`,
  `etag_with_deps`; simplifies `compute_etag`/`set_etag_header`/
  `precondition_check` signatures); 11 resource modules drop their
  `depends_on` declaration (`firewall.rules`, `firewall.redirects`,
  `firewall.forwardings`, `dhcp.servers`, `network.routes`,
  `network.bridge_vlans`, `network.wireguard_peers`, `sqm.queues`,
  `mwan3.members`, `mwan3.policies`, `mwan3.rules`).

  Regression coverage: a new unit test
  (`tests/unit/handler_test.uc::ETag is stable across unrelated sibling
  section churn`) and an inverted integration test
  (`tests/integration/34_batch7_endpoints_test.sh`) lock the new
  per-resource semantics in. The unit test fixture declares
  `depends_on` so it would have failed against v2.0.0 buggy code.

### Operator note: client-held ETags

The fix changes how ETags are computed for the 10 resource families
that previously declared `depends_on` (firewall rules/redirects/
forwardings, dhcp servers, network routes/bridge_vlans/wireguard_peers,
sqm queues, mwan3 members/policies/rules). Clients holding v2.0.0
ETags for these resources will see a one-shot `412 precondition_failed`
on their next `If-Match` write; the response carries the current ETag
in the body and the client picks it up for subsequent writes. ETags
for the other resources are byte-identical across the upgrade (the
old code already short-circuited to a pure body hash when
`depends_on` was absent).

The idempotency cache may serve responses with old ETag headers for
up to 24 hours after upgrade; a chained "POST then `If-Match` next-write"
flow against the affected resources may see one extra 412 within that
window.

### Docs

The CLAUDE.md resource module contract drops the `depends_on` field.
`docs/architecture.md`, `docs/adding-a-resource.md`, `docs/resources.md`,
`docs/errors.md`, `docs/roadmap.md`, `docs/migration-v1-to-v2.md`,
`README.md`, and `web/index.html` are updated to describe per-resource
ETags. The OpenAPI `info.description` and the `ETag` header component
description in `build/openapi.json` are updated in lockstep.

## [2.0.0] - 2026-06-04

First stable v2 release. Promotion of `v2.0.0-rc4` after the dogfooding
and provider-integration windows closed with no further wire-surface
issues. No code or spec changes since rc4; only the `VERSION` bump and
the changelog promotion.

The cumulative v2 changes vs. v1.2.1 are listed across the four RC
entries below. As a contract summary:

- `/api/v2/` mount; 32 curated resource endpoints + `/raw/` passthrough
  + `/batch` + ops endpoints (`/healthz`, `/openapi.json`, `/schema`,
  `/metrics`, `/tokens`, `/auth/whoami`, `/diagnostics`).
- 665 unit tests, property-fuzz at 1000 iterations per resource per CI
  run, integration suite against a real OpenWrt 25.12 VM, soak test
  with RSS/fd-leak watch, per-endpoint latency measurement.
- Per-package locking with deadlock-free batch acquisition; global
  `with_lock` for non-uci writes only.
- Optimistic concurrency via ETag + If-Match (header path through a
  reverse proxy; query-param fallback through uhttpd directly).
- Idempotency-Key support on POSTs; `Idempotent-Replayed` header on
  replays.
- Sensitive-field handling: write-only fields (`key`, `private_key`,
  `preshared_key`, `tls_auth`, `pkcs12`) with `has_<field>: bool`
  presence flag.
- Token mint via CLI or HTTP, scope-subset escalation guard, per-token
  rate limit, per-token request budget metric.
- OpenAPI 3.1.0 spec is the contract. `make openapi-check` gates spec
  drift in CI; `make lint-reserved` blocks Terraform-reserved or
  HCL-keyword schema property names; `make lint-refs` blocks dangling
  `$ref` strings.
- Multi-arch byte-identical APK (`PKGARCH:=all`) verified across
  x86_64 / aarch64 / arm_cortex-a7 / mips_24kc on every release.
- Signed tag (`git verify-tag` in CI), signed APK feed
  (`apk mkndx --sign-key`), reproducible SDK pin
  (`build/sdk.sha256`).
- gh-pages feed carries stable releases only; RCs publish to GitHub
  Releases (marked `--prerelease`) but never to the feed.

The v1.2.1 APK stays available on the feed indefinitely for operators
who need to pin to the v1 wire contract; `apk add 'uapi<2.0.0'` or
`apk add uapi=1.2.1-r1` gets you there. v1-to-v2 migration table at
`docs/migration-v1-to-v2.md`.

## [2.0.0-rc4] - 2026-06-04

Fourth release candidate for v2.0. Absorbs the second-pass review from
the Terraform-provider author against rc3: four wire-surface renames
the strict code generator flagged, plus six spec/doc correctness items
and a CI guard against the next provider-hostile field name. Folds in
operational fixes from the rc3 dogfooding cycle: the APK feed gate
that keeps RCs off the public feed, a Redoc dark-theme pass on the
documentation site, and a second test lint for spec integrity.

### Wire-surface renames (breaking vs. rc3)

These rename the JSON field; the underlying uci option stays the same.
A v1.2.x client never saw any of these fields, so there is no v1-to-v2
migration impact. The renames are bundled into rc4 so the operator
pays the migration cost once at the v2.0.0 boundary, not piecemeal.

- `mwan3/interfaces`: `count` -> `probe_count`. `count` collides with
  Terraform's reserved `count` meta-argument and was breaking the
  provider's schema validation.
- `firewall/zones`, `firewall/defaults`: `output` -> `output_policy`.
  `output` is an HCL block keyword; renders quoted in HCL and trips
  linters.
- `unbound/server`: `resource` -> `resource_limits`. Same HCL-keyword
  smell; also disambiguates from process-resource-limit semantics.
- `network/interfaces` runtime block: `ipv4-address`, `ipv6-address`,
  `ipv6-prefix` now emit snake_case (`ipv4_address`, `ipv6_address`,
  `ipv6_prefix`). ubus returns the hyphenated form; uapi normalizes
  per the project-wide snake_case-where-it-stops policy.

### Added

- **OpenAPI 3.1.0 nullable shape** throughout the spec
  (`type: [..., "null"]`), replacing the OpenAPI-3.0 `nullable: true`
  form. Strict 3.1 validators stop tripping on the legacy form.
- **`required` on nested `match`** for firewall rules and redirects:
  the sub-schema now states `required: ["src_zone"]` directly, in
  addition to the existing `openapi_conditional` form. Spec consumers
  that don't evaluate conditional schemas get the constraint for free.
- **Response headers documented under wire names** on every operation
  that emits them: `X-Request-Id` universally, `ETag` on item GETs and
  writes, `X-Reload-Status`/`X-Reload-Services` on writes,
  `Idempotent-Replayed` on POSTs, `Link`/`X-Next-Cursor` on paginated
  collections, `Retry-After` on 429/423, `WWW-Authenticate` on 401.
- **`adopt` operations gain a real description** explaining the
  ULID-rename + stale-id implications. Operation summaries fix the
  pluralization smell ("Adopt an anonymous firewall **rule**" instead
  of "rules").
- **`TokenCreateResponse` field descriptions**: `bearer` and `name`
  carry one-line explanations.
- **`has_<field>` convention documented** in `info.description` and
  `docs/adding-a-resource.md`. The snake_case-where-it-stops policy
  is now a written paragraph in the same doc.

### Hardening

- **`make lint-reserved`**: walks `build/openapi.json`'s
  `components.schemas` and fails CI on any top-level property whose
  name is a Terraform meta-argument (`count`, `for_each`, `depends_on`,
  `provider`, `lifecycle`, `connection`, `provisioner`) or HCL block
  keyword (`output`, `resource`, `data`, `module`, `variable`,
  `locals`, `terraform`). After rc4 the codebase has zero offenders;
  the guard catches the next provider-hostile name before it ships.
- **`make lint-refs`**: walks every `$ref` under `#/components/` in the
  emitted spec and fails on any dangling target. Caught a cross-
  section header rename that OpenAPI viewers had been rendering as
  an empty box.
- **APK feed gated to stable tags only**
  (`.github/workflows/ci.yml`). The `Publish to APK feed on gh-pages`
  step now skips any tag containing a hyphen (rc, alpha, beta, pre),
  so `apk add uapi` against the public feed only ever resolves to a
  true release. RCs still attach to the GitHub Release (marked
  `--prerelease`); install them deliberately via
  `apk add --allow-untrusted /tmp/uapi-<rc>.apk`.
- **`feed-purge-rc.yml` workflow**: operator-dispatched scrub for
  any pre-release APKs that landed before the gate existed. Defaults
  to dry-run, refuses to leave the feed empty, rebuilds the signed
  index from the remaining stable-only APKs. Used once on 2026-06-04
  to drop the five legacy RC APKs (1.0.0_rc1/rc2, 2.0.0_rc1/rc2/rc3).

### Documentation

- Redoc API reference at <https://raspbeguy.github.io/uapi/api/> now
  matches the project's dark palette throughout (sidebar, schema
  panels, code blocks). Heading typography uses the same sans-serif
  stack as the body to maintain visual rhythm on a docs page where
  every endpoint and section title is a heading.
- `docs/release-process.md` documents the stable-tags-only feed
  policy and the `feed-purge-rc` recovery workflow.
- `docs/installation.md` makes the stable-only feed convention
  explicit; RC install path described as deliberate manual download.
- `docs/migration-v1-to-v2.md` carries the rc3 -> rc4 wire renames
  alongside the original v1 -> v2 table.

### Internal

- `openapi_singular` is now a required field on every CRUD resource
  module (used by the adopt operation summary). The generator fails
  loudly on a missing declaration rather than silently emitting
  ungrammatical summaries.

## [2.0.0-rc3] - 2026-06-03

Third release candidate for v2.0. Folds in four hardening items and three
opportunistic resource curations from `docs/roadmap.md`. All changes are
additive (new error-envelope field, new metric label, new resource
endpoints, new scopes); rc2's wire surface is preserved.

### Added

- **mwan3 curation** (5 resources): `mwan3/interfaces` (per-WAN
  tracking), `mwan3/members`, `mwan3/policies`, `mwan3/rules`, and the
  `mwan3/globals` singleton. Cross-reference validation enforces
  `rule.use_policy -> policy`, `policy.use_members[] -> member`, and
  `member.interface -> interface`. `depends_on` chains those into
  ETag-aware dependency mixing.
- **usteer curation** (1 singleton, `usteer/config`): passive band-
  steering tuning. 33 options including `ssid_list` filter and two log
  list options. (`ssid_list` is a uci list option on the singleton, not
  a separate section type as the original roadmap implied.)
- **openvpn curation** (1 CRUD, `openvpn/instances`): per-tunnel config
  with ~50 options. `key`/`tls_auth`/`pkcs12` are write-only (read
  surfaces `has_<field>: bool`); `merge_for_patch` carries values
  forward so unrelated PATCHes do not wipe credentials. Filesystem path
  fields are validated against `^/[A-Za-z0-9_.+/-]+$` to reject
  shell-metacharacters.
- **Per-token request budget metric**: `uapi_requests_total` now carries
  a `token_id` label (operator-configured cardinality, bounded). Pre-auth
  failures (401 before authorize completes) fold to `token_id="-"`.
- **`/diagnostics` recent_errors ring buffer**: best-effort 20-entry
  sliding window of error envelopes emitted by the parent uhttpd VM.
  Each entry carries `{ts, request_id, code, status, method, path,
  message}`. Surface for post-incident debugging without syslog
  forwarding.

### Hardened

- **Constant-time hash compare in auth**: `values.constant_time_equals`
  closes the bulk timing channel previously disclosed under
  `docs/security.md` "Threat model out of scope". The authorize loop
  also no longer short-circuits on first match, removing the
  position-of-token timing leak.
- **Property-fuzz gate**: new `make test-property` runs at 1000
  iterations per resource (vs 200 in regular `make test`). Wired into
  CI as a distinct step so a fuzz regression has its own pass/fail line.

### Internal

- New scope paths: `mwan3`, `mwan3:globals/interfaces/members/policies/
  rules`, `usteer`, `usteer:config`, `openvpn`, `openvpn:instances`.
- New module `src/lib/error_ring.uc` (single-file JSON ring at
  `/tmp/uapi-error-ring/ring.json`; atomic rename pattern shared with
  ratelimit and idempotency).
- 37 new unit tests + 8 new property-fuzz subjects. 665/665 tests green.

## [2.0.0-rc2] - 2026-06-03

Second release candidate for v2.0. No wire-protocol changes vs rc1; the wire
surface is still locked at the rc1 contract. Fixes one real bug found by the
post-rc1 live-router smoke, twelve internal refactors from a structural code
review, and three new contributor docs.

### Fixed

- **`uapi-token create` no longer produces ghost tokens on hyphenated `--name`.**
  libuci rejects hyphens in section names with "Invalid argument", but
  ucode-mod-uci's `cursor.set` silently returns true on the rejection. The
  CLI would print a cleartext bearer that was never persisted; the operator
  got no signal until auth failed on every request. Both the CLI and the
  HTTP `POST /tokens` path now validate `--name`/`body.name` against
  `^[A-Za-z0-9_]+$` and fail loudly with a message that points the operator
  at the charset. All hyphenated example token names in `README.md`,
  `docs/tokens.md`, `web/`, and the OpenAPI intro now use underscores.

### Refactor (internal, no wire change)

Acted on a structural code review from a follow-up pass. Touches ~600 LOC
across handler, transaction, openapi generator, dispatcher, and resource
modules; spec output is byte-identical to rc1 throughout.

- `handler.uc` - extracted `diff_apply`, `etag_with_deps`, `apply_patch_body`
  from the make/make_singleton factories; `attach_reload_headers` shared by
  `translate_tx` and the DELETE 204 path. Both `patch()` functions are now
  linear: precondition check, apply_patch_body, validate, diff_apply,
  response.
- `transaction.uc` - `_finalize_after_reload(reload_err, restore_fn, body,
  services)` shared between single-package and multi-package paths. Removed
  the latent `result.body ?? result` fallback in favour of explicit null
  propagation.
- `gen_openapi.uc` - `responses(verb, success)` helper collapses 38 hand-
  spelled response blocks. `error_responses(verb)` gates write-only codes
  (409/412/422/423) off GETs and validates the verb at parse time.
  TAG_DESCRIPTIONS / X_TAG_GROUPS / STATIC_PATH_TAGS collapsed into one
  ordered `TAGS` list with derived builders.
- `errors.uc` - exported `STATUS_BY_CODE` / `FIELD_CODES` / `ALL_CODES`;
  gen_openapi now reads the error-code enum from there rather than
  hand-transcribing.
- `scope.uc` - `require_or_deny(...)` and a raw-tree variant
  `require_raw_scope(...)` collapse 20 hand-rolled scope-check sites
  in `main.uc` + `raw.uc`. Tightening the deny message format is now a
  one-helper edit.
- `src/lib/openapi_hints.uc` - new module holding cross-resource conditional
  fragments (`match_requires_src_zone`) imported by firewall.rules and
  firewall.redirects.
- `web/api/index.html` - uses the shared `web/style.css` instead of inline
  topbar CSS.

### Hardened

- **Redoc pinned to v2.5.3 with SRI integrity hash.** Was loading `latest`
  from a third-party CDN. The docs site sits next to the APK signing key
  on gh-pages, so a CDN-side compromise mattered. Browser now refuses any
  byte stream that doesn't match the committed sha384.

### Docs

- **New: `CONTRIBUTING.md`** - dev environment, `make` loop, what kinds of
  changes are welcome, commit/PR style, codebase tour.
- **New: `docs/ucode-quirks.md`** - language and OpenWrt-runtime gotchas
  that have each cost a debug round-trip on this project. First time these
  live in the public tree.
- **New: `docs/concurrency.md`** - fork-per-request rules, lock layout, the
  "would this require state to survive fork().exit()?" mental test.
- README docs list reshaped into operator-facing vs contributor-facing groups.
- `docs/migration-v1-to-v2.md` rename-note for `active_leases_v4_box_total`
  now describes the correct semantics (was previously inverted).

### Removed (slop / inverted-text cleanup)

- Stripped narrator preambles and stale field-name references from
  `transaction.uc`, `gen_openapi.uc`, CHANGELOG (rc1 retag intro removed),
  migration guide; 31 lines deleted, 4 added.

## [2.0.0-rc1] - 2026-06-03

First release candidate for v2.0. The wire surface is locked at this tag.

Major bump. One uapi installation serves exactly one API major; the v1 surface
no longer mounts under the v2 package. Operators who need v1 keep the 1.2.1
package installed. Migration table in `docs/migration-v1-to-v2.md`.

### Breaking

- **snake_case rename across `dropbear/instances`, `snmpd/system`, and
  `vnstat/config`** (16 fields total). Every fromUci/toUci key + every
  `schema_properties` entry now follows the project-wide `snake_case`
  convention. Full mapping in the migration guide.
- **Strict integer types** on every uci field declared `type: "integer"`.
  v1 accepted string-form integers (`"42"`); v2 requires real JSON integers
  (`42`). `fromUci` returns `null` for missing or non-numeric uci values via
  the new `values.as_int` coercion (previously `int("abc")` silently became
  `0`).
- **`schema_properties` completeness sweep.** Every fromUci-surfaced field has
  a typed schema entry. Bodies that previously slipped past the type check
  (silent drops in the toUci layer) now return `422 validation_failed`.
- **URL prefix bumped to `/api/v2/`** (was `/api/v1/`). The install hook
  removes the v1 entry from `uhttpd.main.ucode_prefix` and adds the v2
  one; clients must update their base URL. Versioning policy: one major
  per installed package, never parallel. Operators who need the v1 wire
  contract keep the 1.2.1 APK.

### Added

- **Conditional GET.** `If-None-Match: "<etag>"` (or `?if_none_match=` query
  param) returns `304 Not Modified` when the ETag matches. Same uhttpd
  CGI-allowlist carve-out as `If-Match`.
- **Inbound `X-Request-Id`** (or `?request_id=`) is echoed back; the
  server-generated ULID is used when absent or malformed.
- **`WWW-Authenticate: Bearer realm="uapi", error="<code>"`** on every 401
  (RFC 7235 + RFC 6750 compliance).
- **`/healthz` subsystem checks.** Body now includes `{checks: { ubus, uci,
  lock_dir, time_sync }}`. Returns 503 when any subsystem is degraded.
- **`/schema` / `/schema/<package>` / `/schema/<package>/<resource>`.** Public
  (no auth, like `/openapi.json`). Returns the resource module's
  `schema_properties` for dynamic clients without parsing the full OpenAPI.
- **`/auth/whoami`** returns the current bearer's token metadata
  (`token_id, scopes, source_ip, expires_at, allowed_cidrs, last_used_*`).
- **Token expiry.** `expires_at` field on token sections (`uapi-token create
  --expires-in 30d` extended). After the wall clock passes: `401 invalid_token`
  with `message: "Token expired"`.
- **Token IP scoping.** `allowed_cidrs` list on token sections. A request from
  a source IP outside the listed CIDRs returns `401 invalid_token` with
  `message: "Source IP not permitted for this token"`. Empty list = any IP.
- **Token last-used tracking.** `last_used_at` (epoch) and `last_used_ip`
  updated best-effort on each authed request; throttled to ~1 write/minute
  per token via a tmpfs sentinel.
- **`/tokens` HTTP route.** `GET` lists tokens (no secrets surfaced),
  `GET /<id>` reads one, `POST` mints a new bearer over the wire (returns the
  cleartext once), `DELETE /<id>` revokes. POST honours `expires_in_seconds`
  and `allowed_cidrs`. Scope check: caller must hold `uapi:tokens:rw` (or
  `*:rw`) AND every requested scope must be a strict subset of the caller's
  own - escalation returns `403 scope_escalation_blocked`.
- **Per-token rate limit.** File-backed token-bucket, default 100 req/s burst
  200. Returns `429 too_many_requests` with `Retry-After`. Configurable via a
  `config ratelimit` section in `/etc/config/uapi`.
- **`/metrics`** (Prometheus text). Series: `uapi_requests_total`,
  `uapi_request_duration_seconds_bucket`, `uapi_rate_limit_drops_total`,
  `uapi_lock_contention_total`, `uapi_validate_errors_total`. Path templates
  are normalized (`/firewall/rules/:id` not `/firewall/rules/r_01HX...`) to
  keep cardinality bounded. Scope: `uapi:metrics:ro`.
- **`/diagnostics`** returns version, uptime, loaded resources, current lock
  state. Scope: `uapi:diagnostics:ro`.
- **Idempotency keys.** `Idempotency-Key: <client-supplied>` header (or
  `?idempotency_key=`) on POST: first request caches the response under
  `sha256(token || key)`; subsequent requests with the same key replay the
  cached response (`Idempotent-Replayed: true` marker header). Same key with a
  different body returns `409 idempotency_key_conflict`. Cache TTL 24 h.
- **Cursor pagination.** Collection GETs accept `?cursor=c_<id>&limit=N`.
  Default 100, max 500. Response carries `Link: <...>; rel="next"` (RFC 8288)
  and `X-Next-Cursor: c_<id>` when more items follow. Malformed cursor →
  `400 invalid_cursor`.
- **`POST /batch`.** All-or-nothing across N packages. Body
  `{ operations: [{ path, method, body?, if_match? }, ...] }` (max 50). Pure
  reads acquire no lock; writes acquire per-package EX locks in sorted order
  (deadlock-free) under one combined snapshot/restore. Returns
  `207 Multi-Status` on success, the failing sub-request's status on abort
  with `{ code: "batch_partial_failure", aborted_at_index, reverted: true }`.
  Each sub-request is scope-checked independently.
- **JSON Patch (RFC 6902).** PATCH with
  `Content-Type: application/json-patch+json` switches from merge-patch (the
  default, RFC 7396) to JSON Patch ops:
  `add`/`remove`/`replace`/`move`/`copy`/`test`. `test` enables atomic
  conditional updates without `If-Match`.
- **Dependency-aware ETags.** Resources declare `depends_on: ["package:type"]`;
  the dependent's ETag mixes in the hash of the referenced state. Initial
  declarations: `firewall.rules`, `firewall.redirects`, `firewall.forwardings`
  → `firewall:zone`; `sqm.queues`, `network.routes`, `dhcp.servers`,
  `network.wireguard_peers` → `network:interface`; `network.bridge_vlans`
  → `network:device`. Changing a referenced section now invalidates the
  dependent's ETag.

### New error codes

- `429 too_many_requests` (rate limit)
- `403 scope_escalation_blocked` (token mint guard)
- `400 invalid_cursor` (pagination)
- `409 idempotency_key_conflict` (same key, different body)
- `batch_partial_failure` (carried in 4xx/5xx body when a `/batch` aborts)

### New scopes

`uapi`, `uapi:tokens`, `uapi:metrics`, `uapi:diagnostics`.

### Hardening

- **Non-uci base library** (`src/lib/non_uci.uc`) consolidates the
  `with_lock` + audit + envelope plumbing previously duplicated across
  `packages/*` and `system/access`.
- **Lock-and-state audit** (`docs/lock-state-audit.md`) - every fd-open and
  lock-acquire site walked; release proven on every exit including `die()`.
- **Function-level coverage gate** in CI: ≥80% of lib exports unit-tested,
  100% module-level coverage required.
- **Soak harness in CI** - short read-only sweep with RSS/fd-growth thresholds.
- **Performance benchmark** - per-endpoint p99 measured and reported on every
  CI run.
- **Signed-tag verification** required on release tags
  (`.github/allowed-signers`).
- **Reproducible SDK pin** - SHA256 checksum verified for the OpenWrt SDK
  download (`build/sdk.sha256`).
- **SPDX 2.3 SBOM** emitted per release. `make sbom` generates
  `build/sbom.spdx.json` with every shipped file's sha256, package
  dependencies, and the built APK's verification hash. CI attaches the
  SBOM to the GitHub Release alongside the APK.
- **Multi-arch build verification** on tag push. The `verify-arch-build`
  matrix job (aarch64_generic, arm_cortex-a7, mips_24kc) cross-compiles
  uapi against each arch's SDK to prove the `PKGARCH:=all` invariant
  holds (uapi is pure ucode + shell, so the byte-identical APK works on
  every arch; this job catches a regression if compiled code ever sneaks
  in).

### Documentation

- `docs/migration-v1-to-v2.md` - field renames, strict-int enforcement,
  new endpoint / error code / scope catalogs, client retry patterns.
- `docs/architecture.md` - fork model, lock layout, transaction recipe,
  schema layer, ETag derivation with dep mixing, rate-limit math, metrics
  emission path, where state lives.
- `docs/security.md` - threat model, scope tree examples, TLS posture,
  token storage, rate-limit guarantees, audit shape, hardened-deployment
  recommendations.
- `docs/release-process.md` - operator-facing release flow, SBOM,
  reproducible builds, arch-neutrality rationale, pre-release checklist,
  rollback.

### OpenAPI completeness and contract hardening

- **OpenAPI spec is now a complete machine-readable contract.** Every
  curated resource carries `required: [...]` derived from `validate()`'s
  unconditional requireds. Resources with proto/type discriminators
  (network/interfaces, network/devices, network/rules, dhcp/hosts,
  system/timeservers, wireless/interfaces) gain `allOf: [{if/then/required}]`
  blocks. The 3 resources that populate a runtime block
  (network/interfaces, wireless/interfaces, dhcp/servers) get typed
  `runtime` sub-shapes instead of an opaque `{type: object}`. Generator
  reads three new optional fields per resource module (`openapi_required`,
  `openapi_conditional`, `openapi_runtime`).
- **System endpoints now in the spec.** `/batch`, `/metrics`,
  `/diagnostics`, `/tokens` (GET / GET-by-id / POST / DELETE),
  `/auth/whoami`, `/schema`, `/schema/{package}`,
  `/schema/{package}/{resource}`, `/openapi.json`. The PATCH operations
  declare both content types (`application/json` for merge-patch,
  `application/json-patch+json` for RFC 6902).
- **Error envelope `code` is an explicit enum** in the spec. Includes
  every code uapi can emit (the full list now lives in the
  `ErrorEnvelope.properties.code.enum` array).
- **Response headers documented as components**: `WWW-Authenticate`,
  `Retry-After`, `ETag`, `X-Request-Id`, `Link` (RFC 8288),
  `X-Next-Cursor`, `Idempotent-Replayed`, `X-Reload-Status`,
  `X-Reload-Services`.
- **`X-Reload-Status` + `X-Reload-Services`** response headers on every
  write. `X-Reload-Status: ok` = init script exited 0 (NOT a runtime-
  convergence promise); `X-Reload-Status: no_reload` = the resource has
  no reload services. Documented loudly: convergence is out-of-band.
- **`dhcp/servers.runtime.active_leases_v4_total` renamed to
  `active_leases_v4_box_total`**. The old name was misleading - it sits
  on a per-server resource but counts box-wide (dnsmasq's lease file
  isn't interface-tagged). Breaking but in-window since v2.0.0 hadn't
  been announced. The v1.2.0 entry has been annotated with a forward
  pointer.
- **`/healthz` `version` field documented as the stable version-skew
  probe.** Clients should read it from there rather than inferring from
  the URL or installed package.
- **`dhcp/leases6.ia_type`** declares its enum (`IA_NA`/`IA_TA`/`IA_PD`)
  instead of being a bare string.
- **`docs/operations.md`** gains a "Success != converged" leading
  section and a "version is a stable contract field" note under
  `/healthz`.
- **Verified per-package lock granularity on a live router**: two
  concurrent writes against different uci packages both succeed in
  parallel (~280 ms each, no 423); same-package writes serialize
  correctly. The "single global write lock" concern in the review
  doesn't reflect current code - it's confusion with the
  `transaction.with_lock` path used by non-uci writes (apk,
  system/access), which DOES hold the global EX (correctly, because
  apk's own DB doesn't tolerate parallel installs).

## [1.2.1] - 2026-06-01

Patch release. Three small bugs found by exercising v1.2.0 against a real OpenWrt 25.12.4 router, plus one polish item (an honest error code when the daemon you're configuring isn't installed).

### Fixed

- **`packages/installed` always returned `[]` on apk-tools 3.x.** `list_installed()` called `apk info --installed`, a flag that exists on apk-tools 2.x but not 3.x (which OpenWrt 25 ships). Plain `apk info` is the right command; it prints one installed package name per line. The new implementation also filters output to the package-name regex so diagnostic lines never end up surfacing as fake packages.
- **`network/interfaces` `ipaddr` surfaced as an array on modern uci.** OpenWrt 25 uses `list ipaddr` for static-proto multi-address interfaces (loopback ships as `list ipaddr '127.0.0.1/8'`); uapi was returning the raw uci value, so a GET on a list-form interface returned `"ipaddr": ["127.0.0.1/8"]` instead of the schema-declared string. `fromUci` now surfaces both forms additively: `ipaddr` is always the first address as a string (preserving the v1.0/v1.1 contract); a new `ipaddrs` array carries the full list. `toUci` prefers `ipaddrs` when present and falls back to `ipaddr`. validate accepts either.
- **Makefile `lint-emdash` scanned `build/sdk/`** (OpenWrt feeds checkouts contain em-dashes in upstream package READMEs / test fixtures we don't author or control). `grep --exclude-dir=sdk` now skips it.

### Added

- **New error code `503 init_script_missing` with a pre-flight check.** Before any uci write, `transaction()` now confirms each `/etc/init.d/<svc>` listed in `reload_services` actually exists; missing → fail-fast with a 503 carrying the missing path in `message`, no uci change. Motivates this: live-router testing of v1.2.0 showed that POST `/sqm/queues` on a box without sqm-scripts produced `500 reload_failed_unrecovered`. The cause: step-5 reload returned exit 127 (script not found); the snapshot-restore worked but the SECOND reload attempt also returned 127 (same missing script), so uapi recorded both errors and surfaced "unrecovered" - misleading: uci IS in a known state, only the daemon reload couldn't run because the daemon isn't installed. The new pre-flight makes the two scenarios distinct on the wire:
  - `503 init_script_missing`: daemon not installed; uci state unchanged.
  - `500 reload_failed_restored`: daemon installed but reload exited non-zero; uci state restored from snapshot.
  - `500 reload_failed_unrecovered`: as before, only for the genuinely unrecoverable case (snapshot import / restore-reload both threw or returned errors).

  Step numbering in the atomic-transaction recipe shifts by one in CLAUDE.md: pre-flight is step 0, flock moves to step 1, etc.

### Tests

- Unit: 422 → 431 (+9 covering `ipaddr`/`ipaddrs` semantics, `init_script_missing` pre-flight against absent paths and unsafe names, empty `reload_services` pass-through).
- Integration: +1 file (`30_init_script_missing_test.sh`) verifying live behavior on a router without sqm-scripts: 503 returned, uci unchanged, healthy resources unaffected.

### Live verification

End-to-end run against a real OpenWrt 25.12.4 router (apk-tools 3.0.5) with the locally-built APK installed:

- 6 test phases, 131 assertions: 131 pass, 0 fail.
- `GET /packages/installed` now lists 188 packages (was 0).
- `GET /network/interfaces/loopback` returns `"ipaddr": "127.0.0.1/8"` (schema-conformant string) and `"ipaddrs": ["127.0.0.1/8"]`.
- `POST /sqm/queues` on the unpatched router returned `500 reload_failed_unrecovered`; on 1.2.1 it returns `503 init_script_missing` with `"init script /etc/init.d/sqm not found (is the daemon installed?)"` and leaves uci untouched.

## [1.2.0] - 2026-06-01

Minor release driven by a real Terraform-provider migration that exercised the v1.1 surface against an actual edge router. Three themes:

1. Closing the last "must drop to /raw/" gaps in the curated surface (proto=dhcp/dhcpv6 client options, NAT-loopback reflection on redirects, DHCPv6-reservation fields on dhcp/hosts, parity audit on unbound/server).
2. Surfacing the runtime state Terraform readers need (ubus-derived runtime blocks on network/interfaces, dhcp/servers, wireless/interfaces; new read-only dhcp/leases6 collection).
3. Closing the substantive deferred feature from v1.0's roadmap: ETags / If-Match optimistic concurrency.

Plus two non-uci additions (`system/password`, `system/authorized_keys`) for credential bootstrap, and a formalised "Non-uci resources" registry in CLAUDE.md so the bar for future non-uci additions stays high.

Purely additive: every endpoint, field, scope, response shape, and error code from 1.0.x and 1.1.x continues to work unchanged.

### Added

- **`network/interfaces` proto-conditional DHCP/DHCPv6 client fields.** Under `proto=dhcp`: `peerdns`, `defaultroute`, `metric`, `hostname`, `clientid`. Under `proto=dhcpv6`: `peerdns`, `reqprefix`, `reqaddress`, `ip6hint`, `ip6ifaceid`, `delegate`. Closes the "WAN with PD and noresolv" use case that previously required either dnsmasq workarounds or /raw/.
- **`firewall/redirects` NAT loopback.** New fields: `reflection` (bool), `reflection_src` (enum `internal`/`external`), `reflection_zone` (list). Native fw4 options; no more split-horizon-DNS workaround.
- **`dhcp/hosts` parity audit.** New fields: `duid` (DHCPv6 client id), `hostid` (IPv6 host-id hint), `mac_aliases` (additional MACs via uci `list mac`, backward-compatible with single-string `mac`), `broadcast` (`--dhcp-broadcast` workaround for older clients), `instance` (cross-refs `dhcp/dnsmasq` section names). validate requires either `mac` OR `duid`.
- **`unbound/server` parity audit.** New fields: `manual_conf`, `extended_stats`, `interface_auto`, `localservice`, `hide_binddata`, `rebind_protection`, `num_threads`, `ttl_min`, `domain`, `domain_type`. Listen-address binding deliberately not added; documented in `docs/non-uci-state.md` (no clean uci option exists upstream; use `/etc/unbound/unbound_srv.conf`).
- **`dhcp/leases6` (NEW read-only collection).** Parses `/tmp/(hosts/odhcpd|odhcpd.leases)` to surface odhcpd IPv6 lease state. Per-IA-address entries with `duid`, `iaid`, `hostname`, `interface`, `ia_type`, `ip`, `prefix_length`, `expires_at`. Forgiving parser fails soft on odhcpd format drift across versions.
- **`network/interfaces` runtime block.** Populated from `ubus call network.interface.<name> status`: `up`, `pending`, `available`, `l3_device`, `uptime`, `ipv4-address[]`, `ipv6-address[]`, `ipv6-prefix[]`, `route[]`. Drift-safe for Terraform (field already declared computed).
- **`dhcp/servers` runtime block.** Surfaces `active_leases_v4_total` (box-wide; dnsmasq doesn't tag leases by interface) and `active_leases_v6_iface` (per-interface; odhcpd does). *(renamed to `active_leases_v4_box_total` in v2.0.0; see the v2.0.0 entry below.)*
- **`wireless/interfaces` runtime block.** Looks up the kernel ifname via `network.wireless status`, then queries `iwinfo info`/`assoclist` via ubus. Surfaces `ifname`, `bssid`, `channel`, `frequency`, `signal`, `noise`, `txpower_actual`, `assoclist_count`. Requires new dep `rpcd-mod-iwinfo`.
- **`system/password` (non-uci, write-only).** `POST {user, password}` → 204. Shells out to `/bin/busybox passwd <user>` with the password piped twice via stdin (LuCI's recipe). Validates user as `^(root|[a-z][a-z0-9_-]*)$` and password as `>= 8` characters with no control bytes. Under `transaction.with_lock`. Audit log line carries the user name, never the password.
- **`system/authorized_keys` (non-uci).** `GET` lists; `POST` adds one; `PUT` replaces wholesale; `DELETE /<id>` removes one. File ops on `/etc/dropbear/authorized_keys` (mode 0600, atomic tmp+rename, symlink-safe). Server-side key validation against the allowed type set (`ssh-rsa`, `ssh-ed25519`, three ECDSA curves, two SK variants). Rejects newline/NUL injection in any key field. Stable id = sha256 prefix of the public-key blob (with a 48-bit dual-djb2 fallback in test environments without ucode-mod-digest).
- **ETags / `If-Match` optimistic concurrency.** Every CRUD `GET`, singleton `GET`, and successful write response carries an `ETag` header (sha256 prefix of the canonical JSON body, excluding the runtime block so live ubus drift doesn't trip spurious 412s). `PUT`, `PATCH`, `DELETE`, and singleton `PATCH` honour `If-Match`: stale value returns `412 precondition_failed` and aborts before any uci write. Multi-value (`"a", "b"`), `W/` weak prefix, and `*` (any-existing) all supported. Absent `If-Match` preserves last-write-wins. **uhttpd carve-out:** uhttpd's CGI env has a hard-coded HTTP_* allowlist that excludes If-Match; pass the ETag via `?if_match=<etag>` query parameter as the portable path (uapi accepts either).
- **New error code:** `412 precondition_failed`.
- **Non-uci resources registry in CLAUDE.md.** Six rows: `packages/installed`, `packages/feeds`, `dhcp/leases`, `dhcp/leases6`, `system/password`, `system/authorized_keys`. Each with source-of-truth, lock semantics, reload, audit shape. Adding a new non-uci resource means adding a row.
- **`docs/non-uci-state.md`.** Operator-facing companion to the registry, plus the out-of-scope state catalog (unbound listen-address binding, inittab, etherwake, px5g, FreeBSD sysctl, RRD/NetFlow history) with recommended out-of-band path for each.
- **Curation completeness rule** (CLAUDE.md): "*does this resource expose the options a typical real configuration of this section actually sets?*" as the test for any future curation gap.
- **`examples/curl/`** grew from 5 files to 15: `network_interfaces.sh`, `firewall_redirects.sh`, `firewall_forwardings.sh`, `wireguard_peers.sh`, `dhcp_servers.sh`, `uhttpd_instances.sh`, `sqm_queues.sh`, `dropbear_instances.sh`, `packages_installed.sh`, plus the existing ones.

### Changed

- **`handler.uc` resource factory** now passes `conn` as the second arg to every `fromUci` callsite (list, get_one, replace, patch, remove, adopt, singleton get/patch). Resources that don't need it ignore the extra arg; resources that want runtime data from ubus use it. Default behaviour unchanged for v1.0 resources.
- **`schema_properties` filled in** on seven v1.1 resources that shipped with empty stubs (`dhcp/odhcpd`, `snmpd/{com2secs,system}`, `uhttpd/certs`, `vnstat/{config,interfaces}`, `prometheus_node_exporter_lua/config`). OpenAPI codegen for downstream tooling now sees field types/ranges.
- **`uhttpd/certs.country`** validator accepts `^[A-Za-z]{2}$` (case-insensitive) and normalizes to uppercase in `toUci`. v1.1 accepted any 2-char string; the early v1.2 work tightened it to `^[A-Z]{2}$`, which was a backward-compat break and is now relaxed.
- **`unbound/server` enums** match upstream OpenWrt unbound: `protocol` now `{default, mixed, ip4_only, ip6_only, ip6_local, ip6_prefer}` (`auto` was rejected by the daemon); `resource` picks up `default`.
- **`tests/integration/14_observability_test.sh`** asserts the TLS-bypass audit-log gap is closed: a WRITE via `/etc/uapi.insecure` emits both the `uapi-insecure-bypass` NOTICE and the standard AUDIT line.
- **`tests/integration/22_network_extras_test.sh`** installs an `EXIT/INT/TERM` trap so the throwaway `br-uapitest` bridge is always cleaned up.

### Documentation

- **CLAUDE.md** updated: concurrency section describes the shipped ETag feature plus the uhttpd carve-out; the `v1.1+ roadmap` entry for ETags marked shipped; the curated endpoint list at the top still points readers at the generated `build/openapi.json` for the current authoritative list.
- **`docs/operations.md`** `/metrics` deferred-feature wording rewritten to reflect that the fork-per-request model is the actual blocker.
- **`docs/non-uci-state.md`** (NEW), see Added.

### Dependencies

- New runtime dep: `rpcd-mod-iwinfo` (for `wireless/interfaces` runtime block).

### Tests

- Unit: 350 (v1.1.1) → 422 (+72).
- Integration: 27 (v1.1.1) → 30 (+24_uhttpd_self_lockout, 25_dropbear_instances, 26_packages, 27_runtime_and_leases6, 28_system_access, 29_etags - already partly in v1.1.x; net +3 new files in v1.2).

### Notes

- Generated `openapi.json` grew to ~267 kB describing the expanded surface; spec carries `info.version: "1.2.0"`.
- Clients pinned to `uapi>=1.0` or `>=1.1` continue to work. Clients depending on any of the new endpoints or fields should pin `uapi>=1.2`.

## [1.1.1] - 2026-05-31

Patch release driven by a structured review of v1.1.0. No on-the-wire breaking changes. Two real bugs fixed, plus a security hardening sweep across the new v1.1 surface and several validation gaps closed.

### Fixed

- **handler.uc dynamic-type PUT/PATCH response leaked the sentinel `.type` instead of the real uci type.** For `network/wireguard_peers` this meant a successful write responded with `interface: "peer"` (substring after `"wireguard_"`) rather than the real parent interface name; a Terraform-style client refreshing from the write response would see drift on the next plan. The persisted uci state was always correct; only the response body was wrong. Static-type resources were unaffected (sentinel == real type). Added a regression test that PUT/PATCHes a wireguard peer and asserts the response `interface` matches the request.
- **`uhttpd/instances` self-lockout protection was documented but unimplemented.** The v1.1.0 code declared a `UAPI_PREFIX` constant and a `uapi_prefix_present` helper, but `validate()` was a no-op; a PATCH or PUT that stripped uapi's own `ucode_prefix` entry from the `main` instance silently locked the operator out of the API until console intervention. `validate(json, conn, id)` now enforces the check when `id == "main"` and rejects the write with `422 conflict` on the `ucode_prefix` field. To support this, `handler.uc` now passes `id` as a third argument to `validate()` (existing resources ignore it).

### Security

- **`packages/installed` and `packages/feeds` regex tightening (apk flag injection guard).** `PKG_NAME_RE` was `^[A-Za-z0-9_+.-]+$` and `FEED_NAME_RE` was `^[A-Za-z0-9_.-]+$`, both of which accepted a leading `-` or `.`. A name like `--allow-untrusted` or `--repository=http://attacker/` was regex-valid and reached `apk add` as a flag rather than a positional argument. Names starting with `.` (`.bashrc`, `..foo`) similarly bypassed the intended scoping. Patterns are now `^[A-Za-z0-9_+][A-Za-z0-9_+.-]*$` and `^[A-Za-z0-9_][A-Za-z0-9_.-]*$`; all `apk` invocations also use `--` to separate flags from positional arguments. Unit + integration tests cover both rejection paths.
- **`packages/*` writes now acquire the global `/var/lock/uapi.lock`.** The v1.1.0 implementation bypassed the transaction recipe's flock step; two concurrent installs raced apk's own DB lock and produced nondeterministic `5xx` instead of a clean `423 locked` with `Retry-After`. Refactored via the new `transaction.with_lock` helper, which acquires the same flock without the uci snapshot/reload machinery (apk doesn't go through uci).
- **`packages/*` error envelope no longer dumps raw apk stderr.** `apk add` / `apk del` failures previously surfaced the full stderr in `message`, which can contain absolute paths, mirror URLs, and on misconfigured feeds embedded credentials. The full output is now logged to syslog under the request_id; the response carries a generic `apk add failed (exit N); see syslog <request_id> for details` and the exit code.
- **`packages/*` info_one version-parse regex was broken.** `[:space:]` POSIX char-class syntax does not work in ucode/PCRE; `version` was silently always null. Now parses real `apk info` output.
- **`network/wireguard_peers` secret-masking now matches `wireless/interfaces`.** Previously the `preshared_key` field was returned as the literal string `"(set)"` on read; the field is now omitted on read and only `has_preshared_key: bool` surfaces. The PATCH path still carries the existing key forward via `merge_for_patch`.

### Changed

- **Resource validation gaps closed across v1.1 endpoints.** `snmpd/com2secs` now requires `source` (was silently accepting nonsense sections). `snmpd/accesses` cross-refs `group` against `snmpd/groups`. `vnstat/interfaces` cross-refs `interface` against `network/interfaces`. `network/rules` requires `goto` when `action=goto` (mirroring the existing `lookup` check). `system/timeservers` requires a non-empty server list when `use_dhcp=false`. `uhttpd/instances` validates `listen_http`/`listen_https` format and integer-field bounds. `firewall/defaults` validates `synflood_burst` / `synflood_rate` as positive ints. `uhttpd/certs` requires `commonname` and bounds `days` to 1-36500. `network/routes` validates `source` as IPv4/CIDR. `dhcp/dnsmasq` caps `cachesize` at 1000000 and requires `port` in 1-65535. `dhcp/servers` bounds `start`/`limit` to 0-254 (dnsmasq pool offset/size within a /24). `dropbear/instances` normalizes `PasswordAuth` / `RootPasswordAuth` / `GatewayPorts` to `"1"`/`"0"` (instead of mixed `"on"`/`"off"` and `"1"`/`"0"`).
- **`dhcp/servers` reload list narrowed to `["dnsmasq"]`.** ucitrack already cascades the `dhcp` package to `odhcpd`; the explicit listing produced a double reload.
- **CI: tag glob simplified to `v*` and concurrency cancels in-progress for non-tag refs.** The previous `v[0-9]+.[0-9]+.[0-9]+*` was GitHub filter-pattern syntax (where `+` is literal, not a regex quantifier) and worked by accident; the real release gate is the job-level `if: startsWith(github.ref, 'refs/tags/v')`. Branch and PR pushes now cancel superseded runs (saves runner minutes) but tag runs are never cancelled mid-publish.
- **`tests/integration/22_network_extras_test.sh`** installs an `EXIT/INT/TERM` trap so the throwaway `br-uapitest` bridge is always cleaned up on mid-test failure.

### Added

- **New integration tests for previously uncovered v1.1 endpoints:** `tests/integration/24_uhttpd_self_lockout_test.sh`, `25_dropbear_instances_test.sh`, `26_packages_test.sh`. The packages test specifically exercises the security hardening above against real `apk`.
- **`transaction.with_lock`** helper for non-uci write paths that need the same global serialization the uci recipe gets.

### Documentation

- **CLAUDE.md refreshed.** The curated endpoint list and the scope tree were stale (both still described v1.0); now point at the authoritative sources (`build/openapi.json`, `src/lib/scope.uc`) and enumerate the v1.1 additions.

## [1.1.0] - 2026-05-30

Comprehensive curation pass. Every additional uci section type a typical edge-router configuration relies on now has a curated CRUD or singleton endpoint, and uapi can manage its own runtime package set (apk install/remove and apk feeds). An orchestrator built on this release can drive `/api/v2/...` exclusively without falling through to `/raw/`. Purely additive: every endpoint, field, scope, and response shape from 1.0.x continues to work unchanged.

### Added

- **`network` extensions.**
  - `network/routes` (`network.route`) static routes; target/gateway/interface/table/metric/mtu/type. Validates target as CIDR/IP and cross-refs interface (skipped for blackhole/unreachable).
  - `network/rules` (`network.rule`) policy routing rules; in/out/src/dest/priority/lookup/goto/action/invert/mark.
  - `network/bridge_vlans` (`network.bridge-vlan`) bridge VLAN tagging; device/vlan/ports, vlan 1-4094, port spec regex, bridge cross-ref.
  - `network/wireguard_peers` dynamic-type resource over `wireguard_<parent_iface>`. Cross-refs the parent interface and requires it to be `proto=wireguard`. Preshared key is masked on read and carried through PATCH via `merge_for_patch`.
  - `network/interfaces` now accepts `proto=wireguard` with fields `private_key`, `listen_port`, `addresses` (CIDR list), `mtu`, `nohostroute`, `ip4table`, `ip6table`. `private_key` is masked on read (surfaced as `has_private_key: true`) and preserved across PATCH.
- **`firewall` extensions.**
  - `firewall/forwardings` (`firewall.forwarding`) zone-to-zone forwarding; cross-refs both zones.
  - `firewall/defaults` singleton input/output/forward verdict, syn_flood, drop_invalid, synflood_burst/rate, tcp_syncookies, flow_offloading.
- **`dhcp` extensions.**
  - `dhcp/servers` (`dhcp.dhcp`) per-interface DHCP server config; reloads dnsmasq + odhcpd.
  - `dhcp/dnsmasq` singleton global dnsmasq config; forwarders, address overrides, rebind protection, cache size, etc.
  - `dhcp/odhcpd` singleton odhcpd config; maindhcp, leasefile, loglevel.
- **`system` extensions.** `system/timeservers` (`system.timeserver`) enabled/enable_server/server list/use_dhcp; reloads sysntpd.
- **`dropbear/instances` (`dropbear.dropbear`).** Port, PasswordAuth, RootPasswordAuth, RootLogin, BannerFile, Interface, GatewayPorts.
- **`uhttpd` resources.**
  - `uhttpd/instances` (`uhttpd.uhttpd`) per-instance config; listen_http/listen_https/home/cert/key/ucode_prefix etc.
  - `uhttpd/certs` (`uhttpd.cert`) px5g cert generation params; days/bits/commonname/organization/location/state/country.
- **`unbound/server` singleton (`unbound.unbound`).** Recursive DNS server tuning; enabled/listen_port/dhcp_link/dnssec_enabled/recursion/resource/protocol/query_minimize/prefetch.
- **`sqm/queues` (`sqm.queue`).** Per-interface SQM shaping; interface/download/upload/qdisc/script/linklayer/overhead with enum validation.
- **`snmpd` resources.**
  - `snmpd/agents`, `snmpd/com2secs`, `snmpd/groups`, `snmpd/accesses`, and the `snmpd/system` singleton; together they cover the standard SNMPv1/v2c/v3 ACL stack.
- **`lldpd/config` singleton (`lldpd.lldpd`).** Protocol toggles (CDP/FDP/SONMP/EDP/LLDP-MED), lldp_class, mgmt IP, interface list.
- **`prometheus_node_exporter_lua/config` singleton.** listen_ipv6/listen_interface/listen_port plus per-collector booleans for cpu, meminfo, netdev, loadavg, filesystem, diskstats, uname, netstat, stat, vmstat, boottime, entropy, time, hwmon, textfile, thermal_zone, edac.
- **`vnstat` resources.** `vnstat/config` singleton (DatabaseDir/Interface5MinHours/MonthRotate) and `vnstat/interfaces` (per-iface enable).
- **`packages/installed` (apk packages).** CRUD-shaped resource over the on-router apk store. GET lists installed packages, POST installs (`apk add`), DELETE removes (`apk del`). Package names validated against `^[A-Za-z0-9_+.-]+$`. No uci involvement; shells out via `fs.popen` like `default_reload`.
- **`packages/feeds` (apk repositories).** Manages files under `/etc/apk/repositories.d/`. POST writes a new `.list` file with the supplied URL and runs `apk update`; DELETE removes the file and re-runs `apk update`. URL validated as `http(s)://`; feed name validated as `^[A-Za-z0-9_.-]+$`.
- **Scope tree.** New scopes: `network:routes`, `network:rules`, `network:bridge_vlans`, `network:wireguard_peers`, `firewall:forwardings`, `firewall:defaults`, `dhcp:servers`, `dhcp:dnsmasq`, `dhcp:odhcpd`, `system:timeservers`, `dropbear`, `dropbear:instances`, `uhttpd`, `uhttpd:instances`, `uhttpd:certs`, `unbound`, `unbound:server`, `sqm`, `sqm:queues`, `snmpd`, `snmpd:agents`, `snmpd:com2secs`, `snmpd:groups`, `snmpd:accesses`, `snmpd:system`, `lldpd`, `lldpd:config`, `prometheus_node_exporter_lua`, `prometheus_node_exporter_lua:config`, `vnstat`, `vnstat:config`, `vnstat:interfaces`, `packages`, `packages:installed`, `packages:feeds`. Wildcard `*:rw` continues to cover all of them.
- **Raw access composition.** `/raw/<package>/<id>` now consults the curated domain tree for every new section type above (including a `wireguard_*` prefix match for WG peers), so tokens carrying a curated scope but not `raw:rw` still see writes blocked or allowed consistently with the curated equivalent.

### Changed

- **`handler.uc` resource factory now supports dynamic uci types.** New optional hooks on the resource module: `type_predicate(t)`, `create_type(body)`, `id_prefix`. Default behavior is unchanged (a static `type` string still works exactly as in 1.0.x). The wireguard peers resource is the first user.

### Notes

- Generated `openapi.json` grew to ~250 kB describing the expanded surface; the spec carries `info.version: "1.1.0"`.
- Clients pinned to `uapi>=1.0` continue to work. Clients depending on any of the new endpoints should pin `uapi>=1.1`.

## [1.0.1] - 2026-05-30

Packaging fixes for the upgrade path. No API surface change; existing clients see no difference.

### Fixed

- **`apk upgrade uapi` now picks up the new code immediately.** uhttpd-mod-ucode compiles `main.uc` at parent startup and caches the VM; a plain reload does not re-read the script. 1.0.0's postinst only ran the uci-defaults wiring (which self-deletes after first install) and never told uhttpd to restart on upgrade, so operators upgrading from 1.0.0 would keep serving the previous compiled code until they manually `/etc/init.d/uhttpd restart`. 1.0.1's postinst restarts uhttpd unconditionally after the uci-defaults dance.
- **Bootstrap message no longer shown on upgrades.** The "Create a token / Verify reachable / OpenAPI spec at" banner only prints on first install (no tokens defined yet). Upgrades and remove/reinstall (where the conffile-preserved token store survives) suppress it.

## [1.0.0] - 2026-05-29

First stable release. Identical surface and behavior to 1.0.0-rc2; the version bump promotes the release candidate after CI and end-to-end testing confirmed the post-rc1 architectural changes (real-exit-code reload via `fs.popen`, TOCTOU fix, mid-tree scope wildcards, observability knobs, full integration coverage for every curated resource) hold up under real ubus/uci/netifd.

See the [1.0.0-rc1] and [1.0.0-rc2] entries below for the cumulative content shipping in v1.

## [1.0.0-rc2] - 2026-05-29

Major release-candidate iteration driven by an exhaustive code review of rc1 and a follow-on round of architectural hardening. The on-the-wire API contract is unchanged from rc1; the response semantics are now actually honest about what they claim.

### Fixed

- **Reload mechanism (the big one).** rc1 issued daemon reloads via `ubus call <service> reload`, which is fire-and-forget for every non-daemon service on OpenWrt (`firewall`, `dhcp`/`dnsmasq`): rpcd accepts the call, defers the init script, and unconditionally completes the request with `UBUS_STATUS_OK` regardless of the actual exit code. Net effect on rc1: uci writes hit disk, the API returned 200, the audit log said "success", and `fw4` never actually picked up the change until the next reboot. rc2 reloads via `fs.popen("/etc/init.d/<svc> reload")` and inspects the exit code directly. Reload failures now correctly trigger `500 reload_failed_restored` / `reload_failed_unrecovered` and the snapshot-restore recipe runs end-to-end.
- **TOCTOU window in handler.uc closed.** Every CRUD method (replace/patch/remove/adopt + raw equivalents) now loads the target section *inside* the flock callback. rc1 loaded outside, checked, then locked: a competing writer could mutate state between check and lock.
- **Raw create with explicit `id` now refuses to silently overwrite an existing section.** rc1's `POST /raw/<pkg>` with `body.id = <existing>` would clobber the section's type and merge options; rc2 returns `409 conflict` (pre-flight) plus a defense-in-depth recheck under the lock. The supplied id must also match `^[A-Za-z0-9_]+$` or the request gets `422 invalid_format`.
- **Top-level exception handler.** Uncaught throws inside `dispatch()` (commit failure, malformed scope, unexpected ubus error) now return a `500 internal_error` envelope with `X-Request-Id` and emit an `ERROR` audit line plus a `uapi-internal <request_id>` syslog trace. rc1 let them escape as a broken-CGI response with no envelope.
- **Healthz 503 envelope.** Now `{status:"degraded",errors:[...]}` (matching CLAUDE.md). rc1 incorrectly returned the standard error envelope.
- **System resource envelope.** `id` and `managed` are now stamped at the top level (every other curated resource already had them). `reload: ["system", "log"]` declared so `system` PATCH actually reloads the affected daemons. `log_remote` and `urandom_seed` normalized to JSON booleans on read.
- **Wifi PATCH key preservation.** rc1's PATCH on an encrypted `wireless.interfaces` section forced the caller to resend the cleartext passphrase. rc2 carries the key through via a `merge_for_patch` hook so `PATCH {"ssid":"new"}` works without exposing or losing the key.
- **bus wrapper handles ucode-mod-ubus null-return semantics.** ucode's `conn.call()` returns null on error and stashes the message in a separate `ubus.error()` accessor (not a thrown exception). rc1's `try/catch` therefore never fired. rc2's `bus.call` wrapper checks `r == null && ubus.error() != null` and surfaces real errors via `die()`.
- **Lock open-failure surfaces 500.** rc1 collapsed `fs.open("/var/lock/uapi.lock") == null` (infrastructure problem) into `423 locked` (transient contention). rc2 distinguishes them: contention is `423` with `Retry-After`, infrastructure failure is `500 internal_error` with the path.
- **Audit gating.** `ERROR`/`WARN` syslog now scoped to 401/403/5xx (matching CLAUDE.md). `/healthz` excluded from all log categories. Non-auth 4xx (404/405/409/422/423) no longer emit log lines.
- **ucitrack `/etc/init.d/<package>` fallback.** Now implemented (rc1 promised it; the code path was missing). Lets `/raw/` writes against packages without a ucitrack entry still trigger the right service.
- **OpenAPI schema accuracy.** `dhcp.leases` schema now lists `{expires_at,mac,ip,hostname,duid}` instead of a `{id,managed}` stub. `wireless.interfaces` surfaces `key` (writeOnly) and `has_key` (readOnly).
- **CIDR validation.** `999.0.0.0/24` is now rejected; rc1 only checked digit shape.
- **firewall.redirects** ports/IPs are now arrays (matching firewall.rules).
- **PATCH `match` deep-merge generalized.** rc1 hardcoded the `match` key in `handler.make().patch()`; rc2 uses a per-resource `merge_for_patch` hook, eliminating a latent footgun for the next nested-object resource.

### Added

- **Mid-tree scope wildcards.** `firewall:*:ro` permits ro on every firewall subresource but not the bare domain. `*:rules:ro` matches the `rules` subresource of every domain. Exact segments beat wildcards at the same depth.
- **Observability knobs.** `/etc/config/uapi`'s `config logging` section enables `option access '1'` (every request emits an `ACCESS` INFO line) and `option debug '1'` (per-ubus-call trace at `LOG_DEBUG`). Both default off.
- **`/etc/uapi.insecure` marker now leaves an audit trail.** Every request that bypasses TLS via the marker emits a `uapi-insecure-bypass <request_id> <method> <path> status=<n> remote=<addr>` syslog NOTICE.
- **Mutual TLS docs.** `docs/installation.md` covers the `tls_client_cert_file` / `tls_require_client_cert` route for service-account-as-cert auth.
- **`lib/values.uc` shared helpers.** `normalize_bool`, `as_list`, `is_valid_ipv4`, `is_valid_ipv6`, `is_valid_ip`, `is_valid_cidr` - dedupes 9 modules of inline copies (one of which had drifted).
- **Sample syslog output.** `docs/operations.md` includes example lines for every audit category plus the insecure-bypass and internal-error formats.
- **README "Why this approach" section** framing how uapi differs from prior REST-for-OpenWrt attempts.

### Security

- **Service-name regex guard in `default_reload`.** `^[A-Za-z0-9_-]+$` enforced before interpolating into the `/etc/init.d/<svc>` command string. Defense-in-depth against a future ucitrack entry that could otherwise carry shell metacharacters.
- **`validate()` runs inside the flock.** rc1 ran cross-reference checks (e.g. `firewall.rules.match.src_zone` exists) before acquiring the lock; rc2 runs them inside the transaction so a concurrent zone delete cannot race a rule creation.

### Tests

- **17 new integration tests** covering: TLS-required from non-loopback, lock contention (`423 locked` with `Retry-After`), reload-failure rollback (fail-once injection via `/tmp/fw-fail-once`), audit-line emission, observability knobs, top-level exception handler, raw-409 conflict, token-lifecycle + revocation propagation, CRUD for every previously-uncovered curated resource (network.devices, wireless.devices, wireless.interfaces), adoption flow for every CRUD-capable resource.
- **mac80211_hwsim** auto-loaded in the QEMU VM so wireless tests run for real instead of skipping.
- **Conffile preservation** verified across a same-version reinstall in `release_apk_smoke.sh`.
- **Audit-log assertion** in `03_firewall_rules_crud_test.sh` (captures `X-Request-Id`, greps `logread`).
- Unit suite grew from 253 to 270 cases.

### Removed

- 11 dead exports across `lib/` (`errors.STATUS_BY_CODE`/`FIELD_CODES`, `ids.ALPHABET`/`ULID_LEN`, `scope.KNOWN_PATHS`, `transaction.LOCK_PATH`, `ucitrack.FALLBACK`, `values.IPV4_RE`/`IPV6_RE`/`CIDR_RE`/`is_valid_ipv6`).
- Dead helpers `auth.stub_enabled` / `auth.stub_token` (no longer needed after the real auth implementation landed in v1.0.0-rc1).
- Dead `bus.uci_add` (every write path uses `uci_create_section`).

### Docs

- `CLAUDE.md` rewritten "Atomic transaction recipe" to describe the `fs.popen` reload path and the rationale (every ubus-mediated reload is fire-and-forget).
- "Deferred / future work" reorganized into a "v1.1+ roadmap" with explicit reasoning for each item still missing in v1; the items rc2 implemented (TOCTOU fix, mid-tree wildcards, ucitrack init.d fallback, reload-rollback integration test, ACCESS/DEBUG knobs) are gone from the list.
- Process items dropped from the roadmap (feed submission, raw→curated promotion, i18n).

## [1.0.0-rc1] - 2026-05-28

First release candidate. Native HTTP REST API for OpenWrt 25.12+ packaged as a single `.apk`. The on-the-wire API contract (`/api/v2/...`) is what 1.0.0 will ship; the package version stays `rc` until real-world deployments shake out the install path on a variety of router configurations.

### Surface

- Bearer-token auth with hierarchical scopes (`*:rw`/`*:ro`, `<domain>:rw/ro`, `<domain>:<sub>:rw/ro`), deepest-match-wins, raw access requires both raw-tree and domain-tree permission.
- 10 curated resources: `firewall/{rules,zones,redirects}`, `network/{interfaces,devices}`, `wireless/{devices,interfaces}`, `dhcp/{hosts,leases}`, `system`.
- Generic `/raw/<package>/<id>` passthrough for any uci section type uapi does not curate.
- `/healthz` (no auth) probes ubus reachability.
- `/openapi.json` serves the OpenAPI 3.1 spec (no auth).
- Token CLI: `uapi-token create/list/show/revoke`. Cleartext tokens printed exactly once at creation, stored salted-sha256.

### Guarantees

- Atomic writes: per-request global flock (`/var/lock/uapi.lock`), uci snapshot, validate, stage, commit, daemon reload, restore on reload failure.
- Concurrent reads are lock-free and always permitted at the scope level.
- Audit log line per successful write (syslog `daemon.notice`, plain text, parseable by `logread`).
- Stable resource IDs (ULID with one-char type prefix) survive `/etc/config` rewrites; anonymous sections from other tools are surfaced read-only with `managed: false` until explicit `POST .../adopt`.
- v1 API is additive-only: see CLAUDE.md "API versioning policy" for what triggers v2.

### Distribution

- Single `.apk` package built against the OpenWrt 25.12.4 SDK.
- Conffile-marked token store at `/etc/config/uapi` preserved across upgrades and removal.
- uci-defaults install hook wires `uhttpd.main.ucode_prefix` and self-deletes; pre-remove hook unwires it.
- Release-tier CI builds the APK and runs a full install/use/remove smoke test in a fresh QEMU VM.

[Unreleased]: https://github.com/openwrt-iac/uapi/compare/v2.5.0...HEAD
[2.5.0]: https://github.com/openwrt-iac/uapi/compare/v2.4.1...v2.5.0
[2.4.1]: https://github.com/openwrt-iac/uapi/compare/v2.4.0...v2.4.1
[2.4.0]: https://github.com/openwrt-iac/uapi/compare/v2.3.0...v2.4.0
[2.3.0]: https://github.com/openwrt-iac/uapi/compare/v2.2.3...v2.3.0
[2.2.3]: https://github.com/openwrt-iac/uapi/compare/v2.2.2...v2.2.3
[2.2.2]: https://github.com/openwrt-iac/uapi/compare/v2.2.1...v2.2.2
[2.2.1]: https://github.com/openwrt-iac/uapi/compare/v2.2.0...v2.2.1
[2.2.0]: https://github.com/openwrt-iac/uapi/compare/v2.1.0...v2.2.0
[2.1.0]: https://github.com/openwrt-iac/uapi/compare/v2.0.2...v2.1.0
[2.0.2]: https://github.com/openwrt-iac/uapi/compare/v2.0.1...v2.0.2
[2.0.1]: https://github.com/openwrt-iac/uapi/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/openwrt-iac/uapi/compare/v2.0.0-rc4...v2.0.0
[2.0.0-rc4]: https://github.com/openwrt-iac/uapi/compare/v2.0.0-rc3...v2.0.0-rc4
[2.0.0-rc3]: https://github.com/openwrt-iac/uapi/compare/v2.0.0-rc2...v2.0.0-rc3
[2.0.0-rc2]: https://github.com/openwrt-iac/uapi/compare/v2.0.0-rc1...v2.0.0-rc2
[2.0.0-rc1]: https://github.com/openwrt-iac/uapi/compare/v1.2.1...v2.0.0-rc1
[1.2.1]: https://github.com/openwrt-iac/uapi/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/openwrt-iac/uapi/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/openwrt-iac/uapi/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/openwrt-iac/uapi/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/openwrt-iac/uapi/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/openwrt-iac/uapi/compare/v1.0.0-rc2...v1.0.0
[1.0.0-rc2]: https://github.com/openwrt-iac/uapi/compare/v1.0.0-rc1...v1.0.0-rc2
[1.0.0-rc1]: https://github.com/openwrt-iac/uapi/releases/tag/v1.0.0-rc1
