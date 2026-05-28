const MAC_RE = /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/;
const IPV4_RE = /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/;
const IPV6_RE = /^[0-9A-Fa-f:]+$/;
const LEASETIME_RE = /^[0-9]+[smhdwMY]?$/;

function normalize_bool(v, default_val) {
	if (v == null) return default_val;
	if (v === true || v === "1" || v === "on" || v === "true" || v === "yes")
		return true;
	if (v === false || v === "0" || v === "off" || v === "false" || v === "no")
		return false;
	return default_val;
}

function is_valid_ipv4(s) {
	if (!match(s, IPV4_RE)) return false;
	for (let part in split(s, ".")) {
		let n = int(part);
		if (n < 0 || n > 255) return false;
	}
	return true;
}

function is_valid_ip(s) {
	if (type(s) != "string" || s == "") return false;
	if (index(s, ":") != -1) return !!match(s, IPV6_RE);
	return is_valid_ipv4(s);
}

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		mac: section.mac ?? null,
		ip: section.ip ?? null,
		leasetime: section.leasetime ?? null,
		tag: section.tag ?? null,
		dns: normalize_bool(section.dns, false),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.name != null) out.name = json.name;
	if (json.mac != null)  out.mac = json.mac;
	if (json.ip != null)   out.ip = json.ip;
	if (json.leasetime != null) out.leasetime = json.leasetime;
	if (json.tag != null)  out.tag = json.tag;
	if (json.dns != null)  out.dns = json.dns ? "1" : "0";
	return out;
}

function validate(json) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}

	if (json.mac == null || json.mac == "")
		push(errs, { field: "mac", code: "required", message: "is required" });
	else if (!match(json.mac, MAC_RE))
		push(errs, { field: "mac", code: "invalid_format",
		             message: "must be a MAC address like 00:11:22:33:44:55" });

	if (json.ip == null || json.ip == "")
		push(errs, { field: "ip", code: "required", message: "is required" });
	else if (!is_valid_ip(json.ip))
		push(errs, { field: "ip", code: "invalid_format",
		             message: "must be a valid IPv4 or IPv6 address" });

	if (json.leasetime != null && !match(json.leasetime, LEASETIME_RE))
		push(errs, { field: "leasetime", code: "invalid_format",
		             message: "must look like 12h, 30m, 1d, or a plain number of seconds" });

	return errs;
}

return {
	package: "dhcp",
	type: "host",
	reload: ["dnsmasq"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
};
