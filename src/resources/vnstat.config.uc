let values = require('values');
let as_list_or_null = values.as_list_or_null;

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		// The only option vnstat's init actually reads. It walks `config vnstat` sections
		// and takes the `list interface` inside them (vnstat.init:21,28), then runs
		// `vnstat --add -i <name>` per entry. Values are DEVICE names as the kernel shows
		// them (`br-lan`, `eth0`), not uci interface section names.
		interfaces:          as_list_or_null(section.interface),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
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
		interfaces:           { type: ["array", "null"], items: { type: "string" },
		                        description: "Devices vnstat tracks, as the kernel names them (`br-lan`, `eth0`), not uci interface names. This is the only vnstat option any shipped code reads; see docs/deprecations.md for why `vnstat/interfaces` is being removed in favour of it." },
	},
};
