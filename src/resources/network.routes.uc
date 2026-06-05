let values = require('values');
let is_valid_ipv4 = values.is_valid_ipv4;
let is_valid_cidr = values.is_valid_cidr;
let as_int = values.as_int;

const VALID_TYPES = {
	"unicast": true, "blackhole": true, "unreachable": true,
	"prohibit": true, "throw": true, "anycast": true,
	"multicast": true, "local": true, "broadcast": true,
};

function fromUci(section) {
	let anonymous = !!section['.anonymous'];
	return {
		id: section['.name'],
		managed: !anonymous,
		interface: section.interface ?? null,
		target: section.target ?? null,
		netmask: section.netmask ?? null,
		gateway: section.gateway ?? null,
		table: as_int(section.table),
		metric: as_int(section.metric),
		mtu: as_int(section.mtu),
		source: section.source ?? null,
		type: section.type ?? "unicast",
		runtime: {},
	};
}

function toUci(json) {
	let out = {};
	if (json.interface != null) out.interface = json.interface;
	if (json.target != null)    out.target = json.target;
	if (json.netmask != null)   out.netmask = json.netmask;
	if (json.gateway != null)   out.gateway = json.gateway;
	if (json.table != null)     out.table = "" + json.table;
	if (json.metric != null)    out.metric = "" + json.metric;
	if (json.mtu != null)       out.mtu = "" + json.mtu;
	if (json.source != null)    out.source = json.source;
	if (json.type != null && json.type != "unicast") out.type = json.type;
	return out;
}

function interface_exists(conn, name) {
	let found = false;
	conn.uci_foreach('network', 'interface', function(s) {
		if (s['.name'] == name) { found = true; return false; }
	});
	return found;
}

function validate(json, conn) {
	let errs = [];

	if (type(json) != "object") {
		push(errs, { field: "", code: "invalid_type",
		             message: "body must be a JSON object" });
		return errs;
	}

	if (json.target == null || json.target == "")
		push(errs, { field: "target", code: "required", message: "is required" });
	else if (!is_valid_ipv4(json.target) && !is_valid_cidr(json.target))
		push(errs, { field: "target", code: "invalid_format",
		             message: "must be a valid IPv4 address or CIDR" });

	if (json.gateway != null && json.gateway != "" && !is_valid_ipv4(json.gateway))
		push(errs, { field: "gateway", code: "invalid_format",
		             message: "must be a valid IPv4 address" });

	if (json.netmask != null && json.netmask != "" && !is_valid_ipv4(json.netmask))
		push(errs, { field: "netmask", code: "invalid_format",
		             message: "must be a valid IPv4 netmask" });

	if (json.source != null && json.source != ""
	    && !is_valid_ipv4(json.source) && !is_valid_cidr(json.source))
		push(errs, { field: "source", code: "invalid_format",
		             message: "must be a valid IPv4 address or CIDR" });

	let needs_iface = (json.type == null || json.type == "unicast");
	if (conn != null && needs_iface && json.interface != null && json.interface != "") {
		if (!interface_exists(conn, json.interface))
			push(errs, { field: "interface", code: "conflict",
			             message: sprintf("interface %J does not exist", json.interface) });
	}

	return errs;
}

return {
	package: "network",
	type: "route",
	reload: ["network"],
	fromUci: fromUci,
	toUci: toUci,
	validate: validate,
	openapi_singular: "network route",
	openapi_required: ["target"],
	schema_properties: {
		type:      { type: "string", enum: keys(VALID_TYPES) },
		interface: { type: ["string", "null"],
		             description: "Parent network interface name" },
		target:    { type: "string",
		             description: "Destination IPv4 address or CIDR" },
		netmask:   { type: ["string", "null"],
		             description: "IPv4 netmask if target is an address (not CIDR)" },
		gateway:   { type: ["string", "null"],
		             description: "IPv4 next-hop address" },
		table:     { type: ["integer", "null"], minimum: 0,
		             description: "Routing table id" },
		metric:    { type: "integer", minimum: 0 },
		mtu:       { type: "integer", minimum: 0 },
		source:    { type: ["string", "null"],
		             description: "Preferred source address (IPv4 or CIDR)" },
	},
};
