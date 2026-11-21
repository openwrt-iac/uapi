let values = require('values');
let normalize_bool = values.normalize_bool;
let as_int = values.as_int;

const VALID_POLICIES = { "ACCEPT": true, "REJECT": true, "DROP": true };

function fromUci(section) {
	return {
		id: section['.name'],
		managed: true,
		input: section.input ?? null,
		output_policy: section.output ?? null,
		forward: section.forward ?? null,
		syn_flood: normalize_bool(section.syn_flood, false),
		drop_invalid: normalize_bool(section.drop_invalid, false),
		synflood_burst: as_int(section.synflood_burst),
		synflood_rate: as_int(section.synflood_rate),
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

function validate(json) {
	let errs = [];

	return errs;
}

return {
	package: "firewall",
	type: "defaults",
	reload: ["firewall"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		input:              { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_POLICIES) },
		output_policy:      { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_POLICIES),
		                      description: "Renamed on the wire from uci's `output` (HCL block keyword)." },
		forward:            { "x-uapi-read-nullable": true, type: "string", enum: keys(VALID_POLICIES) },
		syn_flood:          { type: "boolean", default: false,
		                      description: "Enable SYN flood protection" },
		drop_invalid:       { type: "boolean", default: false,
		                      description: "Drop packets with invalid conntrack state" },
		synflood_burst:     { "x-uapi-read-nullable": true, type: "integer", minimum: 1, maximum: 1000000 },
		synflood_rate:      { "x-uapi-read-nullable": true, type: "integer", minimum: 1, maximum: 1000000 },
		tcp_syncookies:     { type: "boolean", default: false,
		                      description: "Enable kernel TCP SYN cookies" },
		flow_offloading:    { type: "boolean", default: false,
		                      description: "Enable software flow offloading" },
		flow_offloading_hw: { type: "boolean", default: false,
		                      description: "Enable hardware flow offloading (requires NIC support)" },
	},
};
