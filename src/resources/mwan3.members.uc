let values = require('values');
let as_int = values.as_int;

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		interface: section.interface ?? null,
		metric:    as_int(section.metric),
		weight:    as_int(section.weight),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.interface != null) out.interface = json.interface;
	if (json.metric != null)    out.metric = "" + json.metric;
	if (json.weight != null)    out.weight = "" + json.weight;
	return out;
}

function validate(json, conn) {
	let errs = [];
	if (json.interface == null || json.interface == "") {
		push(errs, { field: "interface", code: "required", message: "is required" });
	} else if (conn != null) {
		let known = values.section_index(conn, "mwan3", "interface", '.name');
		if (!known[json.interface])
			push(errs, { field: "interface", code: "conflict",
			             message: sprintf("no mwan3 interface named %J", json.interface) });
	}
	return errs;
}

// mwan3_set_policy() leaves a member with a metric above DEFAULT_LOWEST_METRIC out of its policy.
const MAX_METRIC = 256;

function validate_new(json) {
	return (type(json.metric) == "int" && json.metric > MAX_METRIC)
		? [ { field: "metric", code: "out_of_range",
		      message: sprintf("must be <= %d: mwan3 leaves a member with a higher metric out of its policy", MAX_METRIC) } ]
		: [];
}

return {
	package: "mwan3",
	type: "member",
	reload: ["mwan3"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	validate_new: validate_new,
	openapi_singular: "mwan3 member",
	id_prefix: "m",
	openapi_required: ["interface"],
	schema_properties: {
		interface: { "x-uapi-read-nullable": true, type: "string",
		             description: "Name of an mwan3:interfaces section." },
		metric:    { type: ["integer", "null"], maximum: 1000, "x-uapi-write": { minimum: 1, maximum: MAX_METRIC },
		             description: "Lower wins. Members in the same policy with equal metric share load. Unset, mwan3 uses 1. mwan3 leaves a member with a metric above 256 out of its policy: a write refuses one, and a stored one blocks every write of the section, but a read can give one." },
		weight:    { type: ["integer", "null"], minimum: 1, "x-uapi-write": { maximum: 1000 },
		             description: "Relative load-share weight among equal-metric members." },
	},
};
