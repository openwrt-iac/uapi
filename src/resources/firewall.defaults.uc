let values = require('values');
let normalize_bool = values.normalize_bool;

const POLICIES = [ "ACCEPT", "REJECT", "DROP" ];
const UNIT_NSECS = { second: 1000000000, minute: 60000000000, hour: 3600000000000, day: 86400000000000 };
const RATE_UNITS = keys(UNIT_NSECS);
const U64_MAX = 18446744073709551615;
// fw4 reads these with parse_bool, which takes the spellings that normalize_bool takes.
const BOOLS = [ "syn_flood", "drop_invalid", "tcp_syncookies", "flow_offloading", "flow_offloading_hw" ];
const BOOL_REFUSED = " A stored list, or a value other than 1, on, true, yes, 0, off, false or no, reads false and is an error of the section: fw4 stops while it reads the defaults and applies no ruleset.";

// fw4's parse_limit: a rate, then a unit or a prefix of one, after a `!` that the syn_flood chain
// ignores. fw4 applies a rate without a unit per second. Its `+m[1]` is a uint64 that stops at
// 18446744073709551615, where int() gives NaN from 2^63 on.
function fw_limit(v) {
	let m = (type(v) == "string") ? match(trim(replace(v, /^[ \t]*!/, "")), /^([0-9]+)(\/([a-z]+))?$/) : null;
	if (m == null) return null;
	let unit = (m[3] == null) ? "second" : filter(RATE_UNITS, (u) => substr(u, 0, length(m[3])) == m[3])[0];
	return (unit != null) ? { rate: +m[1], unit: unit } : null;
}

// nft_limit_init refuses a packet limit with -EOVERFLOW when rate + burst, or the nanoseconds of the
// unit divided by the rate, times the burst, overflows a u64. fw4 writes no burst for a 0, and nft
// then applies 5.
function nft_overflows(limit, burst) {
	let b = (burst == 0) ? 5 : burst;
	let tmp = UNIT_NSECS[limit.unit] / limit.rate;
	return limit.rate > U64_MAX - b || (tmp > 0 && b > U64_MAX / tmp);
}

// fw4's parse_int is `+val`, and its template prints the number into `burst <n> packets`, which nft
// takes only as an integer: `0x10` and `1e3` are 16 and 1000, and `16.5` stops the load.
function fw_burst(v) {
	let n = (type(v) == "string") ? "" + (+v) : "";
	return match(n, /^-?[0-9]+$/) ? int(n) : null;
}

// parse_defaults of fw4 throws when parse_options refuses an option, as it does for a list and for a
// value that parse_bool, parse_int or parse_limit refuses.
function fw4_refuses(opt, v) {
	if (type(v) != "string") return v != null;
	if (index(BOOLS, opt) >= 0) return normalize_bool(v, null) == null;
	return (opt == "synflood_burst") ? +v != +v : fw_limit(v) == null;
}

function fromUci(section) {
	let rate = fw_limit(section.synflood_rate);
	return {
		id: section['.name'],
		managed: true,
		input: values.fw_enum(section.input, POLICIES) ?? null,
		output_policy: values.fw_enum(section.output, POLICIES) ?? null,
		forward: values.fw_enum(section.forward, POLICIES) ?? null,
		syn_flood: normalize_bool(section.syn_flood, false),
		drop_invalid: normalize_bool(section.drop_invalid, false),
		synflood_burst: fw_burst(section.synflood_burst),
		synflood_rate: (rate != null) ? sprintf("%s/%s", rate.rate, rate.unit) : null,
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
	// A read gives null for these only where uci holds nothing or a value that validate() refuses
	// unless the request names the field, so the empty list, which the handler removes, removes a
	// refused value and nothing else.
	out.synflood_burst = (json.synflood_burst != null) ? "" + json.synflood_burst : [];
	out.synflood_rate  = (json.synflood_rate != null) ? "" + json.synflood_rate : [];
	if (json.tcp_syncookies != null) out.tcp_syncookies = json.tcp_syncookies ? "1" : "0";
	if (json.flow_offloading != null)    out.flow_offloading    = json.flow_offloading ? "1" : "0";
	if (json.flow_offloading_hw != null) out.flow_offloading_hw = json.flow_offloading_hw ? "1" : "0";
	return out;
}

function validate(json, conn, id, delta) {
	let errs = [];
	let limit = (type(json.synflood_rate) == "int") ? { rate: json.synflood_rate, unit: "second" } : fw_limit(json.synflood_rate);
	let burst = json.synflood_burst ?? 50;
	if (limit?.rate > 0 && type(burst) == "int" && burst >= 0 && nft_overflows(limit, burst))
		push(errs, { field: "synflood_rate", code: "out_of_range", live: json.syn_flood === true,
		             message: "overflows 64 bits in the kernel with the burst, so nft refuses the limit and fw4 applies no ruleset while syn_flood is on: send another rate or a smaller burst" });
	if (conn == null || id == null) return errs;
	// The read cannot show a value that fw4 refuses in the type of its field, so this judges what
	// uci holds for each option that the request does not name. A request that names one replaces
	// it, or removes it with a null.
	let stored = conn.uci_get("firewall", id) ?? {};
	for (let opt in [ ...BOOLS, "synflood_burst", "synflood_rate" ]) {
		let v = stored[opt];
		if (v == null || exists(delta ?? {}, opt)) continue;
		if (fw4_refuses(opt, v))
			push(errs, { field: opt, code: "invalid_format", live: true,
			             message: "holds a value that fw4 refuses, so fw4 stops while it reads the defaults and applies no ruleset: send a valid value or null" });
		else if (opt == "synflood_burst" && fw_burst(v) == null)
			push(errs, { field: opt, code: "invalid_format", live: json.syn_flood === true,
			             message: "holds a number that is no integer, which nft refuses as a burst, so fw4 applies no ruleset while syn_flood is on: send an integer or null" });
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
	// A bool that a request names is written only over a spelling that fw4 refuses and that the read
	// gives as false: writing it elsewhere would pin an absent option, which fw4 reads as its default.
	rewrite_when_named: (view, stored) => {
		let out = {};
		for (let opt in BOOLS)
			if (fw4_refuses(opt, stored?.[opt])) out[opt] = opt;
		return out;
	},
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
		                      description: "Packets above `synflood_rate` that `syn_flood` lets through in a burst. A read gives the number as fw4 parses it, so `0x10` reads 16. Unset, fw4 applies 50. A stored list, or a value that is no number to fw4, such as `abc`, reads null and is an error of the section: fw4 stops while it reads the defaults and applies no ruleset. A number that is no integer, such as `16.5`, reads null and is an error too: nft refuses it, so fw4 applies no ruleset while `syn_flood` is on." },
		synflood_rate:      { "x-uapi-read-nullable": true, type: ["integer", "string"],
		                      pattern: "^[1-9][0-9]*/(second|minute|hour|day)$",
		                      "x-uapi-write": { minimum: 1 },
		                      "x-uapi-read": { type: ["string", "null"] },
		                      description: "SYN packets that `syn_flood` lets through, as a rate with its unit, such as `25/second`. A read gives it as fw4 applies it, so a stored `25` and `25/s` read `25/second`. A write also takes an integer, a rate per second. Unset, fw4 applies 25/second. The kernel refuses a limit whose rate plus burst overflows 64 bits, or a slow rate with a large burst, such as `1/minute` with a burst of 4294967295, whose nanoseconds per packet times the burst overflow 64 bits. Such a rate answers 422 `out_of_range`, and a stored one is an error of the section, since fw4 then applies no ruleset while `syn_flood` is on. A stored list, or a value that fw4 refuses, such as `abc`, reads null and is an error of the section: fw4 stops while it reads the defaults and applies no ruleset." },
		tcp_syncookies:     { type: "boolean", default: false,
		                      description: "Enable kernel TCP SYN cookies." + BOOL_REFUSED },
		flow_offloading:    { type: "boolean", default: false,
		                      description: "Enable software flow offloading." + BOOL_REFUSED },
		flow_offloading_hw: { type: "boolean", default: false,
		                      description: "Enable hardware flow offloading (requires NIC support)." + BOOL_REFUSED },
	},
};
