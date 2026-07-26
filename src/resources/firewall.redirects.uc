let values = require('values');
let hints = require('openapi_hints');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;

const VALID_TARGETS = { "DNAT": true, "SNAT": true };
const VALID_FAMILIES = { "any": true, "ipv4": true, "ipv6": true };
const VALID_REFLECTION_SRC = { "internal": true, "external": true };


// fw4 marks only proto, src_mac and reflection_zone as list options on a
// `config redirect`; the rest are scalars, and its parse_opt refuses a list
// outright, discarding the whole section. These stay arrays on the wire
// (changing the type would break clients) but may carry at most one value.
const SCALAR_MATCH_KEYS = {
	src_ip: "src_ip", src_port: "src_port", src_dport: "src_dport",
	dest_ip: "dest_ip", dest_port: "dest_port",
};

function is_set(v) {
	return type(v) == "string" && v != "";
}

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
			mark: section.mark ?? null,
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
	if (is_set(m.src_zone)) out.src = m.src_zone;
	if (is_set(m.dest_zone)) out.dest = m.dest_zone;
	for (let key in SCALAR_MATCH_KEYS) {
		let v = as_list(m[key])[0];
		if (type(v) == "string" && v != "") out[key] = v;
	}
	if (type(m.proto) == "array" && length(m.proto) > 0) out.proto = m.proto;
	if (m.family != null && m.family != "any") out.family = m.family;
	if (m.mark != null) out.mark = m.mark;
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

	// A second value would be written as a uci list, which fw4 refuses on these
	// options, discarding the redirect entirely.
	for (let key in SCALAR_MATCH_KEYS) {
		if (length(as_list(m[key])) > 1)
			push(errs, { field: "match." + key, code: "conflict",
			             message: "firewall4 accepts only one value for this option on a redirect" });
	}

	if (type(json.name) == "string" && length(json.name) > values.NAME_MAX)
		push(errs, { field: "name", code: "out_of_range",
		             message: sprintf("must be at most %d characters: firewall4 renders it into an nftables comment, which nft caps at 128", values.NAME_MAX) });

	let protos = as_list(m.proto);
	for (let i = 0; i < length(protos); i++) {
		let pp = values.proto_problem(protos[i]);
		if (pp != null)
			push(errs, { field: sprintf("match.proto[%d]", i), code: pp.code, message: pp.message });
	}

	for (let key in ["src_ip", "dest_ip"]) {
		let addrs = as_list(m[key]);
		for (let i = 0; i < length(addrs); i++) {
			let a = values.address_problem(addrs[i]);
			if (a != null)
				push(errs, { field: sprintf("match.%s[%d]", key, i), code: a.code, message: a.message });
		}
	}

	for (let key in ["src_port", "src_dport", "dest_port"]) {
		let ports = as_list(m[key]);
		for (let i = 0; i < length(ports); i++) {
			let p = values.port_problem(ports[i], true);
			if (p != null)
				push(errs, { field: sprintf("match.%s[%d]", key, i), code: p.code, message: p.message });
		}
	}

	if (values.masked_value_exceeds(m.mark, values.MARK_MAX))
		push(errs, { field: "match.mark", code: "out_of_range",
		             message: sprintf("%J exceeds the maximum of %d", m.mark, values.MARK_MAX) });

	if (conn != null
	    && ((m.src_zone != null && m.src_zone != "")
	        || (m.dest_zone != null && m.dest_zone != ""))) {
		let zones = {};
		conn.uci_foreach('firewall', 'zone', function(s) { if (s.name) zones[s.name] = true; });
		if (m.src_zone != null && m.src_zone != "" && !zones[m.src_zone])
			push(errs, { field: "match.src_zone", code: "conflict",
			             message: sprintf("zone %J does not exist", m.src_zone) });
		if (m.dest_zone != null && m.dest_zone != "" && m.dest_zone != "*" && !zones[m.dest_zone])
			push(errs, { field: "match.dest_zone", code: "conflict",
			             message: sprintf("zone %J does not exist", m.dest_zone) });

		let rzones = as_list(json.reflection_zone);
		for (let i = 0; i < length(rzones); i++) {
			if (!zones[rzones[i]])
				push(errs, { field: sprintf("reflection_zone[%d]", i), code: "conflict",
				             message: sprintf("zone %J does not exist", rzones[i]) });
		}
	}

	return errs;
}

return {
	package: "firewall",
	type: "redirect",
	reload: ["firewall"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "firewall redirect",
	openapi_required: ["match"],
	openapi_conditional: [hints.match_requires_src_zone],
	schema_properties: {
		target: { type: "string", enum: keys(VALID_TARGETS), default: "DNAT" },
		match: {
			type: "object",
			required: ["src_zone"],
			properties: {
				src_zone:  { type: ["string", "null"] },
				dest_zone: { type: ["string", "null"] },
				src_ip:    { type: "array", maxItems: 1, items: { type: "string" },
				             description: "Match source address. firewall4 accepts one value per redirect, resolving an address, a prefix in either family, or a uci network name" },
				src_port:  { type: "array", maxItems: 1, items: { type: "string", pattern: values.PORT_MATCH_RE },
				             description: "Match source port or range, one value per redirect" },
				src_dport: { type: "array", maxItems: 1, items: { type: "string", pattern: values.PORT_MATCH_RE },
				             description: "Match the incoming destination port or range, one value per redirect" },
				dest_ip:   { type: "array", maxItems: 1, items: { type: "string" },
				             description: "Rewrite destination address, one value per redirect" },
				dest_port: { type: "array", maxItems: 1, items: { type: "string", pattern: values.PORT_MATCH_RE },
				             description: "Rewrite destination port or range, one value per redirect" },
				proto:     { type: "array", items: { type: "string", pattern: values.PROTO_RE },
				             description: "Match protocols by name or number, e.g. tcp, udp, gre, sctp, 47, or the wildcards all / any / tcpudp" },
				family:    { type: "string", enum: keys(VALID_FAMILIES), default: "any" },
				mark:      { type: ["string", "null"], pattern: values.MARK_MATCH_RE,
				             description: "Match fwmark as value or value/mask, optionally negated with a leading '!'" },
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
		enabled: { type: "boolean", default: true },
	},
};
