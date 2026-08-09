let values = require('values');
let strict_bool = values.strict_bool;
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
		logging:         strict_bool(section.logging),
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
		local_source:   { deprecated: true, type: ["string", "null"],
		                  description: "Deprecated, removed in v3: nothing reads this. The live knob is `source_routing`, a boolean about route-line parsing, not an interface name, so there is nothing to rename this to." },
		logging:        { type: "boolean", default: false, description: "Enable mwan3 daemon logging via logread." },
		loglevel:       { type: ["string", "null"], enum: keys(VALID_LOGLEVEL),
		                  description: "syslog facility level (notice/info/debug/etc.)." },
		rtmon_interval: { deprecated: true, type: ["integer", "null"], minimum: 1, maximum: 86400,
		                  description: "Deprecated, removed in v3: nothing reads this. `mwan3rtmon` is driven by `ip monitor route`, so there is no polling interval to set." },
	},
};
