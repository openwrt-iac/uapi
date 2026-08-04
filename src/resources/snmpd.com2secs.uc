let values = require('values');

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		secname: section.secname ?? null,
		source: section.source ?? null,
		community: section.community ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.secname != null)   out.secname = json.secname;
	if (json.source != null)    out.source = json.source;
	if (json.community != null) out.community = json.community;
	return out;
}

function validate(json) {
	let errs = [];
	values.require_present(errs, json, "secname");
	if (json.source == null || json.source == "")
		push(errs, { field: "source", code: "required",
		             message: "is required (the source network range or 'default')" });
	values.require_present(errs, json, "community");
	return errs;
}

return {
	package: "snmpd",
	type: "com2sec",
	reload: ["snmpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "SNMP community-to-security mapping",
	openapi_required: ["secname", "source", "community"],
	schema_properties: {
		secname:   { type: "string", description: "security name this community maps to" },
		source:    { type: "string",
		             description: "source network/range or 'default'" },
		community: { type: "string", description: "SNMP community string" },
	},
};
