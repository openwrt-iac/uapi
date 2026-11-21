let values = require('values');
let strict_bool = values.strict_bool;

const VALID_LOGLEVEL = {
	"emerg": true, "alert": true, "crit": true, "err": true, "error": true,
	"warn": true, "warning": true, "notice": true, "info": true, "debug": true,
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

const MASK_PATTERN = "^(0[xX][0-9A-Fa-f]+|0[0-7]*|[1-9][0-9]*)$";
const MASK_RE = regexp(MASK_PATTERN);

// mwan3 reads the mask in ash arithmetic, and iptables and ip read it as a C number of 32 bits.
function validate(json) {
	let m = json.mmx_mask;
	if (type(m) != "string" || !match(m, MASK_RE)) return [];
	let n = int(m, 0);
	return (type(n) == "int" && n <= 0xffffffff) ? []
		: [ { field: "mmx_mask", code: "out_of_range", message: "must fit in 32 bits: iptables and ip refuse a larger mark mask" } ];
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
		                  pattern: MASK_PATTERN,
		                  description: "Firewall mark mask for mwan3-tagged packets (default 0x3F00), of 32 bits, in hex, decimal or octal, as ash, iptables and ip read it: a leading 0 makes it octal, so 08 is no number." },
		logging:        { type: "boolean", default: false, description: "Enable mwan3 daemon logging via logread." },
		loglevel:       { "x-uapi-read-nullable": true, type: ["string", "null"], enum: [ ...keys(VALID_LOGLEVEL), null ],
		                  description: "syslog facility level (notice/info/debug/etc.)." },
	},
};
