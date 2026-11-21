let values = require('values');
let normalize_bool = values.normalize_bool;
let as_int = values.as_int;

const POLICIES = [ "ACCEPT", "REJECT", "DROP" ];
const RATE_UNITS = [ "second", "minute", "hour", "day" ];

// fw4's parse_limit: a rate, then a unit or a prefix of one, after a `!` that the syn_flood chain
// ignores. fw4 applies a rate without a unit per second, so it reads as the integer that 3.x gave.
function fw_limit(v) {
	let m = (type(v) == "string") ? match(trim(replace(v, /^[ \t]*!/, "")), /^([0-9]+)(\/([a-z]+))?$/) : null;
	if (m == null) return null;
	if (m[3] == null) return int(m[1]);
	let unit = filter(RATE_UNITS, (u) => substr(u, 0, length(m[3])) == m[3])[0];
	return (unit != null) ? sprintf("%d/%s", int(m[1]), unit) : null;
}

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		input: values.fw_enum(section.input, POLICIES) ?? null,
		output_policy: values.fw_enum(section.output, POLICIES) ?? null,
		forward: values.fw_enum(section.forward, POLICIES) ?? null,
		syn_flood: normalize_bool(section.syn_flood, false),
		drop_invalid: normalize_bool(section.drop_invalid, false),
		synflood_burst: as_int(section.synflood_burst),
		synflood_rate: fw_limit(section.synflood_rate),
		tcp_syncookies: normalize_bool(section.tcp_syncookies, false),
		flow_offloading: normalize_bool(section.flow_offloading, false),
		flow_offloading_hw: normalize_bool(section.flow_offloading_hw, false),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.input != null)    out.input = json.input;
	if (json.output_policy != null) out.output = json.output_policy;
	if (json.forward != null)  out.forward = json.forward;
	if (json.syn_flood != null)    out.syn_flood = json.syn_flood ? "1" : "0";
	if (json.drop_invalid != null) out.drop_invalid = json.drop_invalid ? "1" : "0";
	if (json.synflood_burst != null) out.synflood_burst = "" + json.synflood_burst;
	if (json.synflood_rate != null)  out.synflood_rate  = "" + json.synflood_rate;
	if (json.tcp_syncookies != null) out.tcp_syncookies = json.tcp_syncookies ? "1" : "0";
	if (json.flow_offloading != null)    out.flow_offloading    = json.flow_offloading ? "1" : "0";
	if (json.flow_offloading_hw != null) out.flow_offloading_hw = json.flow_offloading_hw ? "1" : "0";
	return out;
}

// fw4 reads these with parse_bool, which takes the spellings that normalize_bool takes.
const BOOLS = { syn_flood: "syn_flood", drop_invalid: "drop_invalid", tcp_syncookies: "tcp_syncookies",
                flow_offloading: "flow_offloading", flow_offloading_hw: "flow_offloading_hw" };
const BOOL_REFUSED = " A stored list, or a value other than 1, on, true, yes, 0, off, false or no, reads false and is an error of the section: fw4 stops while it reads the defaults and applies no ruleset.";

// parse_defaults of fw4 throws when parse_options refuses an option, as it does for a list and for a
// value that parse_bool, parse_int or parse_limit refuses, so fw4 applies no ruleset. The read gives
// such a bool its default and such a number null, so this judges what uci holds for each option that
// the write keeps. A request that names a bool writes it through rewrite_when_named, even where the
// read already gives that value, or removes it for a null. A null for a number keeps the option,
// because the read gives null for it and the write has no option to remove.
function validate(json, conn, id, delta) {
	let errs = [];
	if (conn == null || id == null) return errs;
	let stored = conn.uci_get("firewall", id) ?? {};
	for (let opt in [ ...keys(BOOLS), "synflood_burst", "synflood_rate" ]) {
		let v = stored[opt];
		let replaced = exists(delta ?? {}, opt) && (delta[opt] != null || BOOLS[opt] != null);
		if (v == null || replaced) continue;
		let refused = (type(v) != "string") ? true
			: (BOOLS[opt] != null) ? normalize_bool(v, null) == null
			: (opt == "synflood_burst") ? +v != +v
			: fw_limit(v) == null;
		if (refused)
			push(errs, { field: opt, code: "invalid_format", live: true,
			             message: "holds a value that fw4 refuses, so fw4 stops while it reads the defaults and applies no ruleset: send a valid value" });
	}
	return errs;
}

return {
	package: "firewall",
	type: "defaults",
	reload: ["firewall"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	rewrite_when_named: BOOLS,
	schema_properties: {
		input:              { "x-uapi-read-nullable": true, type: "string", enum: POLICIES,
		                      description: "Unset, fw4 applies DROP, here and in each firewall/zones section without its own `input`." },
		output_policy:      { "x-uapi-read-nullable": true, type: "string", enum: POLICIES,
		                      description: "Renamed on the wire from uci's `output` (HCL block keyword). Unset, fw4 applies DROP, here and in each firewall/zones section without its own `output_policy`." },
		forward:            { "x-uapi-read-nullable": true, type: "string", enum: POLICIES,
		                      description: "Unset, fw4 applies DROP, here and in each firewall/zones section without its own `forward`." },
		syn_flood:          { type: "boolean", default: false,
		                      description: "Enable SYN flood protection." + BOOL_REFUSED },
		drop_invalid:       { type: "boolean", default: false,
		                      description: "Drop packets with invalid conntrack state." + BOOL_REFUSED },
		synflood_burst:     { "x-uapi-read-nullable": true, type: "integer", minimum: 0, maximum: 4294967295,
		                      description: "A stored list, or a value that is no number to fw4, such as `abc`, reads null and is an error of the section: fw4 stops while it reads the defaults and applies no ruleset." },
		synflood_rate:      { "x-uapi-read-nullable": true, type: ["integer", "string"], minimum: 1,
		                      pattern: "^[1-9][0-9]*/(second|minute|hour|day)$",
		                      description: "SYN packets that `syn_flood` lets through: an integer per second, or a rate with its unit, such as `25/minute`. fw4 also takes a prefix of the unit, which reads as the whole word, so `25/s` reads `25/second`. Unset, fw4 applies 25 per second. A stored list, or a value that fw4 refuses, such as `abc`, reads null and is an error of the section: fw4 stops while it reads the defaults and applies no ruleset." },
		tcp_syncookies:     { type: "boolean", default: false,
		                      description: "Enable kernel TCP SYN cookies." + BOOL_REFUSED },
		flow_offloading:    { type: "boolean", default: false,
		                      description: "Enable software flow offloading." + BOOL_REFUSED },
		flow_offloading_hw: { type: "boolean", default: false,
		                      description: "Enable hardware flow offloading (requires NIC support)." + BOOL_REFUSED },
	},
};
