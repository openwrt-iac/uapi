let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;

const VALID_TARGETS = { "SNAT": true, "MASQUERADE": true, "ACCEPT": true };
const VALID_FAMILIES = { "any": true, "ipv4": true, "ipv6": true };


function is_set(v) {
	return type(v) == "string" && v != "";
}

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		// fw4 defaults an unset target to masquerade, and coerces anything
		// outside snat/masquerade/accept to it with a warning.
		target: section.target ?? "MASQUERADE",
		enabled: normalize_bool(section.enabled, true),
		snat_ip: section.snat_ip ?? null,
		snat_port: section.snat_port ?? null,
		match: {
			src_zone: section.src ?? null,
			device: section.device ?? null,
			src_ip: section.src_ip ?? null,
			src_port: section.src_port ?? null,
			dest_ip: section.dest_ip ?? null,
			dest_port: section.dest_port ?? null,
			proto: as_list(section.proto),
			mark: section.mark ?? null,
			// Deliberately not defaulted to "any": fw4 treats an absent family
			// on a nat section as IPv4-only for backwards compatibility, so
			// synthesizing "any" here would misreport what the box does.
			family: section.family ?? null,
		},
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.name != null) out.name = json.name;
	if (json.target != null) out.target = json.target;
	if (json.enabled != null) out.enabled = json.enabled ? "1" : "0";
	if (is_set(json.snat_ip)) out.snat_ip = json.snat_ip;
	if (is_set(json.snat_port)) out.snat_port = json.snat_port;
	let m = json.match ?? {};
	if (is_set(m.src_zone)) out.src = m.src_zone;
	if (is_set(m.device)) out.device = m.device;
	if (is_set(m.src_ip)) out.src_ip = m.src_ip;
	if (is_set(m.src_port)) out.src_port = m.src_port;
	if (is_set(m.dest_ip)) out.dest_ip = m.dest_ip;
	if (is_set(m.dest_port)) out.dest_port = m.dest_port;
	if (type(m.proto) == "array" && length(m.proto) > 0) out.proto = m.proto;
	if (m.mark != null) out.mark = m.mark;
	if (m.family != null) out.family = m.family;
	return out;
}

function port_error(field, value, allow_invert, errs) {
	let p = values.port_problem(value, allow_invert);
	if (p != null)
		push(errs, { field, code: p.code, message: p.message });
}

function validate(json, conn) {
	let errs = [];

	let m = json.match ?? {};
	if (type(m) != "object") {
		push(errs, { field: "match", code: "invalid_type",
		             message: "must be an object" });
		return errs;
	}

	let snat_ip = is_set(json.snat_ip);
	let snat_port = is_set(json.snat_port);

	if (json.target == "SNAT") {
		if (!snat_ip && !snat_port)
			push(errs, { field: "snat_ip", code: "required",
			             message: "one of snat_ip or snat_port is required when target is SNAT" });
	} else {
		if (snat_ip)
			push(errs, { field: "snat_ip", code: "conflict",
			             message: "is only valid when target is SNAT; send null to clear it" });
		if (snat_port)
			push(errs, { field: "snat_port", code: "conflict",
			             message: "is only valid when target is SNAT; send null to clear it" });
	}

	// snat_ip is a network like the match addresses, but fw4 rewrites to it
	// rather than matching on it, so it carries NO_INVERT and rejects the
	// non-contiguous mask a match address is allowed.
	if (snat_ip && substr(json.snat_ip, 0, 1) == "!")
		push(errs, { field: "snat_ip", code: "invalid_format",
		             message: "must not be negated" });
	else if (snat_ip && values.has_noncontiguous_mask(json.snat_ip))
		push(errs, { field: "snat_ip", code: "invalid_format",
		             message: "must not use a non-contiguous mask" });

	if (type(m.device) == "string" && length(m.device) > values.DEVICE_MAX)
		push(errs, { field: "match.device", code: "out_of_range",
		             message: sprintf("must be at most %d characters, the nftables interface-name limit", values.DEVICE_MAX) });

	for (let f in [["snat_ip", json.snat_ip], ["match.src_ip", m.src_ip], ["match.dest_ip", m.dest_ip]]) {
		let a = values.address_problem(f[1]);
		if (a != null)
			push(errs, { field: f[0], code: a.code, message: a.message });
	}

	if (type(json.name) == "string" && length(json.name) > values.NAME_MAX)
		push(errs, { field: "name", code: "out_of_range",
		             message: sprintf("must be at most %d characters: firewall4 renders it into an nftables comment, which nft caps at 128", values.NAME_MAX) });

	let protos = as_list(m.proto);
	let proto_ok = true;
	for (let i = 0; i < length(protos); i++) {
		let pp = values.proto_problem(protos[i]);
		if (pp != null)
			push(errs, { field: sprintf("match.proto[%d]", i), code: pp.code, message: pp.message });
		if (pp != null || type(protos[i]) != "string")
			proto_ok = false;
	}

	port_error("snat_port", json.snat_port, false, errs);
	for (let key in ["src_port", "dest_port"])
		port_error("match." + key, m[key], true, errs);

	// ensure_tcpudp rewrites a lone wildcard to tcp+udp, so a wildcard keeps its
	// ports here. Anything else non-TCP/UDP loses them, whether fw4 discards the
	// section or emits it matching the whole protocol. Only worth saying once the
	// protocols themselves parse: an unresolvable token fails the entire ruleset
	// rather than widening one section.
	if (proto_ok
	    && (snat_port || is_set(m.src_port) || is_set(m.dest_port))
	    && values.port_proto_conflict(protos, true))
		push(errs, { field: "match.proto", code: "conflict",
		             message: "firewall4 keeps a port match only on tcp or udp, or on a wildcard it rewrites to both" });

	if (values.masked_value_exceeds(m.mark, values.MARK_MAX))
		push(errs, { field: "match.mark", code: "out_of_range",
		             message: sprintf("%J exceeds the maximum of %d", m.mark, values.MARK_MAX) });

	if (conn != null && is_set(m.src_zone) && m.src_zone != "*") {
		let zones = {};
		conn.uci_foreach('firewall', 'zone', function(s) { if (s.name) zones[s.name] = true; });
		if (!zones[m.src_zone])
			push(errs, { field: "match.src_zone", code: "conflict",
			             message: sprintf("zone %J does not exist", m.src_zone) });
	}

	return errs;
}

return {
	package: "firewall",
	type: "nat",
	reload: ["firewall"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "firewall NAT rule",
	openapi_conditional: [
		{ if:   { properties: { target: { const: "SNAT" } }, required: ["target"] },
		  then: { anyOf: [ { required: ["snat_ip"] }, { required: ["snat_port"] } ] } },
	],
	schema_properties: {
		name:      { type: ["string", "null"],
		             description: "Human-readable label for this NAT rule" },
		target:    { type: "string", enum: keys(VALID_TARGETS), default: "MASQUERADE",
		             description: "SNAT rewrites to snat_ip/snat_port, MASQUERADE rewrites to the outbound interface address, ACCEPT exempts matched traffic from source NAT" },
		enabled:   { type: "boolean", default: true },
		snat_ip:   { type: ["string", "null"],
		             description: "IPv4 address to rewrite the source to. Requires target SNAT" },
		snat_port: { type: ["string", "null"],
		             description: "Port or port range to rewrite the source port to. Requires target SNAT" },
		match: {
			type: "object",
			properties: {
				src_zone:  { type: ["string", "null"],
				             description: "Outbound (postrouting) zone this rule applies to. Unset matches all egress traffic" },
				device:    { type: ["string", "null"],
				             description: "Outbound interface name to match" },
				src_ip:    { type: ["string", "null"],
				             description: "Match source address. firewall4 resolves an address, a prefix in either family, or a uci network name, optionally negated with a leading '!'" },
				src_port:  { type: ["string", "null"], pattern: values.PORT_MATCH_RE,
				             description: "Match source port or range, optionally negated with a leading '!'" },
				dest_ip:   { type: ["string", "null"],
				             description: "Match destination address, in the same forms as src_ip" },
				dest_port: { type: ["string", "null"], pattern: values.PORT_MATCH_RE,
				             description: "Match destination port or range, optionally negated with a leading '!'" },
				proto:     { type: "array", items: { type: "string", pattern: values.PROTO_RE },
				             description: "Match protocols by name or number, e.g. tcp, udp, gre, sctp, 47, or the wildcards all / any. When a port is matched, every protocol must be tcp or udp, or all of them a wildcard that firewall4 rewrites to both. Defaults to all when unset" },
				mark:      { type: ["string", "null"], pattern: values.MARK_MATCH_RE,
				             description: "Match fwmark as value or value/mask, optionally negated with a leading '!'" },
				family:    { type: ["string", "null"], enum: [...keys(VALID_FAMILIES), null],
				             description: "Restrict to an address family. Unset means IPv4 only, which is firewall4's backwards-compatible default for NAT; set 'any' for dual-stack" },
			},
		},
	},
};
