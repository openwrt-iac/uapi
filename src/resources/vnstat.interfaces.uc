let values = require('values');
let normalize_bool = values.normalize_bool;

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		interface: section.interface ?? null,
		enabled: normalize_bool(section.enabled, true),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.interface != null) out.interface = json.interface;
	if (json.enabled != null)   out.enabled = json.enabled ? "1" : "0";
	return out;
}

function interface_exists(conn, name) {
	return values.section_index(conn, 'network', 'interface', '.name')[name] != null;
}

function validate(json, conn) {
	let errs = [];
	values.require_present(errs, json, "interface");
	if (conn != null && json.interface != null && json.interface != "") {
		if (!interface_exists(conn, json.interface))
			push(errs, { field: "interface", code: "conflict",
			             message: sprintf("network interface %J does not exist",
			                              json.interface) });
	}
	return errs;
}

return {
	package: "vnstat",
	type: "interface",
	reload: ["vnstat"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "vnstat interface",
	openapi_required: ["interface"],
	schema_properties: {
		interface: { type: "string",
		             description: "Network interface to track (must exist in network/interfaces)" },
		enabled:   { type: "boolean", default: true, description: "Whether vnstat tracks this interface" },
	},
};
