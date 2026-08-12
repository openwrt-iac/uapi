let values = require('values');
let strict_bool = values.strict_bool;

const VALID_LOGLEVEL = {
	"emerg": true, "alert": true, "crit": true, "err": true,
	"warn": true, "notice": true, "info": true, "debug": true,
};

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		mmx_mask:        section.mmx_mask ?? null,
		logging:         strict_bool(section.logging),
		loglevel:        section.loglevel ?? null,
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.mmx_mask != null)       out.mmx_mask = json.mmx_mask;
	if (json.logging != null)        out.logging = json.logging ? "1" : "0";
	if (json.loglevel != null)       out.loglevel = json.loglevel;
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
		logging:        { type: "boolean", default: false, description: "Enable mwan3 daemon logging via logread." },
		loglevel:       { "x-uapi-read-nullable": true, type: ["string", "null"], enum: keys(VALID_LOGLEVEL),
		                  description: "syslog facility level (notice/info/debug/etc.)." },
	},
};
