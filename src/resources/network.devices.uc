let values = require('values');
let normalize_bool = values.normalize_bool;
let as_list = values.as_list;
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
		ports: as_list(section.ports),
		vid: as_int(section.vid),
		ifname: section.ifname ?? null,
		mtu: as_int(section.mtu),
		macaddr: section.macaddr ?? null,
		ipv6: normalize_bool(section.ipv6, true),
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

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type", message: "body must be a JSON object" });
		return errs;
	}

	if (json.name == null || json.name == "")
		push(errs, { field: "name", code: "required", message: "is required" });

	if (json.type == null || json.type == "")
		push(errs, { field: "type", code: "required", message: "is required" });

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
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "network device",
	openapi_required: ["name", "type"],
	openapi_conditional: [
		{ if:   { properties: { type: { const: "8021q" } }, required: ["type"] },
		  then: { required: ["vid"] } },
	],
	schema_properties: {
		name:    { type: "string",
		           description: "Device name as seen by netifd / the kernel" },
		type:    { type: "string", enum: keys(VALID_TYPES) },
		ports:   { type: "array", items: { type: "string" } },
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
