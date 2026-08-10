let values = require('values');
let as_list = values.as_list;
let as_int = values.as_int;

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		device: section.device ?? null,
		vlan: as_int(section.vlan),
		ports: as_list(section.ports),
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.device != null) out.device = json.device;
	if (json.vlan != null)   out.vlan = "" + json.vlan;
	if (type(json.ports) == "array" && length(json.ports) > 0)
		out.ports = json.ports;
	return out;
}

function bridge_exists(conn, name) {
	return values.section_index(conn, 'network', 'device', 'name',
	                            function(s) { return s.type == "bridge"; })[name] != null;
}

function validate(json, conn) {
	let errs = [];

	values.require_present(errs, json, "device");

	if (json.vlan == null)
		push(errs, { field: "vlan", code: "required", message: "is required" });

	if (conn != null && json.device != null && json.device != "") {
		if (!bridge_exists(conn, json.device))
			push(errs, { field: "device", code: "conflict",
			             message: sprintf("bridge %J does not exist", json.device) });
	}

	return errs;
}

return {
	package: "network",
	type: "bridge-vlan",
	reload: ["network"],
	// A bridge-vlan turns on VLAN filtering for the whole bridge, so a write to the bridge
	// carrying the request drops untagged traffic and takes the caller off the network. This
	// resource never touches `config interface`, which is why the interface-name match could
	// not see it.
	mgmt_path_guard: true,
	mgmt_device_field: "device",
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "bridge VLAN",
	openapi_required: ["device", "vlan"],
	schema_properties: {
		device: { type: "string",
		          description: "Parent bridge device name (must exist in network/devices type=bridge)" },
		vlan:   { type: "integer", minimum: 1, maximum: 4094 },
		ports:  { type: "array", items: { type: "string", pattern: "^[A-Za-z0-9._-]+(:[tu*]+)?$" },
		          description: "Bridge ports with optional :t (tagged), :u (untagged), :* (pvid) suffix" },
	},
};
