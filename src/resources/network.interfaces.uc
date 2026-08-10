let values = require('values');
let strict_bool = values.strict_bool;
let ids = require('ids');
let platform_bool = values.platform_bool;
let as_list = values.as_list;
let as_list_or_null = values.as_list_or_null;
let is_valid_ipv4 = values.is_valid_ipv4;
let is_valid_cidr = values.is_valid_cidr;
let is_valid_cidr_any = values.is_valid_cidr_any;
let is_valid_ipv6 = values.is_valid_ipv6;
let is_valid_ipv6_cidr = values.is_valid_ipv6_cidr;
let as_int = values.as_int;

const PKG = "network";

// Linux IFNAMSIZ-1 caps the wireguard netdev name at 15 chars (netifd uses
// the section name as the kernel netdev); hyphens are valid in ifnames but
// uci section names reject them, so they're not in the charset either.
const IFNAMSIZ_RE = /^[A-Za-z][A-Za-z0-9_]{0,14}$/;

const VALID_PROTOS = {
	"static": true, "dhcp": true, "dhcpv6": true, "pppoe": true,
	"none": true, "ppp": true, "wwan": true, "wireguard": true,
};
const WG_KEY_RE = /^[A-Za-z0-9+/]{43}=$/;
const VALID_REQADDRESS = { "try": true, "force": true, "none": true };
const IPV6_PREFIX_RE = /^[0-9A-Fa-f:]+\/[0-9]+$/;
const IPV6_IFACEID_RE = /^[0-9A-Fa-f:]+$/;

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
	// Coerced by hand rather than through as_list_or_null because the empty string has to
	// collapse too: a `option ipaddr ''` is uci's way of holding nothing here.
	let ipaddr_raw = (section.ipaddr == "") ? null : section.ipaddr;
	let ipaddrs = values.as_list_or_null(ipaddr_raw);
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
		ip6addrs: as_list_or_null(section.ip6addr),
		netmask: section.netmask ?? null,
		gateway: section.gateway ?? null,
		broadcast: section.broadcast ?? null,
		ip6gw: section.ip6gw ?? null,
		ip6prefix: section.ip6prefix ?? null,
		dns: as_list_or_null(section.dns),
		ip6assign: as_int(section.ip6assign),
		mtu: as_int(section.mtu),
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
		runtime: fetch_runtime(conn, section['.name']),
	};
	if (proto == "wireguard") {
		view.listen_port = as_int(section.listen_port);
		view.addresses = as_list_or_null(section.addresses);
		view.nohostroute = strict_bool(section.nohostroute);
		view.ip4table = section.ip4table ?? null;
		view.ip6table = section.ip6table ?? null;
		view.has_private_key = (section.private_key != null && section.private_key != "");
	}
	// For the v1.2 dhcp / dhcpv6 fields, surface null when uci has nothing
	// explicitly set. Surfacing the daemon's effective default would have the
	// patch merge write those defaults into uci on the next PATCH, silently
	// changing the section's surface area for the client.
	if (proto == "dhcp") {
		view.peerdns = (section.peerdns != null) ? platform_bool(section.peerdns, true) : null;
		view.defaultroute = (section.defaultroute != null) ? platform_bool(section.defaultroute, true) : null;
		view.metric = as_int(section.metric);
		view.hostname = section.hostname ?? null;
		view.clientid = section.clientid ?? null;
	}
	if (proto == "dhcpv6") {
		view.peerdns = (section.peerdns != null) ? platform_bool(section.peerdns, true) : null;
		view.reqprefix = section.reqprefix ?? null;
		view.reqaddress = section.reqaddress ?? null;
		view.ip6hint = section.ip6hint ?? null;
		view.ip6ifaceid = section.ip6ifaceid ?? null;
		view.delegate = (section.delegate != null) ? platform_bool(section.delegate, true) : null;
	}
	return view;
}

function toUci(json) {
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
	if (json.ip6prefix != null) out.ip6prefix = json.ip6prefix;
	if (type(json.dns) == "array" && length(json.dns) > 0) out.dns = json.dns;
	if (json.ip6assign != null) out.ip6assign = "" + json.ip6assign;
	if (json.mtu != null) out.mtu = "" + json.mtu;
	if (json.auto != null) out.auto = json.auto ? "1" : "0";
	if (json.disabled != null) out.disabled = json.disabled ? "1" : "0";
	if (json.proto == "wireguard") {
		if (json.private_key != null) out.private_key = json.private_key;
		if (json.listen_port != null) out.listen_port = "" + json.listen_port;
		if (type(json.addresses) == "array" && length(json.addresses) > 0)
			out.addresses = json.addresses;
		if (json.nohostroute != null) out.nohostroute = json.nohostroute ? "1" : "0";
		if (json.ip4table != null) out.ip4table = "" + json.ip4table;
		if (json.ip6table != null) out.ip6table = "" + json.ip6table;
	}
	if (json.proto == "dhcp") {
		if (json.peerdns != null)      out.peerdns = json.peerdns ? "1" : "0";
		if (json.defaultroute != null) out.defaultroute = json.defaultroute ? "1" : "0";
		if (json.metric != null)       out.metric = "" + json.metric;
		if (json.hostname != null)     out.hostname = json.hostname;
		if (json.clientid != null)     out.clientid = json.clientid;
	}
	if (json.proto == "dhcpv6") {
		if (json.peerdns != null)    out.peerdns = json.peerdns ? "1" : "0";
		if (json.reqprefix != null)  out.reqprefix = "" + json.reqprefix;
		if (json.reqaddress != null) out.reqaddress = json.reqaddress;
		if (json.ip6hint != null)    out.ip6hint = json.ip6hint;
		if (json.ip6ifaceid != null) out.ip6ifaceid = json.ip6ifaceid;
		if (json.delegate != null)   out.delegate = json.delegate ? "1" : "0";
	}
	return out;
}

function validate(json, conn, id) {
	let errs = [];

	values.require_present(errs, json, "proto");

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

	if (json.proto == "static") {
		let has_list = type(json.ipaddrs) == "array" && length(json.ipaddrs) > 0;
		let has_v6 = type(json.ip6addrs) == "array" && length(json.ip6addrs) > 0;
		// One address family is enough, matching LuCI, whose static form marks neither
		// `ipaddr` nor `ip6addr` required. Demanding IPv4 made an IPv6-only interface
		// unwritable and so unable to round-trip its own read.
		//
		// The read-only `ipaddr` deliberately does not count. Only `ipaddrs` and `ip6addrs`
		// write, so a body carrying the scalar alone once satisfied the requirement and then
		// wrote nothing: uapi created an addressless static interface and answered 200.
		if (!has_list && !has_v6)
			push(errs, { field: "ipaddrs", code: "required",
			             message: "either ipaddrs or ip6addrs is required when proto is static" });
		if (has_list) {
			for (let i = 0; i < length(json.ipaddrs); i++) {
				if (!is_valid_ipv4(json.ipaddrs[i]) && !is_valid_cidr(json.ipaddrs[i]))
					push(errs, { field: sprintf("ipaddrs[%d]", i), code: "invalid_format",
					             message: "must be a valid IPv4 address or CIDR" });
			}
		}
		if (has_v6) {
			for (let i = 0; i < length(json.ip6addrs); i++) {
				if (!is_valid_ipv6(json.ip6addrs[i]) && !is_valid_ipv6_cidr(json.ip6addrs[i]))
					push(errs, { field: sprintf("ip6addrs[%d]", i), code: "invalid_format",
					             message: "must be a valid IPv6 address or CIDR" });
			}
		}
		if (json.netmask != null && json.netmask != "" && !is_valid_ipv4(json.netmask))
			push(errs, { field: "netmask", code: "invalid_format",
			             message: "must be a valid IPv4 netmask" });
		if (json.broadcast != null && json.broadcast != "" && !is_valid_ipv4(json.broadcast))
			push(errs, { field: "broadcast", code: "invalid_format",
			             message: "must be a valid IPv4 address" });
		// netifd wants a bare address for the gateway and accepts a prefix length on the
		// routed prefix, which is the same split LuCI encodes as ip6addr("nomask") against
		// ip6addr.
		if (json.ip6gw != null && json.ip6gw != "" && !is_valid_ipv6(json.ip6gw))
			push(errs, { field: "ip6gw", code: "invalid_format",
			             message: "must be a valid IPv6 address without a prefix length" });
		if (json.ip6prefix != null && json.ip6prefix != ""
		    && !is_valid_ipv6_cidr(json.ip6prefix) && !is_valid_ipv6(json.ip6prefix))
			push(errs, { field: "ip6prefix", code: "invalid_format",
			             message: "must be a valid IPv6 address or prefix" });
	}

	if (json.proto == "wireguard") {
		if (json.private_key == null || json.private_key == "")
			push(errs, { field: "private_key", code: "required",
			             message: "is required when proto is wireguard" });
		else if (!match(json.private_key, WG_KEY_RE))
			push(errs, { field: "private_key", code: "invalid_format",
			             message: "must be a 44-char base64 WireGuard private key" });
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

	if (json.proto == "dhcpv6") {
		if (json.ip6hint != null && json.ip6hint != ""
		    && !match(json.ip6hint, IPV6_PREFIX_RE))
			push(errs, { field: "ip6hint", code: "invalid_format",
			             message: "must be an IPv6 prefix like 2001:db8::/56" });
		if (json.ip6ifaceid != null && json.ip6ifaceid != ""
		    && !match(json.ip6ifaceid, IPV6_IFACEID_RE))
			push(errs, { field: "ip6ifaceid", code: "invalid_format",
			             message: "must be an IPv6 host id like ::1 or eui64-form" });
	}

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
		proto: { type: "string", enum: keys(VALID_PROTOS), default: "none",
		         description: "Interface protocol. Several values need a handler package on the device: wwan needs `wwan`, wireguard needs `wireguard-tools`, dhcpv6 needs `odhcp6c`, and ppp/pppoe need `ppp`. When the handler is missing the write still succeeds and the interface is inert; `runtime.effective_proto` is what reveals it" },
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
		             description: "IPv4 broadcast address (static proto)" },
		ip6gw:     { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		             description: "IPv6 default gateway, a bare address with no prefix length (static proto)" },
		ip6prefix: { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		             description: "IPv6 prefix routed to this device for delegation to clients (static proto)" },
		gateway:   { type: ["string", "null"], "x-uapi-clear-on-omit": true,
		             description: "IPv4 default gateway (static proto)" },
		dns:       { type: ["array", "null"], items: { type: "string" } },
		ip6assign: { type: ["integer", "null"], minimum: 0, maximum: 128,
		             description: "Prefix length to assign downstream from a delegated prefix" },
		mtu:       { type: ["integer", "null"], minimum: 0, maximum: 65535 },
		auto:      { type: "boolean", default: true,
		             description: "Bring this interface up at boot" },
		disabled:  { type: "boolean", default: false,
		             description: "Whether netifd ignores this interface entirely. A disabled interface is not registered at all, so it has no ubus object and its addresses and routes are not installed." },
		addresses: { type: ["array", "null"], items: { type: "string" } },
		private_key: { type: "string", writeOnly: true,
		               description: "WireGuard private key; accepted on write, masked on read" },
		has_private_key: { type: "boolean", readOnly: true },
		listen_port:  { type: "integer", minimum: 0, maximum: 65535 },
		nohostroute:  { type: "boolean",
		                description: "Suppress the implicit host-route for wireguard endpoint" },
		ip4table:     { type: ["string", "null"],
		                description: "Routing table to install WireGuard IPv4 routes into" },
		ip6table:     { type: ["string", "null"],
		                description: "Routing table to install WireGuard IPv6 routes into" },
		peerdns:      { type: "boolean",
		                description: "Accept DNS servers advertised by the upstream (dhcp/dhcpv6)" },
		defaultroute: { type: "boolean",
		                description: "Install the default route from DHCP (dhcp)" },
		metric:       { type: "integer", minimum: 0,
		                description: "Default-route metric (dhcp)" },
		hostname:     { type: "string",
		                description: "Client hostname sent in DHCPDISCOVER (dhcp)" },
		clientid:     { type: "string",
		                description: "DHCP client identifier (dhcp)" },
		reqprefix:    { type: "string", pattern: "^(auto|no|[0-9]+)$",
		                description: "DHCPv6 prefix-delegation request: auto, no, or numeric size" },
		reqaddress:   { type: "string", enum: keys(VALID_REQADDRESS),
		                description: "DHCPv6 IA_NA request mode (dhcpv6)" },
		ip6hint:      { type: "string",
		                description: "Preferred IPv6 prefix hint for PD (dhcpv6)" },
		ip6ifaceid:   { type: "string",
		                description: "Static IPv6 interface id for IA_NA (dhcpv6)" },
		delegate:     { type: "boolean",
		                description: "Accept prefix delegation downstream (dhcpv6)" },
	},
};
