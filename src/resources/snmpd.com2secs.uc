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
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
	if (json.secname == null || json.secname == "")
		push(errs, { field: "secname", code: "required", message: "is required" });
	if (json.community == null || json.community == "")
		push(errs, { field: "community", code: "required", message: "is required" });
	return errs;
}

return {
	package: "snmpd",
	type: "com2sec",
	reload: ["snmpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {},
};
