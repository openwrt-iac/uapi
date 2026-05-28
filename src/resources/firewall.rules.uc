const VALID_TARGETS = {
	"ACCEPT": true, "REJECT": true, "DROP": true,
	"NOTRACK": true, "MARK": true,
};
const VALID_FAMILIES = { "any": true, "ipv4": true, "ipv6": true };
const VALID_PROTOS = {
	"tcp": true, "udp": true, "icmp": true, "icmpv6": true,
	"esp": true, "ah": true, "any": true, "all": true,
};

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
		target: section.target ?? null,
		enabled: normalize_bool(section.enabled, true),
		match: {
			src_zone: section.src ?? null,
			dest_zone: section.dest ?? null,
			src_ip: as_list(section.src_ip),
			dest_ip: as_list(section.dest_ip),
			src_port: as_list(section.src_port),
			dest_port: as_list(section.dest_port),
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
	if (type(m.dest_ip) == "array" && length(m.dest_ip) > 0) out.dest_ip = m.dest_ip;
	if (type(m.src_port) == "array" && length(m.src_port) > 0) out.src_port = m.src_port;
	if (type(m.dest_port) == "array" && length(m.dest_port) > 0) out.dest_port = m.dest_port;
	if (type(m.proto) == "array" && length(m.proto) > 0) out.proto = m.proto;
	if (m.family != null && m.family != "any") out.family = m.family;
	return out;
}

function load_zones(conn) {
	let zones = {};
	conn.uci_foreach('firewall', 'zone', function(s) {
		if (s.name) zones[s.name] = true;
	});
	return zones;
}

function validate(json, conn) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}

	if (json.target == null) {
		push(errs, { field: "target", code: "required",
		             message: "is required" });
	} else if (!VALID_TARGETS[json.target]) {
		push(errs, { field: "target", code: "not_in_enum",
		             message: "must be one of ACCEPT, REJECT, DROP, NOTRACK, MARK" });
	}

	let m = json.match ?? {};
	if (type(m) != "object") {
		push(errs, { field: "match", code: "invalid_type",
		             message: "must be an object" });
		return errs;
	}

	if (m.src_zone == null || m.src_zone == "") {
		push(errs, { field: "match.src_zone", code: "required",
		             message: "is required" });
	}

	if (m.family != null && !VALID_FAMILIES[m.family]) {
		push(errs, { field: "match.family", code: "not_in_enum",
		             message: "must be one of any, ipv4, ipv6" });
	}

	let protos = as_list(m.proto);
	for (let i = 0; i < length(protos); i++) {
		if (!VALID_PROTOS[protos[i]]) {
			push(errs, {
				field: sprintf("match.proto[%d]", i),
				code: "not_in_enum",
				message: sprintf("%J is not a recognized protocol", protos[i]),
			});
		}
	}

	if (conn != null && m.src_zone != null && m.src_zone != "") {
		let zones = load_zones(conn);
		if (!zones[m.src_zone]) {
			push(errs, { field: "match.src_zone", code: "conflict",
			             message: sprintf("zone %J does not exist", m.src_zone) });
		}
	}
	if (conn != null && m.dest_zone != null && m.dest_zone != "") {
		let zones = load_zones(conn);
		if (!zones[m.dest_zone]) {
			push(errs, { field: "match.dest_zone", code: "conflict",
			             message: sprintf("zone %J does not exist", m.dest_zone) });
		}
	}

	return errs;
}

return {
	package: "firewall",
	type: "rule",
	reload: ["firewall"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		target: { type: "string", enum: keys(VALID_TARGETS) },
		match: {
			type: "object",
			properties: {
				src_zone:  { type: ["string", "null"] },
				dest_zone: { type: ["string", "null"] },
				src_ip:    { type: "array", items: { type: "string" } },
				dest_ip:   { type: "array", items: { type: "string" } },
				src_port:  { type: "array", items: { type: "string" } },
				dest_port: { type: "array", items: { type: "string" } },
				proto:     { type: "array", items: { type: "string", enum: keys(VALID_PROTOS) } },
				family:    { type: "string", enum: keys(VALID_FAMILIES) },
			},
		},
	},
};
