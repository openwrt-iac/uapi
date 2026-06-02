let values = require('values');
let normalize_bool = values.normalize_bool;
let is_valid_cidr = values.is_valid_cidr;
let is_valid_ipv4 = values.is_valid_ipv4;

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
		priority: section.priority ?? null,
		lookup: section.lookup ?? null,
		goto: section['goto'] ?? null,
		action: section.action ?? "lookup",
		invert: normalize_bool(section.invert, false),
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

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}

	let has_selector = (json['in'] != null && json['in'] != "")
	                || (json.out != null && json.out != "")
	                || (json.src != null && json.src != "")
	                || (json.dest != null && json.dest != "");
	if (!has_selector)
		push(errs, { field: "", code: "required",
		             message: "at least one of in/out/src/dest must be set" });

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
	schema_properties: {
		action:   { type: "string", enum: keys(VALID_ACTIONS) },
		priority: { type: "integer", minimum: 0, maximum: 32766 },
	},
};
