let fs = require('fs');
let values = require('values');
let strict_bool = values.strict_bool;
let ids = require('ids');
let platform_bool = values.platform_bool;
let as_list = values.as_list;
let as_word_list_or_null = values.as_word_list_or_null;
let is_valid_ipv4 = values.is_valid_ipv4;
let is_valid_cidr = values.is_valid_cidr;
let is_valid_cidr_any = values.is_valid_cidr_any;
let is_valid_ipv6 = values.is_valid_ipv6;
let is_valid_ipv6_cidr = values.is_valid_ipv6_cidr;
let netifd_int = values.netifd_int;
let ipv6_words = values.ipv6_words;

const PKG = "network";

// Linux IFNAMSIZ-1 caps the wireguard netdev name at 15 chars (netifd uses
// the section name as the kernel netdev); hyphens are valid in ifnames but
// uci section names reject them, so they're not in the charset either.
const IFNAMSIZ_RE = /^[A-Za-z][A-Za-z0-9_]{0,14}$/;

const VALID_PROTOS = {
	"static": true, "dhcp": true, "dhcpv6": true, "pppoe": true,
	"none": true, "ppp": true, "wwan": true, "wireguard": true,
};
const WG_KEY_RE = regexp("^" + values.WG_KEY_PATTERN + "$");
const VALID_REQADDRESS = { "try": true, "force": true, "none": true };
// Fields that apply only to some protos, after the proto scripts that read them and LuCI's
// forms. Every other field applies to every proto, because netifd reads it as a core interface
// attribute. A field outside its protos is hidden on read and dropped on write, and a request
// that names it is refused: netifd would ignore it, or toUci would drop it.
const FIELD_PROTOS = {
	ipaddr: [ "static" ], ipaddrs: [ "static" ], ip6addrs: [ "static" ],
	netmask: [ "static" ], broadcast: [ "static" ], gateway: [ "static" ], ip6gw: [ "static" ],
	ip6prefix: [ "static", "dhcpv6", "wireguard" ],
	broadcast_flag: [ "dhcp" ], hostname: [ "dhcp" ],
	clientid: [ "dhcp", "dhcpv6" ],
	reqaddress: [ "dhcpv6" ],
	reqprefix: [ "dhcpv6", "pppoe", "ppp" ],
	sourcefilter: [ "dhcpv6", "pppoe", "ppp" ],
	peerdns: [ "dhcp", "dhcpv6", "pppoe", "ppp", "wwan" ],
	private_key: [ "wireguard" ], has_private_key: [ "wireguard" ], listen_port: [ "wireguard" ],
	addresses: [ "wireguard" ], nohostroute: [ "wireguard" ],
};

// The table judges only the protos uapi models. A handler such as 6in4 reads ipaddr and
// ip6prefix, and uapi cannot know what else, so on such a proto every field applies except the
// two that are another reading of an option: uci `broadcast` there is no dhcp flag.
function applies(field, proto) {
	let protos = FIELD_PROTOS[field];
	return protos == null || index(protos, proto) != -1
		|| (!VALID_PROTOS[proto] && field != "broadcast_flag" && field != "has_private_key");
}

// One entry per group of fields that share their protos: on the other modelled protos, each
// field must be null. Generated from FIELD_PROTOS so the document and validate() cannot drift.
function proto_scope_conditionals() {
	let groups = {};
	for (let field, protos in FIELD_PROTOS) {
		let key = join(",", protos);
		if (groups[key] == null)
			groups[key] = { others: filter(keys(VALID_PROTOS), (p) => index(protos, p) == -1), fields: {} };
		groups[key].fields[field] = { type: "null" };
	}
	let out = [];
	for (let key, g in groups)
		push(out, { if: { properties: { proto: { enum: g.others } }, required: [ "proto" ] },
		            then: { properties: g.fields } });
	return out;
}

function fetch_runtime(conn, name) {
	if (conn == null || type(name) != "string" || name == "")
		return {};
	let status = null;
	try { status = conn.call("network.interface." + name, "status"); }
	catch (e) { return {}; }
	if (status == null) return {};
	// ubus emits hyphenated keys (ipv4-address, ipv6-address, ipv6-prefix).
	// Hyphenated identifiers are the only ones in our API surface that need
	// quoting in HCL/Go field tags; remap to snake_case to match the rest.
	return {
		up: !!status.up,
		pending: !!status.pending,
		available: !!status.available,
		// What netifd is actually running, which is not always what uci asks
		// for. netifd registers protocol handlers by scanning
		// /lib/netifd/proto at startup and caches the result: a reload does not
		// rescan, only a restart does. So a protocol whose package is absent, or
		// was installed after netifd started, is silently discarded and reported
		// as "none" while uci still holds the requested value. Comparing this
		// against `proto` is the only way to see that from outside.
		effective_proto: status.proto ?? null,
		l3_device: status.l3_device ?? null,
		uptime: status.uptime ?? null,
		ipv4_address: status["ipv4-address"] ?? [],
		ipv6_address: status["ipv6-address"] ?? [],
		ipv6_prefix:  status["ipv6-prefix"]  ?? [],
		route: status.route ?? [],
	};
}

function fromUci(section, conn) {
	let anonymous = !!section['.anonymous'];
	let proto = section.proto ?? "none";
	// Modern OpenWrt (25+) writes `list ipaddr` for multi-address static
	// interfaces (e.g. loopback ships as `list ipaddr '127.0.0.1/8'`), while
	// older configs used `option ipaddr 'x.x.x.x'`. Surface BOTH forms:
	// `ipaddr` keeps the v1.0/v1.1 contract (a single string; the first entry
	// when uci has a list), and a new `ipaddrs` array holds the full set.
	// netifd reads a scalar as whitespace-separated words, and `option ipaddr ''` as nothing.
	let ipaddrs = as_word_list_or_null(section.ipaddr);
	let ipaddr_first = (ipaddrs != null) ? ipaddrs[0] : null;
	let view = {
		id: section['.name'],
		managed: !anonymous,
		device: section.device ?? null,
		proto: proto,
		ipaddr: ipaddr_first,
		ipaddrs: ipaddrs,
		// uci holds IPv6 static addressing in a separate `list ip6addr`, and modelling only
		// the v4 list made an IPv6-addressed interface read back with no addresses at all and
		// no indication that a value had been seen and dropped.
		ip6addrs: as_word_list_or_null(section.ip6addr),
		netmask: section.netmask ?? null,
		gateway: section.gateway ?? null,
		broadcast: section.broadcast ?? null,
		ip6gw: section.ip6gw ?? null,
		ip6prefix: as_word_list_or_null(section.ip6prefix),
		dns: as_word_list_or_null(section.dns),
		// netifd reads the ip6assign group for every proto. It once lived in the dhcpv6 block, whose
		// script never reads ip6hint, so a static LAN wrote it into nothing and a PUT erased LuCI's.
		ip6assign: netifd_int(section.ip6assign),
		ip6hint: section.ip6hint ?? null,
		ip6ifaceid: section.ip6ifaceid ?? null,
		ip6class: as_word_list_or_null(section.ip6class),
		ip6weight: netifd_int(section.ip6weight),
		mtu: netifd_int(section.mtu),
		auto: platform_bool(section.auto, true),
		// `auto` controls bring-up at boot; `disabled` is stronger and separate: netifd
		// does not register the interface at all, so it has no ubus object and its
		// addresses, routes and peers go with it. Unmodelled, that box reads as ordinary
		// active config, which is the one thing a read must never do.
		//
		// strict_bool, not the platform_bool that `network/routes` and `network/rules` use
		// for the same option name. netifd compares this one literally against "1" while
		// route and rule go through the boolean blob converter, which also takes "true", so
		// on 25.12.5 `disabled 'true'` disables a route and leaves an interface running.
		// Measured three times against a reset baseline: the interface stayed registered on
		// ubus every time. Reading it with the wider helper would report an interface as
		// disabled while it is up, which is the same lie this field exists to end.
		disabled: strict_bool(section.disabled),
		ip4table: section.ip4table ?? null,
		ip6table: section.ip6table ?? null,
		metric: netifd_int(section.metric),
		// The booleans below read null when uci has nothing explicitly set. Surfacing the daemon's
		// effective default would have the patch merge write it into uci on the next PATCH,
		// silently changing the section's surface area for the client.
		defaultroute: (section.defaultroute != null) ? platform_bool(section.defaultroute, true) : null,
		delegate: (section.delegate != null) ? platform_bool(section.delegate, true) : null,
		peerdns: (section.peerdns != null) ? platform_bool(section.peerdns, true) : null,
		// On proto dhcp, uci's `broadcast` is the flag dhcp.sh passes to udhcpc as -B, not an
		// address, so the static reader turned LuCI's `broadcast '1'` into an address that a PUT
		// of the read then refused.
		broadcast_flag: (section.broadcast != null) ? platform_bool(section.broadcast, false) : null,
		hostname: section.hostname ?? null,
		clientid: section.clientid ?? null,
		reqprefix: section.reqprefix ?? null,
		reqaddress: section.reqaddress ?? null,
		sourcefilter: (section.sourcefilter != null) ? platform_bool(section.sourcefilter, true) : null,
		listen_port: values.service_port(section.listen_port, () => fs.readfile("/etc/services"), -1),
		addresses: as_word_list_or_null(section.addresses),
		nohostroute: strict_bool(section.nohostroute),
		has_private_key: (section.private_key != null && section.private_key != ""),
		runtime: fetch_runtime(conn, section['.name']),
	};
	for (let field in FIELD_PROTOS)
		if (!applies(field, proto) || (!VALID_PROTOS[proto] && view[field] == null))
			delete view[field];
	return view;
}

function toUci(body) {
	let json = {};
	for (let k, v in body)
		if (applies(k, body.proto)) json[k] = v;
	let out = {};
	if (json.device != null) out.device = json.device;
	if (json.proto != null) out.proto = json.proto;
	// uci handles both `option ipaddr` and `list ipaddr` semantically; the
	// list form is required for multi-address static interfaces.
	if (type(json.ipaddrs) == "array" && length(json.ipaddrs) > 0)
		out.ipaddr = json.ipaddrs;
	if (type(json.ip6addrs) == "array" && length(json.ip6addrs) > 0)
		out.ip6addr = json.ip6addrs;

	if (json.netmask != null) out.netmask = json.netmask;
	if (json.gateway != null) out.gateway = json.gateway;
	if (json.broadcast != null) out.broadcast = json.broadcast;
	if (json.ip6gw != null) out.ip6gw = json.ip6gw;
	// One prefix is written as a scalar: uci's blob.c drops a list given to a string attribute,
	// and 6rd, map and 464xlat read ip6prefix as one string. A string from a writer is split the
	// way netifd splits a stored one.
	let ip6prefix = as_word_list_or_null(json.ip6prefix);
	if (length(ip6prefix) > 0) out.ip6prefix = (length(ip6prefix) > 1) ? ip6prefix : ip6prefix[0];
	if (type(json.dns) == "array" && length(json.dns) > 0) out.dns = json.dns;
	if (json.ip6assign != null) out.ip6assign = "" + json.ip6assign;
	if (json.ip6hint != null) out.ip6hint = json.ip6hint;
	if (json.ip6ifaceid != null) out.ip6ifaceid = json.ip6ifaceid;
	if (type(json.ip6class) == "array" && length(json.ip6class) > 0) out.ip6class = json.ip6class;
	if (json.ip6weight != null) out.ip6weight = "" + json.ip6weight;
	if (json.mtu != null) out.mtu = "" + json.mtu;
	if (json.auto != null) out.auto = json.auto ? "1" : "0";
	if (json.disabled != null) out.disabled = json.disabled ? "1" : "0";
	if (json.ip4table != null) out.ip4table = "" + json.ip4table;
	if (json.ip6table != null) out.ip6table = "" + json.ip6table;
	if (json.metric != null) out.metric = "" + json.metric;
	if (json.defaultroute != null) out.defaultroute = json.defaultroute ? "1" : "0";
	if (json.delegate != null) out.delegate = json.delegate ? "1" : "0";
	if (json.peerdns != null) out.peerdns = json.peerdns ? "1" : "0";
	if (json.broadcast_flag != null) out.broadcast = json.broadcast_flag ? "1" : "0";
	if (json.hostname != null) out.hostname = json.hostname;
	if (json.clientid != null) out.clientid = json.clientid;
	if (json.reqprefix != null) out.reqprefix = "" + json.reqprefix;
	if (json.reqaddress != null) out.reqaddress = json.reqaddress;
	if (json.sourcefilter != null) out.sourcefilter = json.sourcefilter ? "1" : "0";
	if (json.private_key != null) out.private_key = json.private_key;
	if (json.listen_port != null) out.listen_port = "" + json.listen_port;
	if (type(json.addresses) == "array" && length(json.addresses) > 0)
		out.addresses = json.addresses;
	if (json.nohostroute != null) out.nohostroute = json.nohostroute ? "1" : "0";
	return out;
}

function validate(json, conn, id, delta) {
	let errs = [];

	values.require_present(errs, json, "proto");

	// Only what the request named: a PATCH that switches proto still carries the old proto's
	// fields in its merged view, and toUci drops them. The read-only twins never write, and an
	// empty value asks for nothing, as a module that writes `cond ? [...] : []` sends.
	let named = delta ?? json;
	// Here rather than as an enum in schema_properties, which the Response would then declare
	// although a read answers any proto that uci stores. Only a request that names the proto is
	// refused, so a PATCH of either kind that leaves it out keeps the options of the handler,
	// which toUci cannot emit. The sweep passes the read as delta and still lists the section,
	// because a PUT of it is refused.
	if (named.proto != null && type(json.proto) == "string" && !VALID_PROTOS[json.proto])
		push(errs, { field: "proto", code: "not_in_enum",
		             message: sprintf("must be one of %s: uapi does not write proto %s. A PATCH that leaves proto out keeps the options that its handler reads",
		                              join(", ", keys(VALID_PROTOS)), json.proto) });
	if (type(json.proto) == "string")
		for (let field, v in named) {
			if (v == null || v === "" || (type(v) == "array" && length(v) == 0)
			    || field == "ipaddr" || field == "has_private_key" || applies(field, json.proto))
				continue;
			let protos = FIELD_PROTOS[field];
			push(errs, { field, code: "conflict",
			             message: sprintf("applies only when proto is %s; send null or leave it out",
			                              length(protos) == 1 ? protos[0] : "one of " + join(", ", protos)) });
		}

	// `id` is the universal section-name input and goes through the framework's
	// validate_section_id for the broader uci section-name rules; the tighter IFNAMSIZ
	// cap below applies only where netifd uses the section name as the kernel netdev name.
	if (id != null && json.id != null && json.id != id)
		push(errs, { field: "id", code: "read_only",
		             message: "id can only be set at create time; rename via DELETE + POST" });
	// For proto=wireguard, the IFNAMSIZ-tight cap is a kernel constraint:
	// netifd uses the uci section name as the netdev name and Linux's
	// IFNAMSIZ limits that to 15 chars. Tighten beyond the framework's
	// 32-char default when the caller supplied `id` directly on a
	// wireguard interface.
	if (id == null && json.id != null && json.proto == "wireguard"
	    && (type(json.id) != "string" || !match(json.id, IFNAMSIZ_RE)))
		push(errs, { field: "id", code: "invalid_format",
		             message: "must match [A-Za-z][A-Za-z0-9_]{0,14} (proto=wireguard binds the uci section name to the kernel netdev name; IFNAMSIZ caps it at 15 chars)" });

	// Each format check runs only where its field applies. Elsewhere toUci drops the field and
	// the check above refuses a request that names it, so a stale value stored under another
	// proto must not block the PATCH that switches away from it.
	let ok = (field) => applies(field, json.proto);
	if (ok("netmask") && json.netmask != null && json.netmask != "" && !is_valid_ipv4(json.netmask))
		push(errs, { field: "netmask", code: "invalid_format",
		             message: "must be a valid IPv4 netmask" });
	if (ok("gateway") && json.gateway != null && json.gateway != "" && !is_valid_ipv4(json.gateway))
		push(errs, { field: "gateway", code: "invalid_format",
		             message: "must be a valid IPv4 address" });
	if (ok("broadcast") && json.broadcast != null && json.broadcast != "" && !is_valid_ipv4(json.broadcast))
		push(errs, { field: "broadcast", code: "invalid_format",
		             message: "must be a valid IPv4 address" });
	// netifd wants a bare address for the gateway and accepts a prefix length on the routed
	// prefix, which is the same split LuCI encodes as ip6addr("nomask") against ip6addr.
	if (ok("ip6gw") && json.ip6gw != null && json.ip6gw != "" && !is_valid_ipv6(json.ip6gw))
		push(errs, { field: "ip6gw", code: "invalid_format",
		             message: "must be a valid IPv6 address without a prefix length" });
	let ip6prefix = ok("ip6prefix") ? as_word_list_or_null(json.ip6prefix) : null;
	for (let i = 0; i < length(ip6prefix); i++)
		if (type(ip6prefix[i]) == "string" && !is_valid_ipv6_cidr(ip6prefix[i]) && !is_valid_ipv6(ip6prefix[i]))
			push(errs, { field: sprintf("ip6prefix[%d]", i), code: "invalid_format",
			             message: "must be a valid IPv6 address or prefix" });
	for (let i = 0; ok("ipaddrs") && type(json.ipaddrs) == "array" && i < length(json.ipaddrs); i++) {
		if (!is_valid_ipv4(json.ipaddrs[i]) && !is_valid_cidr(json.ipaddrs[i]))
			push(errs, { field: sprintf("ipaddrs[%d]", i), code: "invalid_format",
			             message: "must be a valid IPv4 address or CIDR" });
	}
	for (let i = 0; ok("ip6addrs") && type(json.ip6addrs) == "array" && i < length(json.ip6addrs); i++) {
		if (!is_valid_ipv6(json.ip6addrs[i]) && !is_valid_ipv6_cidr(json.ip6addrs[i]))
			push(errs, { field: sprintf("ip6addrs[%d]", i), code: "invalid_format",
			             message: "must be a valid IPv6 address or CIDR" });
	}

	if (json.proto == "static") {
		// One address family is enough, matching LuCI, whose static form marks neither
		// `ipaddr` nor `ip6addr` required. Demanding IPv4 made an IPv6-only interface
		// unwritable and so unable to round-trip its own read.
		//
		// The read-only `ipaddr` deliberately does not count. Only `ipaddrs` and `ip6addrs`
		// write, so a body carrying the scalar alone once satisfied the requirement and then
		// wrote nothing: uapi created an addressless static interface and answered 200.
		let has_list = type(json.ipaddrs) == "array" && length(json.ipaddrs) > 0;
		let has_v6 = type(json.ip6addrs) == "array" && length(json.ip6addrs) > 0;
		if (!has_list && !has_v6)
			push(errs, { field: "ipaddrs", code: "required",
			             message: "either ipaddrs or ip6addrs is required when proto is static" });
	}

	if (json.proto == "wireguard") {
		if (json.private_key == null || json.private_key == "")
			push(errs, { field: "private_key", code: "required",
			             message: "is required when proto is wireguard" });
		// A write carries the stored key forward, so the message has to say how to replace one.
		else if (!match(json.private_key, WG_KEY_RE))
			push(errs, { field: "private_key", code: "invalid_format",
			             message: "must be a 44-char base64 WireGuard private key as wg genkey prints it: send a new one to replace a stored key that wg refuses" });
		let addrs = as_list(json.addresses);
		if (length(addrs) == 0)
			push(errs, { field: "addresses", code: "required",
			             message: "is required when proto is wireguard (list of CIDRs)" });
		for (let i = 0; i < length(addrs); i++) {
			// Both families: a wireguard tunnel's own address list is routinely v6 or
			// dual-stack, netifd's handler parses either, and `ipaddr`/`ipaddrs` above
			// stay v4-only because those are the static-proto v4 fields.
			if (!is_valid_cidr_any(addrs[i]))
				push(errs, { field: sprintf("addresses[%d]", i), code: "invalid_format",
				             message: "must be a valid IPv4 or IPv6 CIDR" });
		}
	}

	// These follow LuCI. netifd parses ip6hint with strtol(v, NULL, 16), so a prefix such as
	// 2001:db8::/56 was not ignored: it became subnet 0x2001. An empty string clears the option.
	if (json.ip6hint != null && json.ip6hint != "") {
		let m = match(json.ip6hint, /^(0x)?([0-9A-Fa-f]+)$/);
		let digits = (m != null) ? ltrim(m[2], "0") : null;
		if (digits == null || length(digits) > 8 || hex(digits) >= 0xffffffff)
			push(errs, { field: "ip6hint", code: "invalid_format",
			             message: "must be a hexadecimal subnet id below 0xffffffff, such as 1 or 0x1f" });
	}
	if (json.ip6ifaceid != null && json.ip6ifaceid != "" && json.ip6ifaceid != "eui64" && json.ip6ifaceid != "random") {
		let w = ipv6_words(json.ip6ifaceid);
		if (w == null || w[0] || w[1] || w[2] || w[3])
			push(errs, { field: "ip6ifaceid", code: "invalid_format",
			             message: "must be eui64, random, or an interface id whose network half is zero, such as ::1" });
	}
	// The schema allows -1 because a read reports a port name that /etc/services does not resolve
	// as -1.
	if (ok("listen_port") && json.listen_port === -1)
		push(errs, { field: "listen_port", code: "out_of_range",
		             message: "must be from 0 to 65535: -1 is how a port name that /etc/services does not resolve reads, and wg cannot bring the interface up with it" });
	// odhcp6c takes -P<len> or -P<prefix>/<len>, and LuCI documents both forms.
	if (ok("reqprefix") && type(json.reqprefix) == "string" && index(json.reqprefix, "/") != -1
	    && !is_valid_ipv6_cidr(json.reqprefix))
		push(errs, { field: "reqprefix", code: "invalid_format",
		             message: "must be auto, no, a prefix length, or an IPv6 prefix such as 2001:db8::/56" });
	// The schema allows the whole range so that a stored value reads as it is. ppp.sh hands the
	// mtu to pppd, which exits outside 128..16384 and leaves the interface down. Elsewhere netifd
	// applies a device mtu only from 68 up, and wireguard.sh applies a smaller one, which leaves
	// the device with no IPv4 address while netifd reports the interface up.
	if (type(json.mtu) == "int") {
		if (json.proto == "ppp" || json.proto == "pppoe") {
			if (json.mtu < 128 || json.mtu > 16384)
				push(errs, { field: "mtu", code: "out_of_range",
				             message: "must be from 128 to 16384: pppd refuses anything else and leaves the interface down" });
		}
		else if (json.mtu < 68)
			push(errs, { field: "mtu", code: "out_of_range",
			             message: "must be at least 68: netifd ignores a smaller device mtu, and a WireGuard device below 68 carries no IPv4" });
	}
	if (type(json.ip6class) == "array")
		for (let i = 0; i < length(json.ip6class); i++)
			if (type(json.ip6class[i]) != "string" || !match(json.ip6class[i], /^[A-Za-z0-9_]+$/))
				push(errs, { field: sprintf("ip6class[%d]", i), code: "invalid_format",
				             message: "must be local or an interface name" });

	return errs;
}

return {
	package: PKG,
	type: "interface",
	reload: ["network"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	// Opt in to the advisory management-path warning. Only this resource carries the
	// fields that can move the caller's own path, and `disabled` on a peer or a rule is
	// not the same condition, so the framework is told rather than guessing.
	mgmt_path_guard: true,
	// Caller-supplied name wins. proto=wireguard falls back to a 14-char
	// wg_<rand> (netifd's IFNAMSIZ constraint); other protos return null
	// so handler.create emits the standard 28-char ULID.
	id_for_create: function(body) {
		if (body == null) return null;
		if (body.proto == "wireguard") return ids.new_id("wg", 11);
		return null;
	},
	openapi_singular: "network interface",
	openapi_required: ["proto"],
	openapi_conditional: [
		{ if:   { properties: { proto: { const: "static" } }, required: ["proto"] },
		  then: { anyOf: [
		            { required: ["ipaddr"] },
		            { required: ["ipaddrs"] },
		            { required: ["ip6addrs"] },
		          ] } },
		// private_key is write-only; GET surfaces only has_private_key, so listing
		// it in `required` would make strict OpenAPI client codegen reject reads.
		// validate() enforces presence on create.
		{ if:   { properties: { proto: { const: "wireguard" } }, required: ["proto"] },
		  then: { required: ["addresses"] } },
		...proto_scope_conditionals(),
	],
	openapi_write_conditional: [
		{ if:   { properties: { proto: { enum: [ "ppp", "pppoe" ] } }, required: ["proto"] },
		  then: { properties: { mtu: { minimum: 128, maximum: 16384 } } } },
	],
	openapi_runtime: {
		type: "object",
		description: "Populated from ubus network.interface.<name> status; empty {} when the interface has no runtime state.",
		properties: {
			up:               { type: "boolean" },
			pending:          { type: "boolean" },
			available:        { type: "boolean" },
			effective_proto:  { type: ["string", "null"],
			                    description: "The protocol netifd is actually running for this interface. Differs from the configured `proto` when no handler is registered for it, in which case netifd reports `none` and the interface is inert; a mismatch means the device needs the handler package and a networking restart." },
			l3_device:        { type: ["string", "null"] },
			uptime:           { type: ["integer", "null"], minimum: 0 },
			ipv4_address:     { type: "array", items: { type: "object" } },
			ipv6_address:     { type: "array", items: { type: "object" } },
			ipv6_prefix:      { type: "array", items: { type: "object" } },
			route:            { type: "array", items: { type: "object" } },
		},
	},
	schema_properties: {
		proto: { type: "string", default: "none", "x-uapi-write": { enum: keys(VALID_PROTOS) },
		         description: "Interface protocol. Several values need a handler package on the device: wwan needs `wwan`, wireguard needs `wireguard-tools`, dhcpv6 needs `odhcp6c`, and ppp/pppoe need `ppp`. When the handler is missing the write still succeeds and the interface is inert; `runtime.effective_proto` is what reveals it. A read answers any proto that uci stores, such as the `6in4` that LuCI writes, while a write takes only the protos that the request schema lists. On another proto, a PATCH that leaves `proto` out keeps the options that its handler reads." },
		id:        { type: "string", pattern: "^[A-Za-z][A-Za-z0-9_]{0,31}$",
		             description: "Create-time only; picks the uci section name (which becomes the uapi `id` field). When omitted, the server emits a 14-char `wg_<rand>` for proto=wireguard (fits Linux IFNAMSIZ for the kernel netdev) or a 28-char ULID otherwise. Useful for LuCI parity (`lan`, `wan`, `guest`) and readable cross-references. For proto=wireguard the value must additionally fit IFNAMSIZ (15 chars max)." },
		device:    { type: ["string", "null"],
		             description: "Physical or logical L2 device this interface binds to" },
		ipaddr:    { type: ["string", "null"], readOnly: true,
		             description: "First entry of the uci `list ipaddr`. Read-only: send `ipaddrs` to write, which names the same uci option." },
		ipaddrs:   { type: ["array", "null"], items: { type: "string" },
		             description: "Full IPv4 address list for static proto (uci `list ipaddr`). The only write name for this option; `ipaddr` is the read-only first entry." },
		ip6addrs:  { type: ["array", "null"], items: { type: "string" },
		             description: "IPv6 address list for static proto (uci `list ip6addr`). A static interface needs either this or `ipaddrs`, not both." },
		netmask:   { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		             description: "IPv4 netmask (static proto)" },
		broadcast: { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		             description: "IPv4 broadcast address (static proto). On proto dhcp the same uci option is a flag, `broadcast_flag`." },
		ip6gw:     { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		             description: "IPv6 default gateway, a bare address with no prefix length (static proto)" },
		ip6prefix: { type: ["array", "string", "null"], "x-uapi-clear-on-omit": true, "x-uapi-write-string": true,
		             items: { type: "string" },
		             description: "IPv6 prefixes routed to this device for delegation to clients (static, dhcpv6, wireguard). Responses are always an array. A space-separated string is still accepted on write; v4 removes that (see docs/deprecations.md)." },
		gateway:   { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		             description: "IPv4 default gateway (static proto)" },
		dns:       { type: ["array", "null"], items: { type: "string" } },
		ip6assign: { type: ["integer", "null"], minimum: 0, maximum: 128,
		             description: "Prefix length to assign downstream from a delegated prefix" },
		ip6hint:   { type: ["string", "null"],
		             description: "Hexadecimal subnet id that picks which part of a delegated or ULA prefix this interface gets, such as `1` or `0x1f`, below `0xffffffff`. netifd uses it only when `ip6assign` is set, from 33 to 64." },
		ip6ifaceid: { type: ["string", "null"],
		             description: "Interface id of the address this interface takes from an assigned prefix: `eui64`, `random`, or a fixed id whose network half is zero, such as `::1`. On proto dhcpv6, odhcp6c also uses it for the upstream address." },
		ip6class:  { type: ["array", "null"], items: { type: "string" },
		             description: "Prefix classes this interface may take its assignment from: `local` for the ULA prefix, or the name of the interface that received the prefix. Unset means any." },
		ip6weight: { type: ["integer", "null"], minimum: 0, maximum: 2147483647,
		             description: "Assignment preference: when several interfaces share a prefix, the ones with a higher weight get their subnet first." },
		mtu:       { type: ["integer", "null"], minimum: 0, maximum: 65535, "x-uapi-write": { minimum: 68 },
		             description: "MTU that netifd applies to the interface's devices, from 68 up: the device named by `device` when it has no `config device` section of its own (a dotted VLAN such as `br-lan.10` included), and every device that joins the interface later, such as a Wi-Fi netdev, which then lowers a bridge it joins. A device with its own section keeps its own settings: set its MTU on network/devices, after adopting an anonymous section. On ppp and pppoe the value also goes to pppd, which takes 128 to 16384. wireguard.sh applies it to the tunnel itself. A stored value outside these ranges reads as it is, and a write outside them answers 422." },
		auto:      { type: "boolean", default: true,
		             description: "Bring this interface up at boot" },
		disabled:  { type: "boolean", default: false,
		             description: "Whether netifd ignores this interface entirely. A disabled interface is not registered at all, so it has no ubus object and its addresses and routes are not installed." },
		addresses: { type: ["array", "null"], items: { type: "string" } },
		private_key: { type: "string", writeOnly: true,
		               description: "WireGuard private key; accepted on write, masked on read" },
		has_private_key: { type: "boolean", readOnly: true },
		listen_port:  { "x-uapi-read-nullable": true, type: "integer", minimum: -1, maximum: 65535, "x-uapi-write": { minimum: 0 },
		                description: "WireGuard listen port; 0 or unset lets the kernel pick one. A service name that uci stores, such as `openvpn`, reads as its port from /etc/services, as wg resolves it. -1 reads when the name does not resolve, and then wg cannot bring the interface up; a write of -1 answers 422." },
		nohostroute:  { type: "boolean",
		                description: "Suppress the implicit host-route for wireguard endpoint" },
		ip4table:     { type: ["string", "null"],
		                description: "Routing table for the IPv4 routes this interface installs: a number or a name from /etc/iproute2/rt_tables" },
		ip6table:     { type: ["string", "null"],
		                description: "Routing table for the IPv6 routes this interface installs: a number or a name from /etc/iproute2/rt_tables" },
		peerdns:      { "x-uapi-read-nullable": true, type: "boolean",
		                description: "Use the DNS servers the upstream advertises (dhcp, dhcpv6, pppoe, ppp, wwan). Unset means true." },
		defaultroute: { "x-uapi-read-nullable": true, type: "boolean",
		                description: "Install the default route the protocol provides. Unset means true." },
		metric:       { "x-uapi-read-nullable": true, type: "integer", minimum: 0,
		                description: "Metric of the routes this interface installs without one of their own" },
		broadcast_flag: { "x-uapi-read-nullable": true, type: "boolean",
		                description: "Ask the DHCP server to broadcast its replies, as LuCI's \"Use broadcast flag\" (dhcp). Stored in uci as `broadcast`, which is an address on proto static. Unset means false." },
		hostname:     { "x-uapi-read-nullable": true, type: "string",
		                description: "Client hostname sent in DHCPDISCOVER (dhcp)" },
		clientid:     { "x-uapi-read-nullable": true, type: "string", pattern: "^[0-9A-Fa-f:]*$",
		                description: "Client identifier: DHCP option 61 on proto dhcp, a DUID on proto dhcpv6, as hex digits with optional colons" },
		reqprefix:    { "x-uapi-read-nullable": true, type: "string", pattern: "^(auto|no|[0-9]+|[0-9A-Fa-f:]+/[0-9]+)$",
		                description: "Prefix delegation request (dhcpv6, pppoe, ppp): auto, no, a prefix length, or a prefix such as 2001:db8::/56" },
		reqaddress:   { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_REQADDRESS),
		                description: "DHCPv6 IA_NA request mode (dhcpv6)" },
		delegate:     { "x-uapi-read-nullable": true, type: "boolean",
		                description: "Hand this interface's IPv6 prefixes on to downstream interfaces. Unset means true." },
		sourcefilter: { "x-uapi-read-nullable": true, type: "boolean",
		                description: "Source-specific default routes (dhcpv6, ppp, pppoe). Unset means true. False adds the upstream default route without a source, which a routed `ip6prefix` needs: traffic from its downstream subnets matches no source-specific route." },
	},
};
