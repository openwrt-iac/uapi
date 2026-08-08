let values = require('values');
let as_int = values.as_int;
let as_list = values.as_list;

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		database_dir:        section.DatabaseDir ?? null,
		interface_5min_hours: as_int(section.Interface5MinHours),
		month_rotate:        as_int(section.MonthRotate),
		// The only option vnstat's init actually reads. It walks `config vnstat` sections
		// and takes the `list interface` inside them (vnstat.init:21,28), then runs
		// `vnstat --add -i <name>` per entry. Values are DEVICE names as the kernel shows
		// them (`br-lan`, `eth0`), not uci interface section names.
		interfaces:          as_list(section.interface),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.database_dir != null)         out.DatabaseDir = json.database_dir;
	if (json.interface_5min_hours != null) out.Interface5MinHours = "" + json.interface_5min_hours;
	if (json.month_rotate != null)         out.MonthRotate = "" + json.month_rotate;
	if (json.interfaces != null)           out.interface = json.interfaces;
	return out;
}

function validate(json) {
	let errs = [];
	if (type(json.interfaces) == "array") {
		for (let i = 0; i < length(json.interfaces); i++) {
			let v = json.interfaces[i];
			if (type(v) != "string" || trim(v) == "")
				push(errs, { field: sprintf("interfaces[%d]", i), code: "invalid_format",
				             message: "must be a device name as the kernel shows it, e.g. br-lan" });
		}
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
		interfaces:           { type: "array", items: { type: "string" },
		                        description: "Devices vnstat tracks, as the kernel names them (`br-lan`, `eth0`), not uci interface names. This is the only vnstat option any shipped code reads; see docs/deprecations.md for why `vnstat/interfaces` is being removed in favour of it." },
	},
};
