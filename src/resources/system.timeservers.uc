let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		enabled: normalize_bool(section.enabled, true),
		enable_server: normalize_bool(section.enable_server, false),
		interface: section.interface ?? null,
		server: as_list(section.server),
		use_dhcp: normalize_bool(section.use_dhcp, true),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.enabled != null)        out.enabled = json.enabled ? "1" : "0";
	if (json.enable_server != null)  out.enable_server = json.enable_server ? "1" : "0";
	if (json.interface != null)      out.interface = json.interface;
	if (type(json.server) == "array" && length(json.server) > 0)
		out.server = json.server;
	if (json.use_dhcp != null)       out.use_dhcp = json.use_dhcp ? "1" : "0";
	return out;
}

function validate(json) {
	let errs = [];
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
	return errs;
}

return {
	package: "system",
	type: "timeserver",
	reload: ["sysntpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		server: { type: "array", items: { type: "string" } },
	},
};
