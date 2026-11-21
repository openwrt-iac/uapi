let values = require('values');
let platform_bool = values.platform_bool;
let as_word_list_or_null = values.as_word_list_or_null;
let netifd_int = values.netifd_int;
let as_int = values.as_int;

const VALID_TYPES = {
	"bridge": true, "8021q": true, "8021ad": true, "macvlan": true,
	"veth": true, "tun": true, "tap": true,
};
// netifd sets up a type that it does not know, such as the bonding or vrf that LuCI writes, as a
// plain device, and the netifd of OpenWrt main takes vid 0.
const WRITE = { type: { enum: keys(VALID_TYPES) }, vid: { minimum: 1 } };

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		name: section.name ?? null,
		type: section.type ?? null,
		ports: as_word_list_or_null(section.ports),
		vid: as_int(section.vid),
		ifname: section.ifname ?? null,
		mtu: netifd_int(section.mtu),
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

function validate(json, conn, id, delta, partial, stored) {
	let errs = [];

	values.write_bounds(errs, delta ?? json, WRITE, stored);
	// Only the name: a `config device` section with only name + options
	// (e.g. a macaddr/mtu override on an existing kernel device) is valid uci
	// and is exactly what config_generate emits for per-device macaddr on some
	// targets. Requiring type would be stricter than the platform.
	values.require_present(errs, json, "name");

	if (json.type == "8021q" && json.vid == null)
		push(errs, { field: "vid", code: "required",
		             message: "is required when type is 8021q" });

	// The schema allows a smaller value so that a stored one reads as it is: netifd applies a
	// device mtu only from 68 up, and ignores a smaller one without a log.
	if (type(json.mtu) == "int" && json.mtu < 68)
		push(errs, { field: "mtu", code: "out_of_range",
		             message: "must be at least 68: netifd ignores a smaller device mtu" });

	return errs;
}

return {
	package: "network",
	type: "device",
	reload: ["network"],
	// odhcpd reads this config and has a procd trigger on it. dnsmasq and unbound, which LuCI's
	// ucitrack also reloads, read only ula_prefix and the interface names here: see docs/raw.md.
	reload_if_running: ["odhcpd"],
	unique_field: "name",
	// A device write can change the ports of the bridge carrying the request, or rename it,
	// which reaches the caller without touching `config interface`.
	mgmt_path_guard: true,
	mgmt_device_fields: [ "name", "ports" ],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_write_back: keys(WRITE),
	openapi_singular: "network device",
	openapi_required: ["name"],
	openapi_conditional: [
		{ if:   { properties: { type: { const: "8021q" } }, required: ["type"] },
		  then: { required: ["vid"] } },
	],
	schema_properties: {
		name:    { "x-uapi-read-nullable": true, type: "string",
		           description: "Device name as seen by netifd / the kernel" },
		type:    { "x-uapi-read-nullable": true, type: "string", "x-uapi-write": WRITE.type,
		           description: "Device type that a write sets. A read also gives a type that uapi does not write, such as the bonding or vrf that LuCI writes, and netifd sets up a type that it does not know as a plain device" },
		ports:   { type: ["array", "null"], items: { type: "string" } },
		vid:     { "x-uapi-read-nullable": true, type: "integer", minimum: 0, maximum: 4094, "x-uapi-write": WRITE.vid,
		           description: "VLAN id for 8021q / 8021ad devices. A write takes 1 to 4094, and a read gives a stored 0, which the netifd of OpenWrt main takes" },
		ifname:  { type: ["string", "null"],
		           description: "Underlying parent interface (e.g. for macvlan/8021q)" },
		mtu:     { "x-uapi-read-nullable": true, type: "integer", minimum: 0, maximum: 65535, "x-uapi-write": { minimum: 68 },
		           description: "Device MTU. netifd applies it only from 68 up, so a stored smaller value reads as it is and a write below 68 answers 422." },
		macaddr: { type: ["string", "null"], pattern: "^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$",
		           description: "MAC address override (colon or dash separated)" },
		ipv6:    { type: "boolean", default: true,
		           description: "Enable IPv6 on this device" },
	},
};
