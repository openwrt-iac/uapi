let values = require('values');
let as_list_or_null = values.as_list_or_null;

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		agentaddress: as_list_or_null(section.agentaddress),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (type(json.agentaddress) == "array" && length(json.agentaddress) > 0)
		out.agentaddress = json.agentaddress;
	return out;
}

function validate(json) {
	let errs = [];
	return errs;
}

return {
	package: "snmpd",
	type: "agent",
	reload: ["snmpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "SNMP agent",
	schema_properties: {
		agentaddress: { type: ["array", "null"], items: { type: "string" } },
	},
};
