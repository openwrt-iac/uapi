let fs = require('fs');
let values = require('values');
let platform_bool = values.platform_bool;
let is_valid_cidr = values.is_valid_cidr;
let is_valid_ipv4 = values.is_valid_ipv4;
let netifd_int = values.netifd_int;
let netifd_string = values.netifd_string;
let rt_table_id = values.rt_table_id;
let MUSL_PROTOCOLS = values.MUSL_PROTOCOLS;

const VALID_ACTIONS = { "lookup": true, "goto": true, "unreachable": true,
                        "prohibit": true, "blackhole": true, "throw": true };

// The kernel refuses an IPv4 rule whose tos sets a bit outside 0x1c (fib4_rule_configure), and
// netifd drops one whose tos is above 255.
const TOS_VALUES = [ 0, 4, 8, 12, 16, 20, 24, 28 ];

// The kernel refuses a port range that holds 0 or 65535 or runs backwards
// (fib_rule_port_range_valid), and a uid range that runs backwards or holds 4294967295, which maps
// to no uid. netifd keeps a port in 16 bits and a uid in 32.
const PORT_PATTERN = "^[0-9]{1,5}(-[0-9]{1,5})?$";
const UID_PATTERN = "^[0-9]{1,10}(-[0-9]{1,10})?$";
const PORT_RE = regexp(PORT_PATTERN);
const RANGES = {
	uidrange: { re: regexp(UID_PATTERN), bits: 32, mask: 0xffffffff, min: 0, max: 4294967294, noun: "uid", example: "1000-1005" },
	sport:    { re: PORT_RE, bits: 16, mask: 0xffff, min: 1, max: 65534, noun: "port", example: "1000-2000" },
	dport:    { re: PORT_RE, bits: 16, mask: 0xffff, min: 1, max: 65534, noun: "port", example: "1000-2000" },
};

function in_range(r, lo, hi) {
	return lo >= r.min && hi <= r.max && lo <= hi;
}

// The number that strtoul with base 0, or sscanf's %u with base 10, reads at the start of s, cut to
// the 32 bits that netifd keeps, the length of text it takes, and whether the text is that number.
// null when no digit follows the whitespace and sign that both skip. A number that ucode cannot hold
// reads as 0xffffffff, which musl gives past 64 bits, and a negative one wraps.
function c_unsigned(s, base) {
	let m = match(s, (base == 10) ? /^[[:space:]]*[+-]?[0-9]+/
	                              : /^[[:space:]]*[+-]?(0[xX][0-9A-Fa-f]+|0[0-7]*|[1-9][0-9]*)/);
	if (m == null) return null;
	let n = int(m[0], base);
	return { n: (type(n) == "int") ? n & 0xffffffff : 0xffffffff, len: length(m[0]),
	         fits: type(n) == "int" && n >= 0 && n <= 0xffffffff };
}

// netifd takes a number above 0 that strtoul reads whole, or else a name, and drops the rule when
// neither resolves. It sends the kernel only the low byte of the number. The kernel takes any
// protocol, and reads 0, which `ip` resolves to, as any.
function ipproto_error(v) {
	let s = "" + v;
	let c = c_unsigned(s, 0);
	if (c != null && c.len == length(s))
		return (c.fits && c.n > 0 && c.n <= 255) ? null
			: { code: "out_of_range", message: "must be from 1 to 255: netifd drops a rule whose ipproto is 0, and sends the kernel only the low byte of a larger one" };
	return (index(MUSL_PROTOCOLS, s) >= 0) ? null
		: { code: "invalid_format", message: "must be a number from 1 to 255 or a protocol name that musl knows, such as tcp: netifd drops the rule otherwise" };
}

// netifd reads a range with sscanf("%u-%u"), which reads a second number only right after the dash
// and ignores what follows, and drops the rule without a first number. It sends the kernel a uid in
// 32 bits and a port in 16, so a larger number matches another one.
function range_error(r, v) {
	let s = "" + v;
	let a = c_unsigned(s, 10);
	let rest = (a != null) ? substr(s, a.len) : "";
	let b = ((substr(rest, 0, 1) == "-") ? c_unsigned(substr(rest, 1), 10) : null) ?? a;
	if (a == null || !in_range(r, a.n & r.mask, b.n & r.mask))
		return { code: (type(v) == "string" && match(v, r.re)) ? "out_of_range" : "invalid_format",
		         message: sprintf("must be a %s or a range of %ss such as %s, each from %d to %d and not backwards: netifd drops the rule otherwise, or the kernel refuses it",
		                          r.noun, r.noun, r.example, r.min, r.max) };
	if (!a.fits || !b.fits || a.n > r.mask || b.n > r.mask)
		return { code: "out_of_range",
		         message: sprintf("each %s must be at most %d: netifd sends the kernel its low %d bits, which match another %s", r.noun, r.max, r.bits, r.noun) };
	return null;
}

// LuCI writes a decimal, which reads as the integer it is. Another spelling, such as a name or 06,
// reads as uci holds it.
function rule_ipproto(v) {
	v = netifd_string(v);
	return (v != null && match(v, /^(0|[1-9][0-9]{0,17})$/)) ? int(v) : v;
}

// netifd parses `action` with system_rtn_aton, which knows `unicast` but neither `lookup` nor
// `goto`, and drops a rule whose action it cannot read. Without one, a rule is a goto rule when
// its goto parses and a lookup rule otherwise. `unicast` is a lookup even beside a goto: netifd
// then sends the goto with type unicast, which the kernel refuses.
function rule_action(action, has_goto) {
	if (action == "unicast") return "lookup";
	if (type(action) == "string" && action != "") return action;
	return has_goto ? "goto" : "lookup";
}

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		in: section['in'] ?? null,
		out: section.out ?? null,
		src: section.src ?? null,
		dest: section.dest ?? null,
		priority: netifd_int(section.priority),
		lookup: rt_table_id(section.lookup, () => fs.readfile("/etc/iproute2/rt_tables")),
		goto: netifd_int(section['goto']),
		action: rule_action(section.action, netifd_int(section['goto']) != null),
		invert: platform_bool(section.invert, false),
		mark: section.mark ?? null,
		suppress_prefixlength: netifd_int(section.suppress_prefixlength),
		tos: netifd_int(section.tos),
		uidrange: netifd_string(section.uidrange),
		ipproto: rule_ipproto(section.ipproto),
		sport: netifd_string(section.sport),
		dport: netifd_string(section.dport),
		// See network.routes: netifd drops a disabled section outright, so an unmodelled
		// flag makes a rule that is not in `ip rule` read back as active configuration.
		disabled: platform_bool(section.disabled, false),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json['in'] != null)   out['in'] = json['in'];
	if (json.out != null)     out.out = json.out;
	if (json.src != null)     out.src = json.src;
	if (json.dest != null)    out.dest = json.dest;
	if (json.priority != null) out.priority = "" + json.priority;
	// A lookup table name on write is resolved like netifd resolves it and stored as its id,
	// so a plan that reads the id back stays stable when /etc/iproute2/rt_tables changes.
	if (json.lookup != null)
		out.lookup = "" + (type(json.lookup) == "string"
			? rt_table_id(json.lookup, () => fs.readfile("/etc/iproute2/rt_tables"))
			: json.lookup);
	if (json['goto'] != null) out['goto'] = "" + json['goto'];
	// Cleared for lookup and goto, so a write repairs a stored `action 'goto'` that netifd
	// would drop with the whole rule.
	out.action = (json.action != null && json.action != "lookup" && json.action != "goto") ? json.action : [];
	if (json.invert != null)  out.invert = json.invert ? "1" : "0";
	if (json.mark != null)    out.mark = json.mark;
	if (json.suppress_prefixlength != null) out.suppress_prefixlength = "" + json.suppress_prefixlength;
	if (json.tos != null)     out.tos = "" + json.tos;
	if (json.uidrange != null) out.uidrange = json.uidrange;
	if (json.ipproto != null) out.ipproto = "" + json.ipproto;
	if (json.sport != null)   out.sport = json.sport;
	if (json.dport != null)   out.dport = json.dport;
	if (json.disabled != null) out.disabled = json.disabled ? "1" : "0";
	return out;
}

function validate(json) {
	let errs = [];

	if (json.src != null && json.src != "" && !is_valid_ipv4(json.src) && !is_valid_cidr(json.src))
		push(errs, { field: "src", code: "invalid_format",
		             message: "must be a valid IPv4 address or CIDR" });

	if (json.dest != null && json.dest != "" && !is_valid_ipv4(json.dest) && !is_valid_cidr(json.dest))
		push(errs, { field: "dest", code: "invalid_format",
		             message: "must be a valid IPv4 address or CIDR" });

	let action = rule_action(json.action, json['goto'] != null);
	if (action == "lookup" && (json.lookup == null || json.lookup === ""))
		push(errs, { field: "lookup", code: "required",
		             message: "is required when action is lookup" });
	// The schema allows 0 because a read reports a lookup that netifd cannot resolve as 0.
	if (json.lookup === 0)
		push(errs, { field: "lookup", code: "out_of_range",
		             message: "must be from 1 to 4294967295: netifd drops a rule whose lookup is 0, or a name it cannot resolve, which reads as 0" });
	if (type(json.lookup) == "string"
	    && rt_table_id(json.lookup, () => fs.readfile("/etc/iproute2/rt_tables")) == 0)
		push(errs, { field: "lookup", code: "invalid_format",
		             message: "must be an id from 1 to 4294967295 or a name from /etc/iproute2/rt_tables (default, main and local included): netifd drops a rule whose lookup it cannot resolve, which reads as 0" });
	if (action == "goto" && (json['goto'] == null || json['goto'] === ""))
		push(errs, { field: "goto", code: "required",
		             message: "is required when action is goto" });
	// With lookup netifd installs a goto rule, which reads back as one, and the kernel refuses a
	// goto beside any other action.
	if (json['goto'] != null && action != "goto")
		push(errs, { field: "goto", code: "conflict",
		             message: sprintf("applies only when action is goto, not %s; send null or leave it out", action) });
	if (action == "goto" && type(json['goto']) == "int"
	    && (json['goto'] < 1 || (type(json.priority) == "int" && json['goto'] <= json.priority)))
		push(errs, { field: "goto", code: "out_of_range",
		             message: "must be at least 1 and above priority: the kernel refuses a goto that does not jump forward" });

	return errs;
}

// A write takes only the plain forms, which the request schema declares. Another form that LuCI or
// a hand edit stores is no error while netifd installs the rule with the value that it holds.
// netifd installs no disabled rule.
function validate_new(json) {
	let errs = [];
	let enabled = json.disabled !== true;
	if (json.tos != null && index(TOS_VALUES, json.tos) == -1)
		push(errs, { field: "tos", code: "not_in_enum", live: enabled,
		             message: "must be 0, 4, 8, 12, 16, 20, 24 or 28: netifd drops a rule whose tos is above 255, and the kernel refuses an IPv4 rule whose tos sets a bit outside 0x1c" });
	let pe = (json.ipproto != null) ? ipproto_error(json.ipproto) : null;
	if (pe)
		push(errs, { field: "ipproto", ...pe, live: enabled });
	for (let k, r in RANGES) {
		let re = (json[k] != null) ? range_error(r, json[k]) : null;
		if (re)
			push(errs, { field: k, ...re, live: enabled });
	}
	return errs;
}

return {
	package: "network",
	type: "rule",
	reload: ["network"],
	// odhcpd reads this config and has a procd trigger on it. dnsmasq and unbound, which LuCI's
	// ucitrack also reloads, read only ula_prefix and the interface names here: see docs/raw.md.
	reload_if_running: ["odhcpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	validate_new: validate_new,
	openapi_singular: "network policy rule",
	openapi_conditional: [
		{ if:   { properties: { action: { const: "lookup" } }, required: ["action"] },
		  then: { required: ["lookup"] } },
		{ if:   { properties: { action: { const: "goto" } }, required: ["action"] },
		  then: { required: ["goto"] } },
	],
	schema_properties: {
		in:       { type: ["string", "null"],
		            description: "Match traffic arriving on this interface" },
		out:      { type: ["string", "null"],
		            description: "Match traffic departing on this interface" },
		src:      { type: ["string", "null"],
		            description: "Match source IPv4 address or CIDR" },
		dest:     { type: ["string", "null"],
		            description: "Match destination IPv4 address or CIDR" },
		disabled: { type: "boolean", default: false,
		            description: "Whether netifd skips this rule. A disabled rule is not installed at all, so it is absent from `ip rule`." },
		priority: { "x-uapi-read-nullable": true, type: "integer", minimum: -2147483648, maximum: 2147483647, "x-uapi-write": { minimum: 0 },
		            description: "Position of the rule: a lower one runs first. Without one, netifd numbers the rule by its place among the rules, from 1 up, which puts it ahead of `main` at 32766. A rule without a selector matches every packet, so with a table that holds a default route it routes all traffic, the management session included. LuCI allows the same." },
		lookup:   { type: ["integer", "string", "null"], minimum: 0, maximum: 4294967295,
		            "x-uapi-write": { minimum: 1 },
		            description: "Routing table to look up when action is lookup. A read answers the id (an integer, never a string): 253 default, 254 main, 255 local, or the id in /etc/iproute2/rt_tables; 0 reads when netifd cannot resolve the stored table, and netifd then drops the rule. A write takes that id, or a table name, which is resolved like netifd resolves it and stored as its id; a name that does not resolve answers 422, as does an id of 0." },
		goto:     { type: ["integer", "null"], minimum: 0, maximum: 2147483647, "x-uapi-write": { minimum: 1 },
		            description: "Priority of the rule to jump to when action is goto. It must be above `priority`: the kernel refuses a goto that does not jump forward, and without a priority netifd places the rule by its position, so a goto that does not jump past it fails too." },
		action:   { type: "string", enum: keys(VALID_ACTIONS),
		            description: "What the rule does with matching traffic. netifd parses no `lookup` or `goto` action: a rule without one is a goto rule when `goto` is set and a lookup rule otherwise, so a read derives the action the same way, and a write stores no action for lookup and goto." },
		invert:   { type: "boolean", default: false,
		            description: "Invert the match selectors" },
		mark:     { type: ["string", "null"],
		            description: "Match fwmark (value or value/mask)" },
		suppress_prefixlength: { type: ["integer", "null"], minimum: -2147483648, maximum: 2147483647, "x-uapi-write": { minimum: 0, maximum: 32 },
		            description: "Ignore a route that the lookup of this rule finds when its prefix is this long or shorter, and go on to the next rule: 0 ignores only a default route. A write takes 0 to 32, as LuCI does. A read reports what netifd reads: `0x10` reads 16, and a value that it cannot parse reads null, because netifd ignores it. The kernel takes any other value, -1 as unset and 32 or more as ignoring every IPv4 route, so a stored one reads as it is and is no error." },
		// The request schema refuses a null that its enum does not list, and a null clears the field.
		tos:      { type: ["integer", "null"], minimum: -2147483648, maximum: 2147483647,
		            "x-uapi-write": { enum: [ null, ...TOS_VALUES ] },
		            description: "Match this TOS value. A write takes 0, 4, 8, 12, 16, 20, 24 or 28: netifd drops a rule whose tos is above 255, and the kernel refuses an IPv4 rule whose tos sets a bit outside 0x1c, so the rule is not installed. 0 matches every packet. A read reports what netifd reads, as for `suppress_prefixlength`, so the 10 that LuCI suggests reads 10." },
		uidrange: { type: ["string", "null"], "x-uapi-write": { pattern: UID_PATTERN },
		            description: "Match traffic of local sockets owned by this uid, or by a range of uids such as `1000-1005`, each from 0 to 4294967294. The kernel refuses a range that runs backwards or holds 4294967295, and netifd wraps a larger number. A read reports the stored text. A form that a write refuses, such as `1000-1005x`, which netifd reads as 1000-1005, is no error while netifd installs the rule with it." },
		ipproto:  { type: ["integer", "string", "null"], minimum: 0, "x-uapi-write": { type: [ "integer", "null" ], minimum: 1, maximum: 255 },
		            description: "Match this IP protocol. A write takes an integer from 1 to 255, as LuCI writes it: netifd drops a rule whose ipproto is 0, and sends the kernel only the low byte of a larger one. A stored decimal reads as an integer. netifd also takes a number in another spelling, such as `06` or `0x6`, or a name in musl's table, such as `tcp`, where `ip` resolves to 0, which matches every protocol. Those read as the stored text, and are no error while netifd installs the rule with them." },
		sport:    { type: ["string", "null"], "x-uapi-write": { pattern: PORT_PATTERN },
		            description: "Match this source port, or a range of ports such as `1000-2000`, each from 1 to 65534. The kernel refuses a range that holds 0 or 65535 or runs backwards, as the `0-65535` that LuCI suggests does, and netifd wraps a larger number. A read reports the stored text, as for `uidrange`." },
		dport:    { type: ["string", "null"], "x-uapi-write": { pattern: PORT_PATTERN },
		            description: "Match this destination port, or a range of ports such as `1000-2000`, each from 1 to 65534. The kernel refuses a range that holds 0 or 65535 or runs backwards, as the `0-65535` that LuCI suggests does, and netifd wraps a larger number. A read reports the stored text, as for `uidrange`." },
	},
};
