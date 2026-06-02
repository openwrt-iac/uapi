let values = require('values');
let normalize_bool = values.normalize_bool;

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		enable: normalize_bool(section.enable, true),
		Port: section.Port ?? null,
		PasswordAuth: normalize_bool(section.PasswordAuth, true),
		RootPasswordAuth: normalize_bool(section.RootPasswordAuth, true),
		RootLogin: normalize_bool(section.RootLogin, true),
		BannerFile: section.BannerFile ?? null,
		Interface: section.Interface ?? null,
		GatewayPorts: normalize_bool(section.GatewayPorts, false),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.enable != null)            out.enable = json.enable ? "1" : "0";
	if (json.Port != null)              out.Port = "" + json.Port;
	if (json.PasswordAuth != null)      out.PasswordAuth = json.PasswordAuth ? "1" : "0";
	if (json.RootPasswordAuth != null)  out.RootPasswordAuth = json.RootPasswordAuth ? "1" : "0";
	if (json.RootLogin != null)         out.RootLogin = json.RootLogin ? "1" : "0";
	if (json.BannerFile != null)        out.BannerFile = json.BannerFile;
	if (json.Interface != null)         out.Interface = json.Interface;
	if (json.GatewayPorts != null)      out.GatewayPorts = json.GatewayPorts ? "1" : "0";
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
	id_prefix: "d",
	schema_properties: {
		Port: { type: "integer", minimum: 1, maximum: 65535 },
	},
};
