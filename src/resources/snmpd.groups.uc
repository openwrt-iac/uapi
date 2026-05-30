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
	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}
	if (json.group == null || json.group == "")
		push(errs, { field: "group", code: "required", message: "is required" });
	if (json.version != null && !VALID_VERSIONS[json.version])
		push(errs, { field: "version", code: "not_in_enum",
		             message: "must be v1, v2c, or usm" });
	return errs;
}

return {
	package: "snmpd",
	type: "group",
	reload: ["snmpd"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		version: { type: "string", enum: keys(VALID_VERSIONS) },
	},
};
