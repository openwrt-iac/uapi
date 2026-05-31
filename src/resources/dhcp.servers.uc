let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;

const LEASETIME_RE = /^[0-9]+[smhdwMY]?$/;
const VALID_RA = {
	"disabled": true, "server": true, "relay": true, "hybrid": true,
};

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		interface: section.interface ?? null,
		start: section.start ?? null,
		limit: section.limit ?? null,
		leasetime: section.leasetime ?? null,
		ignore: normalize_bool(section.ignore, false),
		force: normalize_bool(section.force, false),
		dynamicdhcp: normalize_bool(section.dynamicdhcp, true),
		ra: section.ra ?? null,
		dhcpv6: section.dhcpv6 ?? null,
		ra_default: section.ra_default ?? null,
		domain: section.domain ?? null,
		dhcp_option: as_list(section.dhcp_option),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.interface != null)    out.interface = json.interface;
	if (json.start != null)        out.start = "" + json.start;
	if (json.limit != null)        out.limit = "" + json.limit;
	if (json.leasetime != null)    out.leasetime = json.leasetime;
	if (json.ignore != null)       out.ignore = json.ignore ? "1" : "0";
	if (json.force != null)        out.force = json.force ? "1" : "0";
	if (json.dynamicdhcp != null)  out.dynamicdhcp = json.dynamicdhcp ? "1" : "0";
	if (json.ra != null)           out.ra = json.ra;
	if (json.dhcpv6 != null)       out.dhcpv6 = json.dhcpv6;
	if (json.ra_default != null)   out.ra_default = "" + json.ra_default;
	if (json.domain != null)       out.domain = json.domain;
	if (type(json.dhcp_option) == "array" && length(json.dhcp_option) > 0)
		out.dhcp_option = json.dhcp_option;
	return out;
}

function interface_exists(conn, name) {
	let found = false;
	conn.uci_foreach('network', 'interface', function(s) {
		if (s['.name'] == name) { found = true; return false; }
	});
	return found;
}

function validate(json, conn) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}

	if (json.interface == null || json.interface == "")
		push(errs, { field: "interface", code: "required", message: "is required" });

	if (json.start != null) {
		let s = int(json.start);
		if (s < 0 || s > 254)
			push(errs, { field: "start", code: "out_of_range",
			             message: "must be 0-254 (dnsmasq pool offset within /24)" });
	}
	if (json.limit != null) {
		let l = int(json.limit);
		if (l < 0 || l > 254)
			push(errs, { field: "limit", code: "out_of_range",
			             message: "must be 0-254 (dnsmasq pool size within /24)" });
	}
	if (json.leasetime != null && json.leasetime != "" && !match(json.leasetime, LEASETIME_RE))
		push(errs, { field: "leasetime", code: "invalid_format",
		             message: "must look like 12h, 30m, 1d, or plain seconds" });

	if (json.ra != null && !VALID_RA[json.ra])
		push(errs, { field: "ra", code: "not_in_enum",
		             message: "must be disabled, server, relay, or hybrid" });
	if (json.dhcpv6 != null && !VALID_RA[json.dhcpv6])
		push(errs, { field: "dhcpv6", code: "not_in_enum",
		             message: "must be disabled, server, relay, or hybrid" });

	if (conn != null && json.interface != null && json.interface != "") {
		if (!interface_exists(conn, json.interface))
			push(errs, { field: "interface", code: "conflict",
			             message: sprintf("interface %J does not exist", json.interface) });
	}

	return errs;
}

return {
	package: "dhcp",
	type: "dhcp",
	// reload via ucitrack on the dhcp package, which fans out to both dnsmasq
	// and odhcpd. Listing them here would double-reload.
	reload: ["dnsmasq"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		ra:     { type: "string", enum: keys(VALID_RA) },
		dhcpv6: { type: "string", enum: keys(VALID_RA) },
		dhcp_option: { type: "array", items: { type: "string" } },
	},
};
