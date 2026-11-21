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

// mwan3 reads the mask in shell arithmetic, which takes a leading 0 as octal, and gives it to
// iptables, which takes 32 bits.
function validate(json, conn, id, delta) {
	let errs = [];
	let m = (delta ?? json).mmx_mask;
	if (type(m) == "string" && match(m, /^[0-9]+$/)
	    && (match(m, /^0[0-7]*$/) ? length(ltrim(m, "0")) > 11 || int(m, 8) > 0xFFFFFFFF : int(m) > 0xFFFFFFFF))
		push(errs, { field: "mmx_mask", code: "out_of_range",
		             message: "must be at most 0xFFFFFFFF: iptables takes a mark mask of 32 bits" });
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
		                  pattern: "^(0[xX][0-9A-Fa-f]+|0[0-7]*|[1-9][0-9]{0,9})$",
		                  description: "Firewall mark mask for mwan3-tagged packets, in hex, decimal or octal with a leading 0, as the shell arithmetic of mwan3 reads it (default 0x3F00). A decimal or octal mask is at most 0xFFFFFFFF." },
		logging:        { type: "boolean", default: false, description: "Enable mwan3 daemon logging via logread." },
		loglevel:       { "x-uapi-read-nullable": true, type: ["string", "null"], enum: [ ...keys(VALID_LOGLEVEL), null ],
		                  description: "syslog facility level (notice/info/debug/etc.)." },
	},
};
