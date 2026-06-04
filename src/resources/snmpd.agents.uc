let values = require('values');
let as_list = values.as_list;

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		agentaddress: as_list(section.agentaddress),
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
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
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
		agentaddress: { type: "array", items: { type: "string" } },
	},
};
