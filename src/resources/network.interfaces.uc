const VALID_PROTOS = {
	"static": true, "dhcp": true, "dhcpv6": true, "pppoe": true,
	"none": true, "ppp": true, "wwan": true,
};
const IPV4_RE = /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/;
const CIDR_RE = /^[0-9]{1,3}(\.[0-9]{1,3}){3}\/[0-9]{1,2}$/;
const NETMASK_RE = /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/;

function normalize_bool(v, default_val) {
	if (v == null) return default_val;
	if (v === true || v === "1" || v === "on" || v === "true" || v === "yes")
		return true;
	if (v === false || v === "0" || v === "off" || v === "false" || v === "no")
		return false;
	return default_val;
}

function as_list(v) {
	if (v == null) return [];
	if (type(v) == "array") return v;
	return [v];
}

function is_valid_ipv4(s) {
	if (type(s) != "string" || !match(s, IPV4_RE)) return false;
	for (let part in split(s, ".")) {
		let n = int(part);
		if (n < 0 || n > 255) return false;
	}
	return true;
}

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		device: section.device ?? null,
		proto: section.proto ?? "none",
		ipaddr: section.ipaddr ?? null,
		netmask: section.netmask ?? null,
		gateway: section.gateway ?? null,
		dns: as_list(section.dns),
		ip6assign: section.ip6assign ?? null,
		mtu: section.mtu ?? null,
		auto: normalize_bool(section.auto, true),
		runtime: {},
	};
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
		             message: "must be one of static, dhcp, dhcpv6, pppoe, none, ppp, wwan" });

	if (json.proto == "static") {
		if (json.ipaddr == null || json.ipaddr == "")
			push(errs, { field: "ipaddr", code: "required",
			             message: "is required when proto is static" });
		else if (!is_valid_ipv4(json.ipaddr) && !match(json.ipaddr, CIDR_RE))
			push(errs, { field: "ipaddr", code: "invalid_format",
			             message: "must be a valid IPv4 address or CIDR" });
		if (json.netmask != null && json.netmask != "" && !match(json.netmask, NETMASK_RE))
			push(errs, { field: "netmask", code: "invalid_format",
			             message: "must be a valid netmask" });
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
	schema_properties: {
		proto: { type: "string", enum: keys(VALID_PROTOS) },
		dns: { type: "array", items: { type: "string" } },
	},
};
