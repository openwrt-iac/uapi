let values = require('values');
let shell_bool = values.shell_bool;
let as_list_or_null = values.as_list_or_null;
let is_valid_ip = values.is_valid_ip;

const MAC_RE = /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/;
const LEASETIME_RE = /^[0-9]+[smhdwMY]?$/;
const DUID_RE = /^[0-9A-Fa-f]{2}([:]?[0-9A-Fa-f]{2})+$/;
const IPV6_HOSTID_RE = /^[0-9A-Fa-f:]+$/;

// A stored scalar is one or more whitespace-separated tags, which is what dnsmasq makes
// of it. Splitting on read is what settles the wire shape; a read never touches storage.
// A write does converge it, since toUci hands uci the array and uci stores a list, so the
// first write-back turns `option tag 'a b'` into `list tag`. That is safe here only
// because the view is stable across it: dnsmasq treats the two identically, and a body
// read and written back unchanged reads back unchanged, which is what read honesty asks.
// The earlier design refused to normalize on write for that reason and then kept the raw
// shape on read too, which is the part that did not follow.
function split_tags(v) {
	if (v == null) return null;
	if (type(v) == "array") return v;
	let out = [];
	for (let t in split(trim("" + v), /[ \t]+/)) if (t != "") push(out, t);
	return length(out) > 0 ? out : null;
}

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		macs: as_list_or_null(section.mac),
		duid: section.duid ?? null,
		hostid: section.hostid ?? null,
		ip: section.ip ?? null,
		leasetime: section.leasetime ?? null,
		// dnsmasq word-splits whatever it reads, so `option tag 'a b'` and `list tag`
		// are the same configuration to it and uci holds either. Reading the raw shape
		// meant the same reservation answered with a string on one box and an array on
		// another, and a generated client had to handle both to learn one thing. The
		// read is the array now; a stored scalar is split on the way out.
		tag: split_tags(section.tag),
		dns: shell_bool(section.dns, false),
		broadcast: (section.broadcast != null) ? shell_bool(section.broadcast, false) : null,
		instance: section.instance ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.name != null) out.name = json.name;

	// uci cannot hold a one-element list distinctly from a scalar, so a single mac is
	// written as a scalar and read back through as_list as a one-element array.
	if (type(json.macs) == "array" && length(json.macs) > 0)
		out.mac = (length(json.macs) > 1) ? json.macs : json.macs[0];

	if (json.duid != null)      out.duid = json.duid;
	if (json.hostid != null)    out.hostid = json.hostid;
	if (json.ip != null)        out.ip = json.ip;
	if (json.leasetime != null) out.leasetime = json.leasetime;
	if (type(json.tag) == "array" && length(json.tag) > 0) out.tag = json.tag;
	else if (json.tag != null && type(json.tag) != "array") out.tag = json.tag;
	if (json.dns != null)       out.dns = json.dns ? "1" : "0";
	if (json.broadcast != null) out.broadcast = json.broadcast ? "1" : "0";
	if (json.instance != null)  out.instance = json.instance;
	return out;
}

// `dhcp.host.instance` references a dnsmasq instance (the dhcp.dnsmasq section
// name), not a per-interface dhcp.dhcp section. dnsmasq's init reads
// config_get_bool ... "$instance" against `config dnsmasq` entries.
function dnsmasq_instance_exists(conn, name) {
	return values.section_index(conn, 'dhcp', 'dnsmasq', '.name')[name] != null;
}

function validate(json, conn) {
	let errs = [];

	let macs = (type(json.macs) == "array") ? json.macs : [];
	let has_macs = length(macs) > 0;
	let has_duid = json.duid != null && json.duid != "";

	if (!has_macs && !has_duid)
		push(errs, { field: "macs", code: "required",
		             message: "either macs (for DHCPv4) or duid (for DHCPv6) is required" });

	for (let i = 0; i < length(macs); i++) {
		if (!match(macs[i], MAC_RE))
			push(errs, { field: sprintf("macs[%d]", i), code: "invalid_format",
			             message: "must be a MAC address like 00:11:22:33:44:55" });
	}

	if (has_duid && !match(json.duid, DUID_RE))
		push(errs, { field: "duid", code: "invalid_format",
		             message: "must be a hex string (optionally colon-separated)" });

	if (json.hostid != null && json.hostid != ""
	    && !match(json.hostid, IPV6_HOSTID_RE))
		push(errs, { field: "hostid", code: "invalid_format",
		             message: "must be an IPv6 host id like ::42" });

	if (json.ip != null && json.ip != "" && !is_valid_ip(json.ip))
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
	openapi_singular: "DHCP host",
	openapi_conditional: [
		{ anyOf: [
		    { required: ["macs"] },
		    { required: ["duid"] },
		  ] },
	],
	schema_properties: {
		macs:        { type: ["array", "null"], items: { type: "string" },
		               description: "MAC addresses for this reservation, the whole uci `list mac`." },
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
		name:          { type: ["string", "null"],
		               description: "Hostname dnsmasq answers for this reservation" },
		// Responses are always an array; the string stays in the type only because a
		// request may still send one, and one schema serves both directions here. The
		// 2.4.1 spec declared `string`, so clients generated against it send one, and
		// rejecting that would break every existing writer for no gain: dnsmasq
		// word-splits a scalar identically. v3 removes the write form.
		tag:           { type: ["string", "array", "null"], items: { type: "string" },
		               description: "dnsmasq tags for this reservation; a request must match all of them. **Responses are always an array**, including for a section storing a space-separated scalar, which dnsmasq treats the same way. A space-separated string is still accepted on write; v3 removes that and the field becomes array-only. See docs/deprecations.md" },
		// Untyped until 2.5.0, so `dns: "0"` was a truthy string that wrote dns=1,
		// the inverse of the request. dnsmasq reads this with the shell config_get_bool,
		// which accepts the wide spelling set, so normalize_bool stays the reader.
		dns:           { type: "boolean", default: false,
		               description: "Answer DNS queries for this reservation's hostname" },
	},
};
