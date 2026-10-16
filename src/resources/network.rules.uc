let fs = require('fs');
let values = require('values');
let platform_bool = values.platform_bool;
let is_valid_cidr = values.is_valid_cidr;
let is_valid_ipv4 = values.is_valid_ipv4;
let netifd_int = values.netifd_int;
let rt_table_id = values.rt_table_id;

const VALID_ACTIONS = { "lookup": true, "goto": true, "unreachable": true,
                        "prohibit": true, "blackhole": true, "throw": true };

// netifd parses `action` with system_rtn_aton, which knows `unicast` but neither `lookup` nor
// `goto`, and drops a rule whose action it cannot read. Without one, a rule is a goto rule when
// its goto parses and a lookup rule otherwise, and `unicast` is that same lookup.
function rule_action(action, has_goto) {
	if (type(action) == "string" && action != "" && action != "unicast") return action;
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
	if (json.disabled != null) out.disabled = json.disabled ? "1" : "0";
	return out;
}

function validate(json) {
	let errs = [];

	// A mark is a selector in its own right, and the one that matters for policy
	// routing reply traffic: firewall4 marks in mangle prerouting and the rule
	// sends the mark to a table, with no source or destination knowable in
	// advance. `ip rule add fwmark 0x43 lookup 43` is valid, netifd writes it
	// from a rule carrying only mark/lookup/priority, and the kernel prints it
	// back as `from all fwmark 0x43`. Leaving mark out here forced the caller to
	// add `src: "0.0.0.0/0"`, which is what a mark-only rule already means.
	let has_selector = (json['in'] != null && json['in'] != "")
	                || (json.out != null && json.out != "")
	                || (json.src != null && json.src != "")
	                || (json.dest != null && json.dest != "")
	                || (json.mark != null && json.mark != "");
	if (!has_selector)
		push(errs, { field: "", code: "required",
		             message: "at least one of in/out/src/dest/mark must be set" });

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

return {
	package: "network",
	type: "rule",
	reload: ["network"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "network policy rule",
	openapi_conditional: [
		{ anyOf: [
		    { required: ["in"] },
		    { required: ["out"] },
		    { required: ["src"] },
		    { required: ["dest"] },
		    { required: ["mark"] },
		  ] },
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
		priority: { "x-uapi-read-nullable": true, type: "integer", minimum: 0, maximum: 32766 },
		lookup:   { type: ["integer", "null"], minimum: 0, maximum: 4294967295, "x-uapi-write": { minimum: 1 },
		            description: "Routing table id to look up when action is lookup. A name that uci stores reads as its id: 253 default, 254 main, 255 local, or the id in /etc/iproute2/rt_tables. 0 reads when netifd cannot resolve the stored table, and netifd then drops the rule; a write of 0 answers 422." },
		goto:     { type: ["integer", "null"], minimum: 0, maximum: 2147483647, "x-uapi-write": { minimum: 1 },
		            description: "Priority of the rule to jump to when action is goto. It must be above `priority`: the kernel refuses a goto that does not jump forward, and without a priority netifd places the rule by its position, so a goto that does not jump past it fails too." },
		action:   { type: "string", enum: keys(VALID_ACTIONS),
		            description: "What the rule does with matching traffic. netifd parses no `lookup` or `goto` action: a rule without one is a goto rule when `goto` is set and a lookup rule otherwise, so a read derives the action the same way, and a write stores no action for lookup and goto." },
		invert:   { type: "boolean", default: false,
		            description: "Invert the match selectors" },
		mark:     { type: ["string", "null"],
		            description: "Match fwmark (value or value/mask)" },
	},
};
