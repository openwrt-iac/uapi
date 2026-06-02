let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;
let is_valid_ip = values.is_valid_ip;

const MAC_RE = /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/;
const LEASETIME_RE = /^[0-9]+[smhdwMY]?$/;
const DUID_RE = /^[0-9A-Fa-f]{2}([:]?[0-9A-Fa-f]{2})+$/;
const IPV6_HOSTID_RE = /^[0-9A-Fa-f:]+$/;

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	let macs = as_list(section.mac);
	let primary_mac = length(macs) > 0 ? macs[0] : null;
	let extra_macs = length(macs) > 1 ? slice(macs, 1) : [];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		mac: primary_mac,
		mac_aliases: extra_macs,
		duid: section.duid ?? null,
		hostid: section.hostid ?? null,
		ip: section.ip ?? null,
		leasetime: section.leasetime ?? null,
		tag: section.tag ?? null,
		dns: normalize_bool(section.dns, false),
		broadcast: (section.broadcast != null) ? normalize_bool(section.broadcast, false) : null,
		instance: section.instance ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.name != null) out.name = json.name;

	let aliases = (type(json.mac_aliases) == "array") ? json.mac_aliases : [];
	if (json.mac != null && length(aliases) > 0) {
		let all = [json.mac];
		for (let a in aliases) push(all, a);
		out.mac = all;
	} else if (json.mac != null) {
		out.mac = json.mac;
	}

	if (json.duid != null)      out.duid = json.duid;
	if (json.hostid != null)    out.hostid = json.hostid;
	if (json.ip != null)        out.ip = json.ip;
	if (json.leasetime != null) out.leasetime = json.leasetime;
	if (json.tag != null)       out.tag = json.tag;
	if (json.dns != null)       out.dns = json.dns ? "1" : "0";
	if (json.broadcast != null) out.broadcast = json.broadcast ? "1" : "0";
	if (json.instance != null)  out.instance = json.instance;
	return out;
}

// `dhcp.host.instance` references a dnsmasq instance (the dhcp.dnsmasq section
// name), not a per-interface dhcp.dhcp section. dnsmasq's init reads
// config_get_bool ... "$instance" against `config dnsmasq` entries.
function dnsmasq_instance_exists(conn, name) {
	let found = false;
	conn.uci_foreach('dhcp', 'dnsmasq', function(s) {
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

	let has_mac = json.mac != null && json.mac != "";
	let has_duid = json.duid != null && json.duid != "";
	if (!has_mac && !has_duid)
		push(errs, { field: "mac", code: "required",
		             message: "either mac (for DHCPv4) or duid (for DHCPv6) is required" });

	if (has_mac && !match(json.mac, MAC_RE))
		push(errs, { field: "mac", code: "invalid_format",
		             message: "must be a MAC address like 00:11:22:33:44:55" });

	if (type(json.mac_aliases) == "array") {
		for (let i = 0; i < length(json.mac_aliases); i++) {
			if (!match(json.mac_aliases[i], MAC_RE))
				push(errs, { field: sprintf("mac_aliases[%d]", i),
				             code: "invalid_format",
				             message: "must be a MAC address like 00:11:22:33:44:55" });
		}
	}

	if (has_duid && !match(json.duid, DUID_RE))
		push(errs, { field: "duid", code: "invalid_format",
		             message: "must be a hex string (optionally colon-separated)" });

	if (json.hostid != null && json.hostid != ""
	    && !match(json.hostid, IPV6_HOSTID_RE))
		push(errs, { field: "hostid", code: "invalid_format",
		             message: "must be an IPv6 host id like ::42" });

	if (json.ip == null || json.ip == "")
		push(errs, { field: "ip", code: "required", message: "is required" });
	else if (!is_valid_ip(json.ip))
		push(errs, { field: "ip", code: "invalid_format",
		             message: "must be a valid IPv4 or IPv6 address" });

	if (json.leasetime != null && !match(json.leasetime, LEASETIME_RE))
		push(errs, { field: "leasetime", code: "invalid_format",
		             message: "must look like 12h, 30m, 1d, or a plain number of seconds" });

	if (conn != null && json.instance != null && json.instance != "") {
		if (!dnsmasq_instance_exists(conn, json.instance))
			push(errs, { field: "instance", code: "conflict",
			             message: sprintf("no dhcp/dnsmasq section named %J exists",
			                              json.instance) });
	}

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
		mac:         { type: ["string", "null"], pattern: "^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$",
		               description: "Primary MAC address for IPv4 reservation" },
		mac_aliases: { type: "array", items: { type: "string" },
		               description: "Additional MACs for the same reservation (uci list mac)" },
		duid:        { type: ["string", "null"],
		               description: "Client DUID for DHCPv6 reservation" },
		hostid:      { type: ["string", "null"],
		               description: "Static IPv6 host id hint (suffix)" },
		ip:          { type: "string", description: "IPv4 or IPv6 address" },
		leasetime:   { type: ["string", "null"],
		               description: "Duration like '12h', '30m', '1d', or plain seconds" },
		broadcast:   { type: "boolean",
		               description: "Force broadcast replies for clients that need it" },
		instance:    { type: ["string", "null"],
		               description: "Pin this reservation to a specific dhcp/dnsmasq instance (section name)" },
	},
};
