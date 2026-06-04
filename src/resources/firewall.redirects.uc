let values = require('values');
let hints = require('openapi_hints');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;
let is_valid_ipv4 = values.is_valid_ipv4;

const VALID_TARGETS = { "DNAT": true, "SNAT": true };
const VALID_FAMILIES = { "any": true, "ipv4": true, "ipv6": true };
const VALID_PROTOS = {
	"tcp": true, "udp": true, "icmp": true, "icmpv6": true,
	"esp": true, "ah": true, "any": true, "all": true,
};
const VALID_REFLECTION_SRC = { "internal": true, "external": true };
const PORT_RE = /^[0-9]+(-[0-9]+)?$/;

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		target: section.target ?? "DNAT",
		enabled: normalize_bool(section.enabled, true),
		match: {
			src_zone: section.src ?? null,
			dest_zone: section.dest ?? null,
			src_ip: as_list(section.src_ip),
			src_port: as_list(section.src_port),
			src_dport: as_list(section.src_dport),
			dest_ip: as_list(section.dest_ip),
			dest_port: as_list(section.dest_port),
			proto: as_list(section.proto),
			family: section.family ?? "any",
		},
		reflection: (section.reflection != null) ? normalize_bool(section.reflection, true) : null,
		reflection_src: section.reflection_src ?? null,
		reflection_zone: as_list(section.reflection_zone),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.name != null) out.name = json.name;
	if (json.target != null) out.target = json.target;
	if (json.enabled != null) out.enabled = json.enabled ? "1" : "0";
	let m = json.match ?? {};
	if (m.src_zone != null) out.src = m.src_zone;
	if (m.dest_zone != null) out.dest = m.dest_zone;
	if (type(m.src_ip) == "array" && length(m.src_ip) > 0) out.src_ip = m.src_ip;
	if (type(m.src_port) == "array" && length(m.src_port) > 0) out.src_port = m.src_port;
	if (type(m.src_dport) == "array" && length(m.src_dport) > 0) out.src_dport = m.src_dport;
	if (type(m.dest_ip) == "array" && length(m.dest_ip) > 0) out.dest_ip = m.dest_ip;
	if (type(m.dest_port) == "array" && length(m.dest_port) > 0) out.dest_port = m.dest_port;
	if (type(m.proto) == "array" && length(m.proto) > 0) out.proto = m.proto;
	if (m.family != null && m.family != "any") out.family = m.family;
	if (json.reflection != null)     out.reflection = json.reflection ? "1" : "0";
	if (json.reflection_src != null) out.reflection_src = json.reflection_src;
	if (type(json.reflection_zone) == "array" && length(json.reflection_zone) > 0)
		out.reflection_zone = json.reflection_zone;
	return out;
}

function validate(json, conn) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type", message: "body must be a JSON object" });
		return errs;
	}

	let m = json.match ?? {};
	if (type(m) != "object") {
		push(errs, { field: "match", code: "invalid_type", message: "must be an object" });
		return errs;
	}

	if (m.src_zone == null || m.src_zone == "")
		push(errs, { field: "match.src_zone", code: "required", message: "is required" });

	let src_dports = as_list(m.src_dport);
	for (let i = 0; i < length(src_dports); i++) {
		if (!match(src_dports[i], PORT_RE))
			push(errs, { field: sprintf("match.src_dport[%d]", i), code: "invalid_format",
			             message: "must be a port or port range" });
	}

	let dest_ports = as_list(m.dest_port);
	for (let i = 0; i < length(dest_ports); i++) {
		if (!match(dest_ports[i], PORT_RE))
			push(errs, { field: sprintf("match.dest_port[%d]", i), code: "invalid_format",
			             message: "must be a port or port range" });
	}

	let dest_ips = as_list(m.dest_ip);
	for (let i = 0; i < length(dest_ips); i++) {
		if (dest_ips[i] != "" && !is_valid_ipv4(dest_ips[i]))
			push(errs, { field: sprintf("match.dest_ip[%d]", i), code: "invalid_format",
			             message: "must be a valid IPv4 address" });
	}

	if (conn != null
	    && ((m.src_zone != null && m.src_zone != "")
	        || (m.dest_zone != null && m.dest_zone != ""))) {
		let zones = {};
		conn.uci_foreach('firewall', 'zone', function(s) { if (s.name) zones[s.name] = true; });
		if (m.src_zone != null && m.src_zone != "" && !zones[m.src_zone])
			push(errs, { field: "match.src_zone", code: "conflict",
			             message: sprintf("zone %J does not exist", m.src_zone) });
		if (m.dest_zone != null && m.dest_zone != "" && !zones[m.dest_zone])
			push(errs, { field: "match.dest_zone", code: "conflict",
			             message: sprintf("zone %J does not exist", m.dest_zone) });
	}

	return errs;
}

return {
	package: "firewall",
	type: "redirect",
	reload: ["firewall"],
	depends_on: ["firewall:zone"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "firewall redirect",
	openapi_required: ["match"],
	openapi_conditional: [hints.match_requires_src_zone],
	schema_properties: {
		target: { type: "string", enum: keys(VALID_TARGETS) },
		match: {
			type: "object",
			required: ["src_zone"],
			properties: {
				src_zone:  { type: ["string", "null"] },
				dest_zone: { type: ["string", "null"] },
				src_ip:    { type: "array", items: { type: "string" } },
				src_port:  { type: "array", items: { type: "string" } },
				src_dport: { type: "array", items: { type: "string" } },
				dest_ip:   { type: "array", items: { type: "string" } },
				dest_port: { type: "array", items: { type: "string" } },
				proto:     { type: "array", items: { type: "string", enum: keys(VALID_PROTOS) } },
				family:    { type: "string", enum: keys(VALID_FAMILIES) },
			},
		},
		reflection: { type: "boolean",
		              description: "Enable NAT loopback / hairpinning for this redirect (fw4 default true)" },
		reflection_src: { type: "string", enum: keys(VALID_REFLECTION_SRC),
		                  description: "Source address used for hairpinned packets: internal LAN or external WAN" },
		reflection_zone: { type: "array", items: { type: "string" },
		                   description: "Zones in which NAT reflection is allowed (uci list reflection_zone)" },
		name:    { type: ["string", "null"],
		           description: "Human-readable label for this redirect" },
		enabled: { type: "boolean" },
	},
};
