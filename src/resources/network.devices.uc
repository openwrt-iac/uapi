let values = require('values');
let platform_bool = values.platform_bool;
let as_list_or_null = values.as_list_or_null;
let as_int = values.as_int;

const VALID_TYPES = {
	"bridge": true, "8021q": true, "8021ad": true, "macvlan": true,
	"veth": true, "tun": true, "tap": true,
};

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		type: section.type ?? null,
		ports: as_list_or_null(section.ports),
		vid: as_int(section.vid),
		ifname: section.ifname ?? null,
		mtu: as_int(section.mtu),
		macaddr: section.macaddr ?? null,
		ipv6: platform_bool(section.ipv6, true),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.name != null) out.name = json.name;
	if (json.type != null) out.type = json.type;
	if (type(json.ports) == "array" && length(json.ports) > 0) out.ports = json.ports;
	if (json.vid != null) out.vid = "" + json.vid;
	if (json.ifname != null) out.ifname = json.ifname;
	if (json.mtu != null) out.mtu = "" + json.mtu;
	if (json.macaddr != null) out.macaddr = json.macaddr;
	if (json.ipv6 != null) out.ipv6 = json.ipv6 ? "1" : "0";
	return out;
}

function validate(json) {
	let errs = [];

	values.require_present(errs, json, "name");

	// type is optional: a `config device` section with only name + options
	// (e.g. a macaddr/mtu override on an existing kernel device) is valid uci
	// and is exactly what config_generate emits for per-device macaddr on some
	// targets. Requiring type would be stricter than the platform. Validate the
	// enum only when a type is actually present.
	if (json.type != null && json.type != "" && !VALID_TYPES[json.type])
		push(errs, { field: "type", code: "not_in_enum",
		             message: "must be one of bridge, 8021q, 8021ad, macvlan, veth, tun, tap" });

	if (json.type == "8021q" && (json.vid == null || json.vid == ""))
		push(errs, { field: "vid", code: "required",
		             message: "is required when type is 8021q" });

	return errs;
}

return {
	package: "network",
	type: "device",
	reload: ["network"],
	unique_field: "name",
	// A device write can change the ports of the bridge carrying the request, or rename it,
	// which reaches the caller without touching `config interface`.
	mgmt_path_guard: true,
	mgmt_device_fields: [ "name", "ports" ],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "network device",
	openapi_required: ["name"],
	openapi_conditional: [
		{ if:   { properties: { type: { const: "8021q" } }, required: ["type"] },
		  then: { required: ["vid"] } },
	],
	schema_properties: {
		name:    { type: "string",
		           description: "Device name as seen by netifd / the kernel" },
		type:    { type: "string", enum: keys(VALID_TYPES) },
		ports:   { type: ["array", "null"], items: { type: "string" } },
		vid:     { type: "integer", minimum: 1, maximum: 4094,
		           description: "VLAN id for 8021q / 8021ad devices" },
		ifname:  { type: ["string", "null"],
		           description: "Underlying parent interface (e.g. for macvlan/8021q)" },
		mtu:     { type: "integer", minimum: 0, maximum: 65535 },
		macaddr: { type: ["string", "null"], pattern: "^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$",
		           description: "MAC address override (colon or dash separated)" },
		ipv6:    { type: "boolean", default: true,
		           description: "Enable IPv6 on this device" },
	},
};
