let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;

const VALID_POLICIES = { "ACCEPT": true, "REJECT": true, "DROP": true };
const VALID_FAMILIES = { "any": true, "ipv4": true, "ipv6": true };

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		input: section.input ?? "REJECT",
		output: section.output ?? "REJECT",
		forward: section.forward ?? "REJECT",
		network: as_list(section.network),
		masq: normalize_bool(section.masq, false),
		mtu_fix: normalize_bool(section.mtu_fix, false),
		family: section.family ?? "any",
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.name != null) out.name = json.name;
	if (json.input != null) out.input = json.input;
	if (json.output != null) out.output = json.output;
	if (json.forward != null) out.forward = json.forward;
	if (type(json.network) == "array" && length(json.network) > 0) out.network = json.network;
	if (json.masq != null) out.masq = json.masq ? "1" : "0";
	if (json.mtu_fix != null) out.mtu_fix = json.mtu_fix ? "1" : "0";
	if (json.family != null && json.family != "any") out.family = json.family;
	return out;
}

function validate(json) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type", message: "body must be a JSON object" });
		return errs;
	}

	if (json.name == null || json.name == "")
		push(errs, { field: "name", code: "required", message: "is required" });

	return errs;
}

return {
	package: "firewall",
	type: "zone",
	reload: ["firewall"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	schema_properties: {
		name:    { type: ["string", "null"], pattern: "^[a-zA-Z0-9_-]+$",
		           description: "Zone name; alphanumerics, dashes, underscores" },
		input:   { type: "string", enum: keys(VALID_POLICIES) },
		output:  { type: "string", enum: keys(VALID_POLICIES) },
		forward: { type: "string", enum: keys(VALID_POLICIES) },
		family:  { type: "string", enum: keys(VALID_FAMILIES) },
		network: { type: "array", items: { type: "string" } },
		masq:    { type: "boolean",
		           description: "Enable IPv4 masquerading on this zone" },
		mtu_fix: { type: "boolean",
		           description: "Clamp MSS to PMTU for traffic in this zone" },
	},
};
