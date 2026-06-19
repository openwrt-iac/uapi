let values = require('values');
let normalize_bool = values.normalize_bool;
let as_int = values.as_int;
let is_valid_cidr = values.is_valid_cidr;
let is_valid_ip = values.is_valid_ip;

const VALID_FAMILY = { "ipv4": true, "ipv6": true };
const VALID_PROTO = { "tcp": true, "udp": true, "icmp": true, "all": true };

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		family:     section.family ?? null,
		proto:      section.proto ?? null,
		src_ip:     section.src_ip ?? null,
		src_port:   section.src_port ?? null,
		dest_ip:    section.dest_ip ?? null,
		dest_port:  section.dest_port ?? null,
		sticky:     normalize_bool(section.sticky, false),
		timeout:    as_int(section.timeout),
		ipset:      section.ipset ?? null,
		use_policy: section.use_policy ?? null,
		logging:    normalize_bool(section.logging, false),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.family != null)     out.family = json.family;
	if (json.proto != null)      out.proto = json.proto;
	if (json.src_ip != null)     out.src_ip = json.src_ip;
	if (json.src_port != null)   out.src_port = json.src_port;
	if (json.dest_ip != null)    out.dest_ip = json.dest_ip;
	if (json.dest_port != null)  out.dest_port = json.dest_port;
	if (json.sticky != null)     out.sticky = json.sticky ? "1" : "0";
	if (json.timeout != null)    out.timeout = "" + json.timeout;
	if (json.ipset != null)      out.ipset = json.ipset;
	if (json.use_policy != null) out.use_policy = json.use_policy;
	if (json.logging != null)    out.logging = json.logging ? "1" : "0";
	return out;
}

function _load_policy_names(conn) {
	let names = {};
	if (conn == null) return names;
	conn.uci_foreach("mwan3", "policy", function(s) {
		if (s['.name'] != null) names[s['.name']] = true;
	});
	return names;
}

// src_ip / dest_ip accept either a bare IP or a CIDR. uci docs allow both.
function _is_valid_addr_or_cidr(s) {
	return is_valid_ip(s) || is_valid_cidr(s);
}

function validate(json, conn) {
	let errs = [];
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
	if (json.use_policy == null || json.use_policy == "") {
		push(errs, { field: "use_policy", code: "required", message: "is required" });
	} else if (conn != null) {
		let known = _load_policy_names(conn);
		if (!known[json.use_policy])
			push(errs, { field: "use_policy", code: "conflict",
			             message: sprintf("no mwan3 policy named %J", json.use_policy) });
	}
	if (json.src_ip != null && json.src_ip != "" && !_is_valid_addr_or_cidr(json.src_ip))
		push(errs, { field: "src_ip", code: "invalid_format",
		             message: "must be a valid IP or CIDR" });
	if (json.dest_ip != null && json.dest_ip != "" && !_is_valid_addr_or_cidr(json.dest_ip))
		push(errs, { field: "dest_ip", code: "invalid_format",
		             message: "must be a valid IP or CIDR" });
	return errs;
}

return {
	package: "mwan3",
	type: "rule",
	reload: ["mwan3"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "mwan3 rule",
	id_prefix: "r",
	openapi_required: ["use_policy"],
	schema_properties: {
		family:     { type: ["string", "null"], enum: [...keys(VALID_FAMILY), null] },
		proto:      { type: ["string", "null"], enum: [...keys(VALID_PROTO), null] },
		src_ip:     { type: ["string", "null"], description: "IP address or CIDR." },
		src_port:   { type: ["string", "null"], description: "Single port or 'lo-hi' range." },
		dest_ip:    { type: ["string", "null"], description: "IP address or CIDR." },
		dest_port:  { type: ["string", "null"], description: "Single port or 'lo-hi' range." },
		sticky:     { type: "boolean", default: false,
		              description: "Pin matching connections to the same member for `timeout` seconds." },
		timeout:    { type: ["integer", "null"], minimum: 1, maximum: 86400 },
		ipset:      { type: ["string", "null"],
		              description: "Match destination against an ipset; bypasses src/dest_ip." },
		use_policy: { type: "string",
		              description: "Name of an mwan3:policies section." },
		logging:    { type: "boolean", default: false },
	},
};
