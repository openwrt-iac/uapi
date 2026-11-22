let values = require('values');
let fw_bool = values.fw_bool;
let as_list_or_null = values.as_list_or_null;

const POLICIES = [ "ACCEPT", "REJECT", "DROP" ];
const VALID_FAMILIES = { "any": true, "ipv4": true, "ipv6": true };

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		input: values.fw_enum(section.input, POLICIES),
		output_policy: values.fw_enum(section.output, POLICIES),
		forward: values.fw_enum(section.forward, POLICIES),
		network: as_list_or_null(section.network),
		masq: fw_bool(section.masq, false),
		mtu_fix: fw_bool(section.mtu_fix, false),
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
	out.masq = (json.masq != null) ? (json.masq ? "1" : "0") : [];
	out.mtu_fix = (json.mtu_fix != null) ? (json.mtu_fix ? "1" : "0") : [];
	if (json.family != null && json.family != "any") out.family = json.family;
	return out;
}

function validate(json, conn, id, delta, partial) {
	let errs = [];

	values.require_present(errs, json, "name");
	values.fw_refused_bools(errs, conn, id, delta, partial, [ "masq", "mtu_fix" ]);

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
		name:    { type: ["string", "null"], pattern: "^[a-zA-Z_.][a-zA-Z0-9/_.-]*$", "x-uapi-write": { pattern: "^[a-zA-Z_][a-zA-Z0-9_-]*$" },
		           description: "Zone name. A write takes a letter or an underscore, then letters, digits, dashes and underscores, and a read also gives the dots and slashes that firewall4 takes. firewall4 skips a zone whose name starts with a digit or a dash, so a write refuses it, and a stored one blocks every write of the section." },
		input:         { "x-uapi-read-nullable": true, "x-uapi-clear-on-omit": true, type: "string", enum: POLICIES,
		                 description: "Unset, fw4 applies the `input` of firewall/defaults, and DROP when that has none, as LuCI shows it. The read gives null then, so a write of the read keeps the zone on the policy of firewall/defaults. A PUT that leaves the field out, or a null, removes the option, and the zone takes the policy of firewall/defaults again." },
		output_policy: { "x-uapi-read-nullable": true, "x-uapi-clear-on-omit": true, type: "string", enum: POLICIES,
		                 description: "Renamed on the wire from uci's `output` (HCL block keyword). Unset, fw4 applies the `output_policy` of firewall/defaults, and DROP when that has none, as LuCI shows it. The read gives null then, so a write of the read keeps the zone on the policy of firewall/defaults. A PUT that leaves the field out, or a null, removes the option, and the zone takes the policy of firewall/defaults again." },
		forward:       { "x-uapi-read-nullable": true, "x-uapi-clear-on-omit": true, type: "string", enum: POLICIES,
		                 description: "Unset, fw4 applies the `forward` of firewall/defaults, and DROP when that has none, as LuCI shows it. The read gives null then, so a write of the read keeps the zone on the policy of firewall/defaults. A PUT that leaves the field out, or a null, removes the option, and the zone takes the policy of firewall/defaults again." },
		family:  { type: "string", enum: keys(VALID_FAMILIES), default: "any" },
		network: { type: ["array", "null"], items: { type: "string" } },
		masq:    { "x-uapi-read-nullable": true, type: "boolean", default: false,
		           description: "Enable IPv4 masquerading on this zone. " + values.FW_BOOL_REFUSED },
		mtu_fix: { "x-uapi-read-nullable": true, type: "boolean", default: false,
		           description: "Clamp MSS to PMTU for traffic in this zone. " + values.FW_BOOL_REFUSED },
	},
};
