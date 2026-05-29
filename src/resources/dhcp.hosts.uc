let values = require('values');
let normalize_bool = values.normalize_bool;
let is_valid_ip = values.is_valid_ip;

const MAC_RE = /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/;
const LEASETIME_RE = /^[0-9]+[smhdwMY]?$/;

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
	schema_properties: {
		mac: { type: "string", pattern: "^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$" },
		ip:  { type: "string", description: "IPv4 or IPv6 address" },
		leasetime: { type: ["string", "null"],
		             description: "Duration like '12h', '30m', '1d', or plain seconds" },
	},
};
