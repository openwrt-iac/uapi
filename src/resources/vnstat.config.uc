function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		DatabaseDir: section.DatabaseDir ?? null,
		Interface5MinHours: section.Interface5MinHours ?? null,
		MonthRotate: section.MonthRotate ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.DatabaseDir != null)        out.DatabaseDir = json.DatabaseDir;
	if (json.Interface5MinHours != null) out.Interface5MinHours = "" + json.Interface5MinHours;
	if (json.MonthRotate != null)        out.MonthRotate = "" + json.MonthRotate;
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
	package: "vnstat",
	type: "vnstat",
	reload: ["vnstat"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {},
};
