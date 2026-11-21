let values = require('values');
let strict_bool = values.strict_bool;
let as_int = values.as_int;
let is_valid_cidr_any = values.is_valid_cidr_any;
let is_valid_ip = values.is_valid_ip;

const VALID_FAMILY = { "ipv4": true, "ipv6": true, "any": true };
// iptables takes a number up to 255, all, a name that getprotobyname knows, or one of its own table.
// mwan3 loads every rule in one iptables-restore, which fails as a whole on another value.
const WRITE_PROTO_PATTERN = "^([0-9]{1,2}|1[0-9]{2}|2[0-4][0-9]|25[0-5]|"
	+ join("|", [ "all", ...values.MUSL_PROTOCOLS, "sctp", "udplite", "icmpv6", "ipv6-mh", "mh" ]) + ")$";

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
		sticky:     strict_bool(section.sticky),
		timeout:    as_int(section.timeout),
		ipset:      section.ipset ?? null,
		use_policy: section.use_policy ?? null,
		logging:    strict_bool(section.logging),
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

// src_ip / dest_ip accept either a bare IP (v4 or v6) or a CIDR (v4 or v6).
// Stock mwan3 default_rule_v6 ships `option dest_ip '::/0'`.
function _is_valid_addr_or_cidr(s) {
	return is_valid_ip(s) || is_valid_cidr_any(s);
}

function validate(json, conn) {
	let errs = [];
	if (json.use_policy == null || json.use_policy == "") {
		push(errs, { field: "use_policy", code: "required", message: "is required" });
	} else if (conn != null) {
		let known = values.section_index(conn, "mwan3", "policy", '.name');
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
		proto:      { type: ["string", "null"], pattern: "^([0-9]{1,3}|[A-Za-z][A-Za-z0-9._-]*)$",
		              "x-uapi-write": { pattern: WRITE_PROTO_PATTERN },
		              description: "IP protocol as iptables takes it: a number from 0 to 255, or a name such as tcp, udp, icmp, esp or all, which LuCI suggests. A write takes a name that iptables knows, in lower case. A stored name or number that iptables refuses reads as it is, and mwan3 then loads none of its rules." },
		src_ip:     { type: ["string", "null"], description: "IP address or CIDR." },
		src_port:   { type: ["string", "null"], pattern: values.SHELL_WORD_RE, description: "Single port or 'lo-hi' range." },
		dest_ip:    { type: ["string", "null"], description: "IP address or CIDR." },
		dest_port:  { type: ["string", "null"], pattern: values.SHELL_WORD_RE, description: "Single port or 'lo-hi' range." },
		sticky:     { type: "boolean", default: false,
		              description: "Pin matching connections to the same member for `timeout` seconds." },
		timeout:    { type: ["integer", "null"], minimum: 1, maximum: 2147483, "x-uapi-write": { maximum: 1000000 } },
		ipset:      { type: ["string", "null"], pattern: values.SHELL_WORD_RE,
		              description: "Match destination against an ipset; bypasses src/dest_ip." },
		use_policy: { "x-uapi-read-nullable": true, type: "string",
		              description: "Name of an mwan3:policies section." },
		logging:    { type: "boolean", default: false },
	},
};
