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
	let use_dhcp = (json.use_dhcp == null) ? true : !!json.use_dhcp;
	let servers = as_list(json.server);
	if (!use_dhcp && length(servers) == 0)
		push(errs, { field: "server", code: "required",
		             message: "at least one NTP server is required when use_dhcp is false" });
	let want_server = (json.enable_server == null) ? false : !!json.enable_server;
	if (want_server && length(servers) == 0 && !use_dhcp)
		push(errs, { field: "server", code: "required",
		             message: "enable_server=true with no upstream servers is unworkable" });
	return errs;
}

return {
	package: "system",
	type: "timeserver",
	reload: ["sysntpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "timeserver",
	openapi_conditional: [
		{ if:   { properties: { use_dhcp: { const: false } }, required: ["use_dhcp"] },
		  then: { required: ["server"] } },
	],
	schema_properties: {
		enabled:       { type: "boolean",
		                 description: "Whether sysntpd runs at all" },
		enable_server: { type: "boolean",
		                 description: "Also serve time to LAN clients" },
		interface:     { type: ["string", "null"],
		                 description: "Bind sysntpd to a specific network interface" },
		server:        { type: "array", items: { type: "string" } },
		use_dhcp:      { type: "boolean",
		                 description: "Accept NTP servers learned via DHCP option 42" },
	},
};
