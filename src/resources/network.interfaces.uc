let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;
let is_valid_ipv4 = values.is_valid_ipv4;
let is_valid_cidr = values.is_valid_cidr;

const VALID_PROTOS = {
	"static": true, "dhcp": true, "dhcpv6": true, "pppoe": true,
	"none": true, "ppp": true, "wwan": true, "wireguard": true,
};
const WG_KEY_RE = /^[A-Za-z0-9+/]{43}=$/;
const VALID_REQADDRESS = { "try": true, "force": true, "none": true };
const REQPREFIX_RE = /^(auto|no|[0-9]+)$/;
const IPV6_PREFIX_RE = /^[0-9A-Fa-f:]+\/[0-9]+$/;
const IPV6_IFACEID_RE = /^[0-9A-Fa-f:]+$/;

function fetch_runtime(conn, name) {
	if (conn == null || type(name) != "string" || name == "")
		return {};
	let status = null;
	try { status = conn.call("network.interface." + name, "status"); }
	catch (e) { return {}; }
	if (status == null) return {};
	return {
		up: !!status.up,
		pending: !!status.pending,
		available: !!status.available,
		l3_device: status.l3_device ?? null,
		uptime: status.uptime ?? null,
		"ipv4-address": status["ipv4-address"] ?? [],
		"ipv6-address": status["ipv6-address"] ?? [],
		"ipv6-prefix": status["ipv6-prefix"] ?? [],
		route: status.route ?? [],
	};
}

function fromUci(section, conn) {
	let anonymous = !!section['.anonymous'];
	let proto = section.proto ?? "none";
	let view = {
		id: section['.name'],
		managed: !anonymous,
		device: section.device ?? null,
		proto: proto,
		ipaddr: section.ipaddr ?? null,
		netmask: section.netmask ?? null,
		gateway: section.gateway ?? null,
		dns: as_list(section.dns),
		ip6assign: section.ip6assign ?? null,
		mtu: section.mtu ?? null,
		auto: normalize_bool(section.auto, true),
		runtime: fetch_runtime(conn, section['.name']),
	};
	if (proto == "wireguard") {
		view.listen_port = section.listen_port ?? null;
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
		view.metric = section.metric ?? null;
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
	if (json.ipaddr != null) out.ipaddr = json.ipaddr;
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

function validate(json) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type", message: "body must be a JSON object" });
		return errs;
	}

	if (json.proto == null || json.proto == "")
		push(errs, { field: "proto", code: "required", message: "is required" });
	else if (!VALID_PROTOS[json.proto])
		push(errs, { field: "proto", code: "not_in_enum",
		             message: "must be one of static, dhcp, dhcpv6, pppoe, none, ppp, wwan, wireguard" });

	if (json.proto == "static") {
		if (json.ipaddr == null || json.ipaddr == "")
			push(errs, { field: "ipaddr", code: "required",
			             message: "is required when proto is static" });
		else if (!is_valid_ipv4(json.ipaddr) && !is_valid_cidr(json.ipaddr))
			push(errs, { field: "ipaddr", code: "invalid_format",
			             message: "must be a valid IPv4 address or CIDR" });
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
		if (json.listen_port != null) {
			let p = int(json.listen_port);
			if (p < 0 || p > 65535)
				push(errs, { field: "listen_port", code: "out_of_range",
				             message: "must be 0-65535" });
		}
	}

	let dns = as_list(json.dns);
	for (let i = 0; i < length(dns); i++) {
		if (!is_valid_ipv4(dns[i]) && type(dns[i]) != "string")
			push(errs, { field: sprintf("dns[%d]", i), code: "invalid_format",
			             message: "must be an IP address" });
	}

	if (json.proto == "dhcp") {
		if (json.metric != null) {
			let m = int(json.metric);
			if (m < 0)
				push(errs, { field: "metric", code: "out_of_range",
				             message: "must be non-negative" });
		}
	}

	if (json.proto == "dhcpv6") {
		if (json.reqprefix != null && json.reqprefix != ""
		    && !match("" + json.reqprefix, REQPREFIX_RE))
			push(errs, { field: "reqprefix", code: "invalid_format",
			             message: "must be 'auto', 'no', or a numeric prefix size" });
		if (json.reqaddress != null && !VALID_REQADDRESS[json.reqaddress])
			push(errs, { field: "reqaddress", code: "not_in_enum",
			             message: "must be try, force, or none" });
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
		dns: { type: "array", items: { type: "string" } },
		addresses: { type: "array", items: { type: "string" } },
		private_key: { type: "string", writeOnly: true,
		               description: "WireGuard private key; accepted on write, masked on read" },
		has_private_key: { type: "boolean", readOnly: true },
		listen_port: { type: "integer", minimum: 0, maximum: 65535 },
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
