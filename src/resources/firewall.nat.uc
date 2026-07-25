let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;

const VALID_TARGETS = { "SNAT": true, "MASQUERADE": true, "ACCEPT": true };
const VALID_FAMILIES = { "any": true, "ipv4": true, "ipv6": true };

// fw4 resolves a protocol by name against /etc/protocols, by number, or as one
// of the wildcards, so a closed enum would reject working config such as gre,
// sctp, or a bare 47. Shape only; fw4 owns the lookup.
const PROTO_STR = '^!?[A-Za-z0-9][A-Za-z0-9-]{0,31}$';

// Wildcards fw4 narrows to tcp+udp when a port is present, via ensure_tcpudp.
const TCPUDP = { "tcp": true, "udp": true, "tcpudp": true, "any": true, "all": true, "*": true };
// fw4 parses a port as a single number or a min-max / min:max range, each
// component within 0..65535 and the range ordered. Match options may be
// negated; snat_port carries NO_INVERT and may not.
const PORT_STR = '^[0-9]{1,5}([-:][0-9]{1,5})?$';
const PORT_MATCH_STR = '^!?[0-9]{1,5}([-:][0-9]{1,5})?$';
const PORT_RE = regexp(PORT_STR);
const PORT_MATCH_RE = regexp(PORT_MATCH_STR);
const PORT_MAX = 65535;

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
	if (json.snat_ip != null) out.snat_ip = json.snat_ip;
	if (json.snat_port != null) out.snat_port = json.snat_port;
	let m = json.match ?? {};
	if (m.src_zone != null) out.src = m.src_zone;
	if (m.device != null) out.device = m.device;
	if (m.src_ip != null) out.src_ip = m.src_ip;
	if (m.src_port != null) out.src_port = m.src_port;
	if (m.dest_ip != null) out.dest_ip = m.dest_ip;
	if (m.dest_port != null) out.dest_port = m.dest_port;
	if (type(m.proto) == "array" && length(m.proto) > 0) out.proto = m.proto;
	if (m.mark != null) out.mark = m.mark;
	if (m.family != null) out.family = m.family;
	return out;
}

function is_set(v) {
	return type(v) == "string" && v != "";
}

function port_error(field, value, allow_invert, errs) {
	if (type(value) != "string" || value == "") return;

	if (!match(value, allow_invert ? PORT_MATCH_RE : PORT_RE)) {
		push(errs, { field, code: "invalid_format",
		             message: allow_invert
		                 ? "must be a port or port range (e.g. 80, 1000-2000, 1000:2000), optionally negated with a leading '!'"
		                 : "must be a port or port range (e.g. 80, 1000-2000, 1000:2000)" });
		return;
	}

	// The pattern bounds the digit count, not the value: fw4 rejects a section
	// whose port exceeds 65535 or whose range runs backwards, which would
	// otherwise reach the router and be silently dropped.
	let bounds = [];
	for (let part in split(replace(value, /^!/, ""), /[-:]/)) push(bounds, +part);
	for (let n in bounds) {
		if (n > PORT_MAX) {
			push(errs, { field, code: "out_of_range",
			             message: sprintf("port %d exceeds the maximum of %d", n, PORT_MAX) });
			return;
		}
	}
	if (length(bounds) == 2 && bounds[0] > bounds[1])
		push(errs, { field, code: "out_of_range",
		             message: "port range start must not exceed its end" });
}

function check_ports(m, errs) {
	for (let key in ["src_port", "dest_port"])
		port_error("match." + key, m[key], true, errs);
}

function validate(json, conn) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}

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

	// fw4 types snat_ip as a network, which resolves an address, a prefix in
	// either family, or a uci network name, so there is no syntax we can check
	// here without reimplementing its resolver. Negation is the one form it
	// explicitly refuses (NO_INVERT).
	if (snat_ip && substr(json.snat_ip, 0, 1) == "!")
		push(errs, { field: "snat_ip", code: "invalid_format",
		             message: "must not be negated" });

	port_error("snat_port", json.snat_port, false, errs);
	check_ports(m, errs);

	// fw4 rewrites a wildcard proto to tcp+udp when ports are present, so only
	// an explicitly non-TCP/UDP proto is a real conflict.
	let protos = as_list(m.proto);
	if (length(protos) > 0 && (snat_port || is_set(m.src_port) || is_set(m.dest_port))) {
		// ensure_tcpudp keeps the section only when EVERY protocol is TCP/UDP or
		// a wildcard it can narrow; one stray icmp entry makes fw4 drop it.
		let tcpudp = true;
		for (let p in protos) if (!TCPUDP[p]) tcpudp = false;
		if (!tcpudp)
			push(errs, { field: "match.proto", code: "conflict",
			             message: "ports require a TCP or UDP protocol" });
	}

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
				src_port:  { type: ["string", "null"], pattern: PORT_MATCH_STR,
				             description: "Match source port or range, optionally negated with a leading '!'" },
				dest_ip:   { type: ["string", "null"],
				             description: "Match destination address, in the same forms as src_ip" },
				dest_port: { type: ["string", "null"], pattern: PORT_MATCH_STR,
				             description: "Match destination port or range, optionally negated with a leading '!'" },
				proto:     { type: "array", items: { type: "string", pattern: PROTO_STR },
				             description: "Match protocols by name or number, e.g. tcp, udp, gre, sctp, 47, or the wildcards all / any. Defaults to all when unset" },
				mark:      { type: ["string", "null"], pattern: values.MARK_MATCH_RE,
				             description: "Match fwmark as value or value/mask, optionally negated with a leading '!'" },
				family:    { type: ["string", "null"], enum: [...keys(VALID_FAMILIES), null],
				             description: "Restrict to an address family. Unset means IPv4 only, which is firewall4's backwards-compatible default for NAT; set 'any' for dual-stack" },
			},
		},
	},
};
