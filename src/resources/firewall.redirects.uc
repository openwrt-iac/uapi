const VALID_TARGETS = { "DNAT": true, "SNAT": true };
const VALID_FAMILIES = { "any": true, "ipv4": true, "ipv6": true };
const VALID_PROTOS = {
	"tcp": true, "udp": true, "icmp": true, "icmpv6": true,
	"esp": true, "ah": true, "any": true, "all": true,
};
const IPV4_RE = /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/;
const PORT_RE = /^[0-9]+(-[0-9]+)?$/;

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
			src_dport: section.src_dport ?? null,
			dest_ip: section.dest_ip ?? null,
			dest_port: section.dest_port ?? null,
			proto: as_list(section.proto),
			family: section.family ?? "any",
		},
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
	if (m.src_dport != null) out.src_dport = m.src_dport;
	if (m.dest_ip != null) out.dest_ip = m.dest_ip;
	if (m.dest_port != null) out.dest_port = m.dest_port;
	if (type(m.proto) == "array" && length(m.proto) > 0) out.proto = m.proto;
	if (m.family != null && m.family != "any") out.family = m.family;
	return out;
}

function is_valid_ipv4(s) {
	if (type(s) != "string" || !match(s, IPV4_RE)) return false;
	for (let part in split(s, ".")) {
		let n = int(part);
		if (n < 0 || n > 255) return false;
	}
	return true;
}

function validate(json, conn) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type", message: "body must be a JSON object" });
		return errs;
	}

	if (json.target != null && !VALID_TARGETS[json.target])
		push(errs, { field: "target", code: "not_in_enum",
		             message: "must be one of DNAT, SNAT" });

	let m = json.match ?? {};
	if (type(m) != "object") {
		push(errs, { field: "match", code: "invalid_type", message: "must be an object" });
		return errs;
	}

	if (m.src_zone == null || m.src_zone == "")
		push(errs, { field: "match.src_zone", code: "required", message: "is required" });

	if (m.src_dport != null && !match(m.src_dport, PORT_RE))
		push(errs, { field: "match.src_dport", code: "invalid_format",
		             message: "must be a port or port range" });

	if (m.dest_port != null && !match(m.dest_port, PORT_RE))
		push(errs, { field: "match.dest_port", code: "invalid_format",
		             message: "must be a port or port range" });

	if (m.dest_ip != null && m.dest_ip != "" && !is_valid_ipv4(m.dest_ip))
		push(errs, { field: "match.dest_ip", code: "invalid_format",
		             message: "must be a valid IPv4 address" });

	if (m.family != null && !VALID_FAMILIES[m.family])
		push(errs, { field: "match.family", code: "not_in_enum",
		             message: "must be one of any, ipv4, ipv6" });

	let protos = as_list(m.proto);
	for (let i = 0; i < length(protos); i++) {
		if (!VALID_PROTOS[protos[i]])
			push(errs, { field: sprintf("match.proto[%d]", i), code: "not_in_enum",
			             message: sprintf("%J is not a recognized protocol", protos[i]) });
	}

	if (conn != null && m.src_zone != null && m.src_zone != "") {
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
	type: "redirect",
	reload: ["firewall"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
};
