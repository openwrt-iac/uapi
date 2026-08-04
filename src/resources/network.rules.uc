let values = require('values');
let platform_bool = values.platform_bool;
let is_valid_cidr = values.is_valid_cidr;
let is_valid_ipv4 = values.is_valid_ipv4;
let as_int = values.as_int;

const VALID_ACTIONS = { "lookup": true, "goto": true, "unreachable": true,
                        "prohibit": true, "blackhole": true, "throw": true };

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		in: section['in'] ?? null,
		out: section.out ?? null,
		src: section.src ?? null,
		dest: section.dest ?? null,
		priority: as_int(section.priority),
		lookup: as_int(section.lookup),
		goto: as_int(section['goto']),
		action: section.action ?? "lookup",
		invert: platform_bool(section.invert, false),
		mark: section.mark ?? null,
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
	if (json.action != null && json.action != "lookup") out.action = json.action;
	if (json.invert != null)  out.invert = json.invert ? "1" : "0";
	if (json.mark != null)    out.mark = json.mark;
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

	let action = json.action ?? "lookup";
	if (action == "lookup" && (json.lookup == null || json.lookup == ""))
		push(errs, { field: "lookup", code: "required",
		             message: "is required when action is lookup" });
	if (action == "goto" && (json['goto'] == null || json['goto'] == ""))
		push(errs, { field: "goto", code: "required",
		             message: "is required when action is goto" });

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
		priority: { type: "integer", minimum: 0, maximum: 32766 },
		lookup:   { type: ["integer", "null"], minimum: 0,
		            description: "Routing table id to look up when action is lookup" },
		goto:     { type: ["integer", "null"], minimum: 0,
		            description: "Priority of the rule to jump to when action is goto" },
		action:   { type: "string", enum: keys(VALID_ACTIONS), default: "lookup" },
		invert:   { type: "boolean", default: false,
		            description: "Invert the match selectors" },
		mark:     { type: ["string", "null"],
		            description: "Match fwmark (value or value/mask)" },
	},
};
