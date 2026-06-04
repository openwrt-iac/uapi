let values = require('values');
let normalize_bool = values.normalize_bool;
let as_int = values.as_int;

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		enable:             normalize_bool(section.enable, true),
		port:               as_int(section.Port),
		password_auth:      normalize_bool(section.PasswordAuth, true),
		root_password_auth: normalize_bool(section.RootPasswordAuth, true),
		root_login:         normalize_bool(section.RootLogin, true),
		banner_file:        section.BannerFile ?? null,
		interface:          section.Interface ?? null,
		gateway_ports:      normalize_bool(section.GatewayPorts, false),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.enable != null)             out.enable = json.enable ? "1" : "0";
	if (json.port != null)               out.Port = "" + json.port;
	if (json.password_auth != null)      out.PasswordAuth = json.password_auth ? "1" : "0";
	if (json.root_password_auth != null) out.RootPasswordAuth = json.root_password_auth ? "1" : "0";
	if (json.root_login != null)         out.RootLogin = json.root_login ? "1" : "0";
	if (json.banner_file != null)        out.BannerFile = json.banner_file;
	if (json.interface != null)          out.Interface = json.interface;
	if (json.gateway_ports != null)      out.GatewayPorts = json.gateway_ports ? "1" : "0";
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
	package: "dropbear",
	type: "dropbear",
	reload: ["dropbear"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "dropbear instance",
	id_prefix: "d",
	schema_properties: {
		enable:             { type: "boolean" },
		port:               { type: "integer", minimum: 1, maximum: 65535 },
		password_auth:      { type: "boolean" },
		root_password_auth: { type: "boolean" },
		root_login:         { type: "boolean" },
		banner_file:        { type: ["string", "null"] },
		interface:          { type: ["string", "null"], description: "Listen interface or IP" },
		gateway_ports:      { type: "boolean", description: "Allow remote port forwarding" },
	},
};
