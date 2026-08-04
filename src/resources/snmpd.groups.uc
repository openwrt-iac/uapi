let values = require('values');

const VALID_VERSIONS = { "v1": true, "v2c": true, "usm": true };

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		group: section.group ?? null,
		version: section.version ?? null,
		secname: section.secname ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.group != null)   out.group = json.group;
	if (json.version != null) out.version = json.version;
	if (json.secname != null) out.secname = json.secname;
	return out;
}

function validate(json) {
	let errs = [];
	values.require_present(errs, json, "group");
	return errs;
}

return {
	package: "snmpd",
	type: "group",
	reload: ["snmpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "SNMP group",
	openapi_required: ["group"],
	schema_properties: {
		group:   { type: "string",
		           description: "Group name referenced by snmpd/accesses entries" },
		version: { type: "string", enum: keys(VALID_VERSIONS) },
		secname: { type: ["string", "null"],
		           description: "Security name (community for v1/v2c, USM user for v3)" },
	},
};
