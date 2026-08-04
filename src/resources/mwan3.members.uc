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

function _load_iface_names(conn) {
	return values.section_index(conn, "mwan3", "interface", '.name');
}

function validate(json, conn) {
	let errs = [];
	if (json.interface == null || json.interface == "") {
		push(errs, { field: "interface", code: "required", message: "is required" });
	} else if (conn != null) {
		let known = _load_iface_names(conn);
		if (!known[json.interface])
			push(errs, { field: "interface", code: "conflict",
			             message: sprintf("no mwan3 interface named %J", json.interface) });
	}
	return errs;
}

return {
	package: "mwan3",
	type: "member",
	reload: ["mwan3"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "mwan3 member",
	id_prefix: "m",
	openapi_required: ["interface"],
	schema_properties: {
		interface: { type: "string",
		             description: "Name of an mwan3:interfaces section." },
		metric:    { type: ["integer", "null"], minimum: 1, maximum: 1000,
		             description: "Lower wins. Members in the same policy with equal metric share load." },
		weight:    { type: ["integer", "null"], minimum: 1, maximum: 1000,
		             description: "Relative load-share weight among equal-metric members." },
	},
};
