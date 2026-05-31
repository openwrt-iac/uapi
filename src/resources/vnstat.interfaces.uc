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
	let found = false;
	conn.uci_foreach('network', 'interface', function(s) {
		if (s['.name'] == name) { found = true; return false; }
	});
	return found;
}

function validate(json, conn) {
	let errs = [];
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
	if (json.interface == null || json.interface == "")
		push(errs, { field: "interface", code: "required", message: "is required" });
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
	schema_properties: {},
};
