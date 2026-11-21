let values = require('values');
let strict_bool = values.strict_bool;

// The names that LuCI offers and that the LOG target of iptables takes.
const LOG_LEVELS = [ "emerg", "alert", "crit", "error", "warning", "notice", "info", "debug" ];
const IPTABLES_REFUSED = [ "err", "warn" ];

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

// mwan3 hands the level to iptables-restore in the one batch that loads all of its rules, so a level
// that iptables refuses leaves every rule out as soon as one of them logs.
function validate_new(json) {
	if (index(IPTABLES_REFUSED, json.loglevel) < 0) return [];
	return [ { field: "loglevel", code: "not_in_enum", live: json.logging === true,
	           message: "is a log level that iptables refuses, so mwan3 loads none of its rules once one of them logs: use error or warning" } ];
}

return {
	package: "mwan3",
	type: "globals",
	reload: ["mwan3"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	validate_new: validate_new,
	schema_properties: {
		mmx_mask:       { type: ["string", "null"],
		                  pattern: MASK_PATTERN,
		                  description: "Firewall mark mask for mwan3-tagged packets (default 0x3F00), of 32 bits, in hex, decimal or octal, as ash, iptables and ip read it: a leading 0 makes it octal, so 08 is no number." },
		logging:        { type: "boolean", default: false, description: "Enable mwan3 daemon logging via logread." },
		loglevel:       { "x-uapi-read-nullable": true, type: ["string", "null"], enum: [ ...LOG_LEVELS, ...IPTABLES_REFUSED, null ],
		                  "x-uapi-write": { enum: [ ...LOG_LEVELS, null ] },
		                  description: "Level of the LOG rule that mwan3 adds for each mwan3/rules section with `logging` while `logging` is on here. Unset, mwan3 uses notice. iptables refuses `err` and `warn`, and mwan3 then loads none of its rules. A write refuses them, and a stored one blocks every write of the section, but a read can give one." },
	},
};
