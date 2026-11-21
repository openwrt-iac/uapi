let fs = require('fs');
let values = require('values');
let platform_bool = values.platform_bool;
let is_valid_cidr = values.is_valid_cidr;
let is_valid_ipv4 = values.is_valid_ipv4;
let netifd_int = values.netifd_int;
let netifd_string = values.netifd_string;
let rt_table_id = values.rt_table_id;

const VALID_ACTIONS = { "lookup": true, "goto": true, "unreachable": true,
                        "prohibit": true, "blackhole": true, "throw": true };

// The kernel refuses an IPv4 rule whose tos sets a bit outside 0x1c (fib4_rule_configure), and
// netifd drops one whose tos is above 255.
const TOS_VALUES = [ 0, 4, 8, 12, 16, 20, 24, 28 ];

// musl's getprotobyname compares a name against this built-in table, case-sensitively.
const MUSL_PROTOCOLS = [ "ip", "icmp", "igmp", "ggp", "ipencap", "st", "tcp", "egp", "pup", "udp", "hmp",
                         "xns-idp", "rdp", "iso-tp4", "xtp", "ddp", "idpr-cmtp", "ipv6", "ipv6-route",
                         "ipv6-frag", "idrp", "rsvp", "gre", "esp", "ah", "skip", "ipv6-icmp", "ipv6-nonxt",
                         "ipv6-opts", "rspf", "vmtp", "ospf", "ipip", "encap", "pim", "raw" ];

// The kernel refuses a port range that holds 0 or 65535 or runs backwards
// (fib_rule_port_range_valid), and a uid range that runs backwards or holds 4294967295, which maps
// to no uid. netifd keeps a port in 16 bits and a uid in 32.
const PORT_PATTERN = "^[0-9]{1,5}(-[0-9]{1,5})?$";
const UID_PATTERN = "^[0-9]{1,10}(-[0-9]{1,10})?$";
const PORT_RE = regexp(PORT_PATTERN);
const RANGES = {
	uidrange: { re: regexp(UID_PATTERN), mask: 0xffffffff, min: 0, max: 4294967294, noun: "uid", example: "1000-1005" },
	sport:    { re: PORT_RE, mask: 0xffff, min: 1, max: 65534, noun: "port", example: "1000-2000" },
	dport:    { re: PORT_RE, mask: 0xffff, min: 1, max: 65534, noun: "port", example: "1000-2000" },
};

function in_range(r, lo, hi) {
	return lo >= r.min && hi <= r.max && lo <= hi;
}

// The number that strtoul with base 0, or sscanf's %u with base 10, reads at the start of s, cut to
// the 32 bits that netifd keeps, and the length of text it takes. null when no digit follows the
// whitespace and sign that both skip. A number that ucode cannot hold reads as 0xffffffff, which
// musl gives past 64 bits.
function c_unsigned(s, base) {
	let m = match(s, (base == 10) ? /^[[:space:]]*[+-]?[0-9]+/
	                              : /^[[:space:]]*[+-]?(0[xX][0-9A-Fa-f]+|0[0-7]*|[1-9][0-9]*)/);
	if (m == null) return null;
	let n = int(m[0], base);
	return { n: (type(n) == "int") ? n & 0xffffffff : 0xffffffff, len: length(m[0]) };
}

// netifd takes a number above 0 that strtoul reads whole, or else a name, and drops the rule when
// neither resolves. The kernel takes any protocol, and reads 0, which `ip` resolves to, as any.
function ipproto_installs(v) {
	let s = "" + v;
	let c = c_unsigned(s, 0);
	return (c != null && c.len == length(s) && c.n > 0) || index(MUSL_PROTOCOLS, s) >= 0;
}

// netifd reads a range with sscanf("%u-%u"), which reads a second number only right after the dash
// and ignores what follows, and drops the rule without a first number.
function range_installs(r, s) {
	let a = c_unsigned(s, 10);
	if (a == null) return false;
	let rest = substr(s, a.len);
	let b = (substr(rest, 0, 1) == "-") ? c_unsigned(substr(rest, 1), 10) : null;
	return in_range(r, a.n & r.mask, (b ?? a).n & r.mask);
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
	if (json.lookup != null)  out.lookup = "" + json.lookup;
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

// A write takes only the plain forms, while uci can hold others from LuCI or a hand edit. An error
// is live only for a value with which netifd drops the rule or the kernel refuses it, so enabling a
// rule that netifd installs as it is stays possible. netifd installs no disabled rule.
function validate_new(json) {
	let errs = [];
	let enabled = json.disabled !== true;
	let sp = json.suppress_prefixlength;
	if (type(sp) == "int" && (sp < 0 || sp > 32))
		push(errs, { field: "suppress_prefixlength", code: "out_of_range", live: false,
		             message: "must be from 0 to 32, the prefix lengths of IPv4, as LuCI takes it" });
	if (json.tos != null && index(TOS_VALUES, json.tos) == -1)
		push(errs, { field: "tos", code: "not_in_enum", live: enabled,
		             message: "must be 0, 4, 8, 12, 16, 20, 24 or 28: netifd drops a rule whose tos is above 255, and the kernel refuses an IPv4 rule whose tos sets a bit outside 0x1c" });
	let p = json.ipproto;
	if (p != null) {
		let live = enabled && !ipproto_installs(p);
		if (type(p) != "int")
			push(errs, { field: "ipproto", code: "invalid_type", live,
			             message: "must be an integer, as LuCI writes it: a protocol name or another spelling that uci holds passes only unchanged" });
		else if (p < 1 || p > 255)
			push(errs, { field: "ipproto", code: "out_of_range", live,
			             message: "must be from 1 to 255: netifd drops a rule whose ipproto is 0, and sends the kernel only the low byte of a larger one" });
	}
	for (let k, r in RANGES) {
		let v = json[k];
		if (v == null) continue;
		let live = enabled && !range_installs(r, "" + v);
		if (type(v) != "string" || !match(v, r.re)) {
			push(errs, { field: k, code: "invalid_format", live,
			             message: sprintf("must be a %s or a range of %ss such as %s", r.noun, r.noun, r.example) });
			continue;
		}
		let ends = map(split(v, "-"), (n) => int(n));
		if (!in_range(r, ends[0], ends[-1]))
			push(errs, { field: k, code: "out_of_range", live,
			             message: sprintf("each %s must be from %d to %d, and a range must not run backwards: the kernel refuses the rule otherwise, and netifd wraps a larger number", r.noun, r.min, r.max) });
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
		priority: { "x-uapi-read-nullable": true, type: "integer", minimum: 0, maximum: 32766,
		            description: "Position of the rule: a lower one runs first. Without one, netifd numbers the rule by its place among the rules, from 1 up, which puts it ahead of `main` at 32766. A rule without a selector matches every packet, so with a table that holds a default route it routes all traffic, the management session included. LuCI allows the same." },
		lookup:   { type: ["integer", "null"], minimum: 0, maximum: 4294967295, "x-uapi-write": { minimum: 1 },
		            description: "Routing table id to look up when action is lookup. A name that uci stores reads as its id: 253 default, 254 main, 255 local, or the id in /etc/iproute2/rt_tables. 0 reads when netifd cannot resolve the stored table, and netifd then drops the rule. A write of 0 answers 422." },
		goto:     { type: ["integer", "null"], minimum: 0, maximum: 2147483647, "x-uapi-write": { minimum: 1 },
		            description: "Priority of the rule to jump to when action is goto. It must be above `priority`: the kernel refuses a goto that does not jump forward, and without a priority netifd places the rule by its position, so a goto that does not jump past it fails too." },
		action:   { type: "string", enum: keys(VALID_ACTIONS),
		            description: "What the rule does with matching traffic. netifd parses no `lookup` or `goto` action: a rule without one is a goto rule when `goto` is set and a lookup rule otherwise, so a read derives the action the same way, and a write stores no action for lookup and goto." },
		invert:   { type: "boolean", default: false,
		            description: "Invert the match selectors" },
		mark:     { type: ["string", "null"],
		            description: "Match fwmark (value or value/mask)" },
		suppress_prefixlength: { type: ["integer", "null"], minimum: -2147483648, maximum: 2147483647, "x-uapi-write": { minimum: 0, maximum: 32 },
		            description: "Ignore a route that the lookup of this rule finds when its prefix is this long or shorter, and go on to the next rule: 0 ignores only a default route. A write takes 0 to 32, as LuCI does. A read reports what netifd reads: `0x10` reads 16, and a value that it cannot parse reads null, because netifd ignores it. The kernel takes any other value, -1 as unset and 32 or more as ignoring every IPv4 route, so a stored one reads as it is and a write may send it back unchanged." },
		// The request schema refuses a null that its enum does not list, and a null clears the field.
		tos:      { type: ["integer", "null"], minimum: -2147483648, maximum: 2147483647,
		            "x-uapi-write": { enum: [ null, ...TOS_VALUES ] },
		            description: "Match this TOS value. A write takes 0, 4, 8, 12, 16, 20, 24 or 28: netifd drops a rule whose tos is above 255, and the kernel refuses an IPv4 rule whose tos sets a bit outside 0x1c, so the rule is not installed. 0 matches every packet. A read reports what netifd reads, as for `suppress_prefixlength`, so the 10 that LuCI suggests reads 10." },
		uidrange: { type: ["string", "null"], "x-uapi-write": { pattern: UID_PATTERN },
		            description: "Match traffic of local sockets owned by this uid, or by a range of uids such as `1000-1005`, each from 0 to 4294967294. The kernel refuses a range that runs backwards or holds 4294967295, and netifd wraps a larger number. A read reports the stored text, and a write may send back unchanged a form that it refuses, such as `1000-1005x`, which netifd reads as 1000-1005." },
		ipproto:  { type: ["integer", "string", "null"], minimum: 0, "x-uapi-write": { minimum: 1, maximum: 255 },
		            description: "Match this IP protocol. A write takes an integer from 1 to 255, as LuCI writes it: netifd drops a rule whose ipproto is 0, and sends the kernel only the low byte of a larger one. A stored decimal reads as an integer. netifd also takes a number in another spelling, such as `06` or `0x6`, or a name in musl's table, such as `tcp`, where `ip` resolves to 0, which matches every protocol. Those read as the stored text, and a write may send one back unchanged." },
		sport:    { type: ["string", "null"], "x-uapi-write": { pattern: PORT_PATTERN },
		            description: "Match this source port, or a range of ports such as `1000-2000`, each from 1 to 65534. The kernel refuses a range that holds 0 or 65535 or runs backwards, as the `0-65535` that LuCI suggests does, and netifd wraps a larger number. A read reports the stored text, as for `uidrange`." },
		dport:    { type: ["string", "null"], "x-uapi-write": { pattern: PORT_PATTERN },
		            description: "Match this destination port, or a range of ports such as `1000-2000`, each from 1 to 65534. The kernel refuses a range that holds 0 or 65535 or runs backwards, as the `0-65535` that LuCI suggests does, and netifd wraps a larger number. A read reports the stored text, as for `uidrange`." },
	},
};
