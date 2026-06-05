let values = require('values');
let ids = require('ids');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;
let is_valid_ipv4 = values.is_valid_ipv4;
let is_valid_cidr = values.is_valid_cidr;
let as_int = values.as_int;

// Linux IFNAMSIZ is 16 bytes including NUL, leaving 15 usable chars. For
// `proto=wireguard` netifd uses the uci section name verbatim as the kernel
// netdev name, so the section name must also be a legal ifname AND a legal
// uci section name (no hyphens). Hyphens are valid ifname chars but uci
// rejects them in section names, so we drop them from the accepted set.
const WG_IFNAME_RE = /^[A-Za-z][A-Za-z0-9_]{0,14}$/;

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
	let ipaddr_raw = section.ipaddr;
	let ipaddrs = (type(ipaddr_raw) == "array") ? ipaddr_raw
	              : (ipaddr_raw != null && ipaddr_raw != "") ? [ipaddr_raw] : [];
	let ipaddr_first = length(ipaddrs) > 0 ? ipaddrs[0] : null;
	let view = {
		id: section['.name'],
		managed: !anonymous,
		device: section.device ?? null,
		proto: proto,
		ipaddr: ipaddr_first,
		ipaddrs: ipaddrs,
		netmask: section.netmask ?? null,
		gateway: section.gateway ?? null,
		dns: as_list(section.dns),
		ip6assign: as_int(section.ip6assign),
		mtu: as_int(section.mtu),
		auto: normalize_bool(section.auto, true),
		runtime: fetch_runtime(conn, section['.name']),
	};
	if (proto == "wireguard") {
		view.listen_port = as_int(section.listen_port);
		view.addresses = as_list(section.addresses);
		view.nohostroute = normalize_bool(section.nohostroute, false);
		view.ip4table = section.ip4table ?? null;
		view.ip6table = section.ip6table ?? null;
		view.has_private_key = (section.private_key != null && section.private_key != "");
	}
	// For the v1.2 dhcp / dhcpv6 fields, surface null when uci has nothing
	// explicitly set. Surfacing the daemon's effective default would cause
	// merge_for_patch to write those defaults into uci on the next PATCH,
	// silently changing the section's surface area for the client.
	if (proto == "dhcp") {
		view.peerdns = (section.peerdns != null) ? normalize_bool(section.peerdns, true) : null;
		view.defaultroute = (section.defaultroute != null) ? normalize_bool(section.defaultroute, true) : null;
		view.metric = as_int(section.metric);
		view.hostname = section.hostname ?? null;
		view.clientid = section.clientid ?? null;
	}
	if (proto == "dhcpv6") {
		view.peerdns = (section.peerdns != null) ? normalize_bool(section.peerdns, true) : null;
		view.reqprefix = section.reqprefix ?? null;
		view.reqaddress = section.reqaddress ?? null;
		view.ip6hint = section.ip6hint ?? null;
		view.ip6ifaceid = section.ip6ifaceid ?? null;
		view.delegate = (section.delegate != null) ? normalize_bool(section.delegate, true) : null;
	}
	return view;
}

function toUci(json) {
	let out = {};
	if (json.device != null) out.device = json.device;
	if (json.proto != null) out.proto = json.proto;
	// Prefer ipaddrs (list form) when present; fall back to ipaddr (string).
	// uci handles both `option ipaddr` and `list ipaddr` semantically; the
	// list form is required for multi-address static interfaces.
	if (type(json.ipaddrs) == "array" && length(json.ipaddrs) > 0)
		out.ipaddr = json.ipaddrs;
	else if (json.ipaddr != null)
		out.ipaddr = json.ipaddr;
	if (json.netmask != null) out.netmask = json.netmask;
	if (json.gateway != null) out.gateway = json.gateway;
	if (type(json.dns) == "array" && length(json.dns) > 0) out.dns = json.dns;
	if (json.ip6assign != null) out.ip6assign = "" + json.ip6assign;
	if (json.mtu != null) out.mtu = "" + json.mtu;
	if (json.auto != null) out.auto = json.auto ? "1" : "0";
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

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type", message: "body must be a JSON object" });
		return errs;
	}

	if (json.proto == null || json.proto == "")
		push(errs, { field: "proto", code: "required", message: "is required" });

	if (json.name != null) {
		if (id != null)
			push(errs, { field: "name", code: "read_only",
			             message: "name can only be set at create time; rename via DELETE + POST" });
		else if (json.proto != "wireguard")
			push(errs, { field: "name", code: "invalid_format",
			             message: "is only valid when proto is wireguard (the section name doubles as the kernel netdev name)" });
		else if (type(json.name) != "string" || !match(json.name, WG_IFNAME_RE))
			push(errs, { field: "name", code: "invalid_format",
			             message: "must match [A-Za-z][A-Za-z0-9_]{0,14} (Linux IFNAMSIZ + uci section-name rules)" });
		else if (conn != null) {
			let existing = null;
			try { existing = conn.uci_get("network", json.name); } catch (_) {}
			if (existing != null)
				push(errs, { field: "name", code: "conflict",
				             message: sprintf("section 'network.%s' already exists", json.name) });
		}
	}

	if (json.proto == "static") {
		let has_list = type(json.ipaddrs) == "array" && length(json.ipaddrs) > 0;
		let has_single = json.ipaddr != null && json.ipaddr != "";
		if (!has_list && !has_single)
			push(errs, { field: "ipaddr", code: "required",
			             message: "is required when proto is static (use 'ipaddr' for a single address or 'ipaddrs' for a list)" });
		if (has_single && !is_valid_ipv4(json.ipaddr) && !is_valid_cidr(json.ipaddr))
			push(errs, { field: "ipaddr", code: "invalid_format",
			             message: "must be a valid IPv4 address or CIDR" });
		if (has_list) {
			for (let i = 0; i < length(json.ipaddrs); i++) {
				if (!is_valid_ipv4(json.ipaddrs[i]) && !is_valid_cidr(json.ipaddrs[i]))
					push(errs, { field: sprintf("ipaddrs[%d]", i), code: "invalid_format",
					             message: "must be a valid IPv4 address or CIDR" });
			}
		}
		if (json.netmask != null && json.netmask != "" && !is_valid_ipv4(json.netmask))
			push(errs, { field: "netmask", code: "invalid_format",
			             message: "must be a valid IPv4 netmask" });
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
			if (!is_valid_cidr(addrs[i]))
				push(errs, { field: sprintf("addresses[%d]", i), code: "invalid_format",
				             message: "must be a valid IPv4 CIDR" });
		}
	}

	let dns = as_list(json.dns);
	for (let i = 0; i < length(dns); i++) {
		if (!is_valid_ipv4(dns[i]) && type(dns[i]) != "string")
			push(errs, { field: sprintf("dns[%d]", i), code: "invalid_format",
			             message: "must be an IP address" });
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
	package: "network",
	type: "interface",
	reload: ["network"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	// Wireguard sections need their uci name to also be a legal Linux ifname
	// (netifd uses the section name as the kernel netdev), so the standard
	// 28-char ULID breaks the tunnel silently. Caller may supply `name` to
	// pick it; otherwise emit a 14-char `wg_<11-char-rand>` that fits IFNAMSIZ.
	// Other protos keep the default 28-char ULID from handler.create.
	id_for_create: function(body) {
		if (body == null || body.proto != "wireguard") return null;
		if (body.name != null) return body.name;
		return ids.new_id("wg", 11);
	},
	openapi_singular: "network interface",
	openapi_required: ["proto"],
	openapi_conditional: [
		{ if:   { properties: { proto: { const: "static" } }, required: ["proto"] },
		  then: { anyOf: [
		            { required: ["ipaddr"] },
		            { required: ["ipaddrs"] },
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
			l3_device:        { type: ["string", "null"] },
			uptime:           { type: ["integer", "null"], minimum: 0 },
			ipv4_address:     { type: "array", items: { type: "object" } },
			ipv6_address:     { type: "array", items: { type: "object" } },
			ipv6_prefix:      { type: "array", items: { type: "object" } },
			route:            { type: "array", items: { type: "object" } },
		},
	},
	merge_for_patch: function(existing_section, existing_json, body) {
		let merged = { ...existing_json };
		for (let k in body) {
			if (type(merged[k]) == "object" && type(body[k]) == "object")
				merged[k] = { ...merged[k], ...body[k] };
			else
				merged[k] = body[k];
		}
		// For wireguard interfaces, carry forward the masked private_key
		// when PATCH omits it (same pattern as wireless.interfaces' key).
		let proto = merged.proto ?? existing_section.proto ?? null;
		if (proto == "wireguard" && body.private_key == null && existing_section.private_key != null)
			merged.private_key = existing_section.private_key;
		return merged;
	},
	schema_properties: {
		proto: { type: "string", enum: keys(VALID_PROTOS) },
		name:      { type: "string", pattern: "^[A-Za-z][A-Za-z0-9_]{0,14}$",
		             maxLength: 15,
		             description: "Create-time only; only valid when proto is wireguard. Sets the uci section name, which netifd uses verbatim as the kernel netdev name (capped at 15 chars by Linux IFNAMSIZ). When omitted, the server generates a short `wg_<rand>` id." },
		device:    { type: ["string", "null"],
		             description: "Physical or logical L2 device this interface binds to" },
		ipaddr:    { type: ["string", "null"],
		             description: "Static IPv4 address (single). Backward-compatible view of the first entry when uci has `list ipaddr`." },
		ipaddrs:   { type: "array", items: { type: "string" },
		             description: "Full IPv4 address list for static proto (uci `list ipaddr`). Preferred on write for multi-address interfaces." },
		netmask:   { type: ["string", "null"],
		             description: "IPv4 netmask (static proto)" },
		gateway:   { type: ["string", "null"],
		             description: "IPv4 default gateway (static proto)" },
		dns:       { type: "array", items: { type: "string" } },
		ip6assign: { type: ["integer", "null"], minimum: 0, maximum: 128,
		             description: "Prefix length to assign downstream from a delegated prefix" },
		mtu:       { type: ["integer", "null"], minimum: 0, maximum: 65535 },
		auto:      { type: "boolean",
		             description: "Bring this interface up at boot" },
		addresses: { type: "array", items: { type: "string" } },
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
