let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;

const VALID_TARGETS = {
	"ACCEPT": true, "REJECT": true, "DROP": true,
	"NOTRACK": true, "MARK": true, "DSCP": true, "HELPER": true,
};

// fw4 accepts a DSCP as one of its symbolic classes (case-insensitively) or a
// number 0..63. LuCI's equivalent regex omits LE and is case-sensitive; we
// follow fw4 because it is what applies the config, so a value LuCI rejects
// but the box accepts still round-trips. Match options may be negated with a
// leading '!'; the set_* options carry NO_INVERT in fw4, and a negated value
// there makes it skip the whole section.
const DSCP_VAL = '([Cc][Ss][0-7]|[Bb][Ee]|[Ll][Ee]|[Aa][Ff][1-4][1-3]|[Ee][Ff]|0[xX][0-9a-fA-F]{1,2}|[0-9]{1,2})';
const HELPER_VAL = '[A-Za-z0-9][A-Za-z0-9._-]{0,31}';

const DSCP_RE = '^' + DSCP_VAL + '$';
const DSCP_MATCH_RE = '^!?' + DSCP_VAL + '$';
const HELPER_RE = '^' + HELPER_VAL + '$';
const HELPER_MATCH_RE = '^!?' + HELPER_VAL + '$';

const DSCP_MAX = 63;
const VALID_FAMILIES = { "any": true, "ipv4": true, "ipv6": true };
const VALID_PROTOS = {
	"tcp": true, "udp": true, "icmp": true, "icmpv6": true,
	"esp": true, "ah": true, "igmp": true, "any": true, "all": true,
};

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		target: section.target ?? null,
		enabled: normalize_bool(section.enabled, true),
		set_mark: section.set_mark ?? null,
		set_xmark: section.set_xmark ?? null,
		set_dscp: section.set_dscp ?? null,
		set_helper: section.set_helper ?? null,
		match: {
			src_zone: section.src ?? null,
			dest_zone: section.dest ?? null,
			src_ip: as_list(section.src_ip),
			dest_ip: as_list(section.dest_ip),
			src_port: as_list(section.src_port),
			dest_port: as_list(section.dest_port),
			proto: as_list(section.proto),
			family: section.family ?? "any",
			mark: section.mark ?? null,
			dscp: section.dscp ?? null,
			helper: section.helper ?? null,
		},
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.name != null) out.name = json.name;
	if (json.target != null) out.target = json.target;
	if (json.enabled != null) out.enabled = json.enabled ? "1" : "0";
	if (json.set_mark != null) out.set_mark = json.set_mark;
	if (json.set_xmark != null) out.set_xmark = json.set_xmark;
	if (json.set_dscp != null) out.set_dscp = json.set_dscp;
	if (json.set_helper != null) out.set_helper = json.set_helper;
	let m = json.match ?? {};
	if (m.src_zone != null) out.src = m.src_zone;
	if (m.dest_zone != null) out.dest = m.dest_zone;
	if (type(m.src_ip) == "array" && length(m.src_ip) > 0) out.src_ip = m.src_ip;
	if (type(m.dest_ip) == "array" && length(m.dest_ip) > 0) out.dest_ip = m.dest_ip;
	if (type(m.src_port) == "array" && length(m.src_port) > 0) out.src_port = m.src_port;
	if (type(m.dest_port) == "array" && length(m.dest_port) > 0) out.dest_port = m.dest_port;
	if (type(m.proto) == "array" && length(m.proto) > 0) out.proto = m.proto;
	if (m.family != null && m.family != "any") out.family = m.family;
	if (m.mark != null) out.mark = m.mark;
	if (m.dscp != null) out.dscp = m.dscp;
	if (m.helper != null) out.helper = m.helper;
	return out;
}

// '*' (and the synonym 'any') is firewall4's wildcard meaning "any zone"; the
// stock OpenWrt config ships rules with `option dest '*'` (e.g. Allow-ICMPv6-
// Forward). Validation must accept it alongside named zones.
const WILDCARD_ZONES = { "*": true, "any": true };

function load_zones(conn) {
	let zones = {};
	conn.uci_foreach('firewall', 'zone', function(s) {
		if (s.name) zones[s.name] = true;
	});
	return zones;
}

// fw4 derives the chain name from the zone (`helper_<zone>` / `notrack_<zone>`),
// so a wildcard is as unusable as an absent one: both leave rule.src.zone unset
// and fw4 discards the section.
const ZONE_REQUIRED_TARGETS = { "NOTRACK": true, "HELPER": true };

function is_set(v) {
	return type(v) == "string" && v != "";
}

function range_error(field, value, max, errs) {
	if (values.masked_value_exceeds(value, max))
		push(errs, { field, code: "out_of_range",
		             message: sprintf("%J exceeds the maximum of %d", value, max) });
}

function check_target_coupling(json, errs) {
	let t = json.target;
	let mark = is_set(json.set_mark);
	let xmark = is_set(json.set_xmark);

	if (t == "MARK") {
		if (!mark && !xmark)
			push(errs, { field: "set_mark", code: "required",
			             message: "one of set_mark or set_xmark is required when target is MARK" });
		if (mark && xmark)
			push(errs, { field: "set_xmark", code: "conflict",
			             message: "set_mark and set_xmark are mutually exclusive" });
	} else {
		if (mark)
			push(errs, { field: "set_mark", code: "conflict",
			             message: "is only valid when target is MARK; send null to clear it" });
		if (xmark)
			push(errs, { field: "set_xmark", code: "conflict",
			             message: "is only valid when target is MARK; send null to clear it" });
	}

	if (t == "DSCP") {
		if (!is_set(json.set_dscp))
			push(errs, { field: "set_dscp", code: "required",
			             message: "is required when target is DSCP" });
	} else if (is_set(json.set_dscp)) {
		push(errs, { field: "set_dscp", code: "conflict",
		             message: "is only valid when target is DSCP; send null to clear it" });
	}

	if (t == "HELPER") {
		if (!is_set(json.set_helper))
			push(errs, { field: "set_helper", code: "required",
			             message: "is required when target is HELPER" });
	} else if (is_set(json.set_helper)) {
		push(errs, { field: "set_helper", code: "conflict",
		             message: "is only valid when target is HELPER; send null to clear it" });
	}
}

function validate(json, conn) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}

	if (json.target == null)
		push(errs, { field: "target", code: "required", message: "is required" });

	let m = json.match ?? {};
	if (type(m) != "object") {
		push(errs, { field: "match", code: "invalid_type",
		             message: "must be an object" });
		return errs;
	}

	if (ZONE_REQUIRED_TARGETS[json.target] && !(is_set(m.src_zone) && !WILDCARD_ZONES[m.src_zone])) {
		push(errs, { field: "match.src_zone", code: "required",
		             message: sprintf("a named source zone is required when target is %s", json.target) });
	}

	check_target_coupling(json, errs);
	range_error("set_mark", json.set_mark, values.MARK_MAX, errs);
	range_error("set_xmark", json.set_xmark, values.MARK_MAX, errs);
	range_error("set_dscp", json.set_dscp, DSCP_MAX, errs);
	range_error("match.mark", m.mark, values.MARK_MAX, errs);
	range_error("match.dscp", m.dscp, DSCP_MAX, errs);

	if (conn != null && m.src_zone != null && m.src_zone != "" && !WILDCARD_ZONES[m.src_zone]) {
		let zones = load_zones(conn);
		if (!zones[m.src_zone]) {
			push(errs, { field: "match.src_zone", code: "conflict",
			             message: sprintf("zone %J does not exist", m.src_zone) });
		}
	}
	if (conn != null && m.dest_zone != null && m.dest_zone != "" && !WILDCARD_ZONES[m.dest_zone]) {
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
	openapi_singular: "firewall rule",
	openapi_required: ["target", "match"],
	openapi_conditional: [
		{ if:   { properties: { target: { enum: ["NOTRACK", "HELPER"] } }, required: ["target"] },
		  then: { properties: { match: { type: "object", required: ["src_zone"] } },
		          required: ["match"] } },
		{ if:   { properties: { target: { const: "MARK" } }, required: ["target"] },
		  then: { anyOf: [ { required: ["set_mark"] }, { required: ["set_xmark"] } ] } },
		{ if:   { properties: { target: { const: "DSCP" } }, required: ["target"] },
		  then: { required: ["set_dscp"] } },
		{ if:   { properties: { target: { const: "HELPER" } }, required: ["target"] },
		  then: { required: ["set_helper"] } },
	],
	schema_properties: {
		name:    { type: ["string", "null"],
		           description: "Human-readable label for this rule" },
		target:  { type: "string", enum: keys(VALID_TARGETS) },
		enabled: { type: "boolean", default: true },
		set_mark: { type: ["string", "null"], pattern: values.MARK_RE,
		            description: "Mark to set, as value or value/mask (decimal or 0x hex, 32-bit). Requires target MARK; mutually exclusive with set_xmark" },
		set_xmark: { type: ["string", "null"], pattern: values.MARK_RE,
		             description: "Mark to XOR, as value or value/mask (decimal or 0x hex, 32-bit). Requires target MARK; mutually exclusive with set_mark" },
		set_dscp: { type: ["string", "null"], pattern: DSCP_RE,
		            description: "DSCP class to apply: a symbolic name (CS0-CS7, BE, LE, AF11-AF43, EF, case-insensitive) or a number 0-63. Requires target DSCP" },
		set_helper: { type: ["string", "null"], pattern: HELPER_RE,
		              description: "Conntrack helper to assign, e.g. ftp or sip. Matched case-sensitively against the helpers firewall4 has loaded. Requires target HELPER" },
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
				family:    { type: "string", enum: keys(VALID_FAMILIES), default: "any" },
				mark:      { type: ["string", "null"], pattern: values.MARK_MATCH_RE,
				             description: "Match fwmark as value or value/mask, optionally negated with a leading '!'" },
				dscp:      { type: ["string", "null"], pattern: DSCP_MATCH_RE,
				             description: "Match DSCP class or value, optionally negated with a leading '!'" },
				helper:    { type: ["string", "null"], pattern: HELPER_MATCH_RE,
				             description: "Match traffic tracked by this conntrack helper, optionally negated with a leading '!'" },
			},
		},
	},
};
