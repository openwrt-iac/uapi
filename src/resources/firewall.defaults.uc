let values = require('values');
let normalize_bool = values.normalize_bool;

const VALID_POLICIES = { "ACCEPT": true, "REJECT": true, "DROP": true };

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		input: section.input ?? null,
		output: section.output ?? null,
		forward: section.forward ?? null,
		syn_flood: normalize_bool(section.syn_flood, false),
		drop_invalid: normalize_bool(section.drop_invalid, false),
		synflood_burst: section.synflood_burst ?? null,
		synflood_rate: section.synflood_rate ?? null,
		tcp_syncookies: normalize_bool(section.tcp_syncookies, false),
		flow_offloading: normalize_bool(section.flow_offloading, false),
		flow_offloading_hw: normalize_bool(section.flow_offloading_hw, false),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.input != null)    out.input = json.input;
	if (json.output != null)   out.output = json.output;
	if (json.forward != null)  out.forward = json.forward;
	if (json.syn_flood != null)    out.syn_flood = json.syn_flood ? "1" : "0";
	if (json.drop_invalid != null) out.drop_invalid = json.drop_invalid ? "1" : "0";
	if (json.synflood_burst != null) out.synflood_burst = "" + json.synflood_burst;
	if (json.synflood_rate != null)  out.synflood_rate  = "" + json.synflood_rate;
	if (json.tcp_syncookies != null) out.tcp_syncookies = json.tcp_syncookies ? "1" : "0";
	if (json.flow_offloading != null)    out.flow_offloading    = json.flow_offloading ? "1" : "0";
	if (json.flow_offloading_hw != null) out.flow_offloading_hw = json.flow_offloading_hw ? "1" : "0";
	return out;
}

function validate(json) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}

	for (let field in ["input", "output", "forward"]) {
		if (json[field] != null && !VALID_POLICIES[json[field]])
			push(errs, { field: field, code: "not_in_enum",
			             message: "must be one of ACCEPT, REJECT, DROP" });
	}

	for (let field in ["synflood_burst", "synflood_rate"]) {
		if (json[field] == null) continue;
		let n = int(json[field]);
		if (n < 1 || n > 1000000)
			push(errs, { field: field, code: "out_of_range",
			             message: "must be a positive integer (typical range 1-1000000)" });
	}

	return errs;
}

return {
	package: "firewall",
	type: "defaults",
	reload: ["firewall"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		input:   { type: "string", enum: keys(VALID_POLICIES) },
		output:  { type: "string", enum: keys(VALID_POLICIES) },
		forward: { type: "string", enum: keys(VALID_POLICIES) },
	},
};
