let values = require('values');
let normalize_bool = values.normalize_bool;
let as_int = values.as_int;

const VALID_LOGLEVEL = {
	"emerg": true, "alert": true, "crit": true, "err": true,
	"warn": true, "notice": true, "info": true, "debug": true,
};

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		mmx_mask:        section.mmx_mask ?? null,
		local_source:    section.local_source ?? null,
		logging:         normalize_bool(section.logging, false),
		loglevel:        section.loglevel ?? null,
		rtmon_interval:  as_int(section.rtmon_interval),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.mmx_mask != null)       out.mmx_mask = json.mmx_mask;
	if (json.local_source != null)   out.local_source = json.local_source;
	if (json.logging != null)        out.logging = json.logging ? "1" : "0";
	if (json.loglevel != null)       out.loglevel = json.loglevel;
	if (json.rtmon_interval != null) out.rtmon_interval = "" + json.rtmon_interval;
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
	package: "mwan3",
	type: "globals",
	reload: ["mwan3"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		mmx_mask:       { type: ["string", "null"],
		                  pattern: "^0x[0-9A-Fa-f]+$",
		                  description: "Firewall mark mask for mwan3-tagged packets (hex, default 0x3F00)." },
		local_source:   { type: ["string", "null"],
		                  description: "Network interface used as source for locally-generated traffic; 'none' to disable." },
		logging:        { type: "boolean", description: "Enable mwan3 daemon logging via logread." },
		loglevel:       { type: ["string", "null"], enum: keys(VALID_LOGLEVEL),
		                  description: "syslog facility level (notice/info/debug/etc.)." },
		rtmon_interval: { type: ["integer", "null"], minimum: 1, maximum: 86400,
		                  description: "Seconds between netlink route-monitor polls." },
	},
};
