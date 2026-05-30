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

function fromUci(section) {
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
		runtime: {},
	};
	if (proto == "wireguard") {
		view.listen_port = section.listen_port ?? null;
		view.addresses = as_list(section.addresses);
		view.nohostroute = normalize_bool(section.nohostroute, false);
		view.ip4table = section.ip4table ?? null;
		view.ip6table = section.ip6table ?? null;
		view.has_private_key = (section.private_key != null && section.private_key != "");
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
	},
};
