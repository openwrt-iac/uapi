let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list_or_null = values.as_list_or_null;

const POLICIES = [ "ACCEPT", "REJECT", "DROP" ];
const VALID_FAMILIES = { "any": true, "ipv4": true, "ipv6": true };

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		input: values.fw_enum(section.input, POLICIES) ?? "REJECT",
		output_policy: values.fw_enum(section.output, POLICIES) ?? "REJECT",
		forward: values.fw_enum(section.forward, POLICIES) ?? "REJECT",
		network: as_list_or_null(section.network),
		masq: normalize_bool(section.masq, false),
		mtu_fix: normalize_bool(section.mtu_fix, false),
		family: values.fw_family(section.family) ?? "any",
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.name != null) out.name = json.name;
	if (json.input != null) out.input = json.input;
	if (json.output_policy != null) out.output = json.output_policy;
	if (json.forward != null) out.forward = json.forward;
	if (type(json.network) == "array" && length(json.network) > 0) out.network = json.network;
	if (json.masq != null) out.masq = json.masq ? "1" : "0";
	if (json.mtu_fix != null) out.mtu_fix = json.mtu_fix ? "1" : "0";
	if (json.family != null && json.family != "any") out.family = json.family;
	return out;
}

function validate(json) {
	let errs = [];

	values.require_present(errs, json, "name");

	return errs;
}

return {
	package: "firewall",
	type: "zone",
	reload: ["firewall"],
	unique_field: "name",
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "firewall zone",
	openapi_required: ["name"],
	schema_properties: {
		name:    { type: ["string", "null"], pattern: "^[a-zA-Z_.][a-zA-Z0-9/_.-]*$", "x-uapi-write": { pattern: "^[a-zA-Z0-9_-]+$" },
		           description: "Zone name. A write takes alphanumerics, dashes and underscores, and a read also gives the dots and slashes that firewall4 takes" },
		input:         { type: "string", enum: POLICIES, default: "REJECT" },
		output_policy: { type: "string", enum: POLICIES, default: "REJECT",
		                 description: "Renamed on the wire from uci's `output` (HCL block keyword)." },
		forward:       { type: "string", enum: POLICIES, default: "REJECT" },
		family:  { type: "string", enum: keys(VALID_FAMILIES), default: "any" },
		network: { type: ["array", "null"], items: { type: "string" } },
		masq:    { type: "boolean", default: false,
		           description: "Enable IPv4 masquerading on this zone" },
		mtu_fix: { type: "boolean", default: false,
		           description: "Clamp MSS to PMTU for traffic in this zone" },
	},
};
