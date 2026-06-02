let values = require('values');
let normalize_bool = values.normalize_bool;

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		maindhcp: normalize_bool(section.maindhcp, false),
		leasefile: section.leasefile ?? null,
		leasetrigger: section.leasetrigger ?? null,
		loglevel: section.loglevel ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.maindhcp != null)     out.maindhcp = json.maindhcp ? "1" : "0";
	if (json.leasefile != null)    out.leasefile = json.leasefile;
	if (json.leasetrigger != null) out.leasetrigger = json.leasetrigger;
	if (json.loglevel != null)     out.loglevel = "" + json.loglevel;
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
	package: "dhcp",
	type: "odhcpd",
	reload: ["odhcpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		maindhcp: { type: "boolean",
		            description: "Use odhcpd as the IPv4 DHCP server too" },
		loglevel: { type: "integer", minimum: 0, maximum: 7,
		            description: "syslog priority (0=emerg .. 7=debug)" },
	},
};
