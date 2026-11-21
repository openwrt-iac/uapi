let values = require('values');

const VALID_VERSIONS = { "v1": true, "v2c": true, "usm": true };
// snmpd also takes any, and each version in any case.
const WRITE = { version: { enum: keys(VALID_VERSIONS) } };

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

function validate(json, conn, id, delta, partial, stored) {
	let errs = [];
	values.require_present(errs, json, "group");
	values.write_bounds(errs, delta ?? json, WRITE, stored);
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
		group:   { "x-uapi-read-nullable": true, type: "string", pattern: values.ONE_WORD_RE,
		           description: "Group name referenced by snmpd/accesses entries" },
		version: { "x-uapi-read-nullable": true, type: "string", "x-uapi-write": WRITE.version },
		secname: { type: ["string", "null"], pattern: values.ONE_WORD_RE,
		           description: "Security name (community for v1/v2c, USM user for v3)" },
	},
};
