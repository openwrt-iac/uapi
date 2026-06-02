function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		database_dir:        section.DatabaseDir ?? null,
		interface_5min_hours: as_int(section.Interface5MinHours),
		month_rotate:        as_int(section.MonthRotate),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.database_dir != null)         out.DatabaseDir = json.database_dir;
	if (json.interface_5min_hours != null) out.Interface5MinHours = "" + json.interface_5min_hours;
	if (json.month_rotate != null)         out.MonthRotate = "" + json.month_rotate;
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
	schema_properties: {
		database_dir:         { type: "string",
		                        description: "Path to vnstat's database directory" },
		interface_5min_hours: { type: "integer", minimum: 0,
		                        description: "How many hours of 5-minute granularity data to keep" },
		month_rotate:         { type: "integer", minimum: 1, maximum: 31,
		                        description: "Day of month that monthly counters roll over" },
	},
};
