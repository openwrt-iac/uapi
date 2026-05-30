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

	if (json.loglevel != null) {
		let l = int(json.loglevel);
		if (l < 0 || l > 7)
			push(errs, { field: "loglevel", code: "out_of_range",
			             message: "must be 0-7" });
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
	schema_properties: {},
};
