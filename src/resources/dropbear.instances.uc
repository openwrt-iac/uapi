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
	if (json.PasswordAuth != null)      out.PasswordAuth = json.PasswordAuth ? "on" : "off";
	if (json.RootPasswordAuth != null)  out.RootPasswordAuth = json.RootPasswordAuth ? "on" : "off";
	if (json.RootLogin != null)         out.RootLogin = json.RootLogin ? "1" : "0";
	if (json.BannerFile != null)        out.BannerFile = json.BannerFile;
	if (json.Interface != null)         out.Interface = json.Interface;
	if (json.GatewayPorts != null)      out.GatewayPorts = json.GatewayPorts ? "on" : "off";
	return out;
}

function validate(json) {
	let errs = [];
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
	if (json.Port != null) {
		let p = int(json.Port);
		if (p < 1 || p > 65535)
			push(errs, { field: "Port", code: "out_of_range",
			             message: "must be 1-65535" });
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
